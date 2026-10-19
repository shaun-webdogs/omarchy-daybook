#!/usr/bin/env python3
"""Let outside tools keep their tasks in Daybook. Stdlib only.

A feed owns one source ("zendesk", "wrike", ...) and hands Daybook the full list
of that source's open items each run. Daybook then matches:

- new item: added to today, near the top of the list
- known item, still open here: title, note, link and waiting tag follow the
  source, except fields you edited by hand in Daybook
- item gone from the list: completed, marked closed by the sync
- item back on the list: revived only if the sync closed it. A task you
  completed or archived yourself stays closed.

The panel's service holds its lock while the shell runs, so this writes rows
directly with the same SQL as daybook.py, inside BEGIN IMMEDIATE. It never
touches the running timer: a running task is left for the next run.
"""

import datetime as dt
import json
import os
from pathlib import Path
import sqlite3
import sys

sys.path.insert(0, str(Path(__file__).resolve().parent))
from daybook import WAITING_TAG, Store, data_directory  # noqa: E402


class Feed:
    def __init__(self, path=None, today=None):
        self.path = Path(path or os.environ.get("DAYBOOK_DB") or data_directory() / "daybook.sqlite3")
        if not self.path.exists():
            raise FileNotFoundError(f"no Daybook database at {self.path}")
        self.today = today or dt.date.today().isoformat()
        self.db = sqlite3.connect(self.path, timeout=5, isolation_level=None)
        self.db.row_factory = sqlite3.Row
        self.db.execute("PRAGMA foreign_keys=ON")
        self.db.execute("PRAGMA synchronous=FULL")
        version = self.db.execute("PRAGMA user_version").fetchone()[0]
        if version != 1:
            raise ValueError(f"Daybook schema version {version}, expected 1")
        columns = {r[1] for r in self.db.execute("PRAGMA table_info(tasks)")}
        if "closed_by" not in columns:
            raise ValueError("Daybook is older than this feed: open the panel once so it upgrades the database")

    def close(self):
        self.db.close()

    def tasks(self, source):
        """{ext_id: row} for every task this source ever added, open or closed."""
        return {r["ext_id"]: r for r in self.db.execute("""
            SELECT t.*, d.task_id IS NOT NULL AS on_today, COALESCE(d.completed, 0) AS completed
            FROM tasks t LEFT JOIN days d ON d.task_id=t.id AND d.day=?
            WHERE t.source=?""", (self.today, source))}

    @staticmethod
    def is_open(row):
        return bool(row["on_today"]) and not row["completed"] and not row["archived"]

    def _ensure_tag(self, tag):
        row = self.db.execute("SELECT value FROM meta WHERE key='tags'").fetchone()
        tags = json.loads(row[0]) if row else list(Store.DEFAULT_TAGS)
        if tag not in tags:
            self.db.execute("INSERT OR REPLACE INTO meta VALUES('tags', ?)", (json.dumps(tags + [tag], ensure_ascii=False),))

    def reconcile(self, source, items, apply=False, allow_empty=False):
        """Match Daybook to `items` for one source. Returns log lines.

        items: [{"ext_id", "title", "note", "link", "waiting"}], in the order new
        ones should appear. Without apply everything is rolled back.
        """
        if not items and not allow_empty:
            raise ValueError(f"{source}: empty item list - refusing to close every task")
        seen = set()
        for item in items:
            ext = str(item["ext_id"])
            if not ext or ext in seen:
                raise ValueError(f"{source}: missing or duplicate id {ext!r}")
            seen.add(ext)
        log, added = [], []
        self.db.execute("BEGIN IMMEDIATE")
        try:
            known = self.tasks(source)
            active = self.db.execute("SELECT task_id FROM active").fetchone()
            running = active[0] if active else None
            for item in items:
                ext = str(item["ext_id"])
                title = Store.title(item["title"][:240])
                note = Store.note(item.get("note") or "")
                link = item.get("link") or ""
                tag = WAITING_TAG if item.get("waiting") else ""
                row = known.get(ext)
                if row is None:
                    if tag:
                        self._ensure_tag(tag)
                    task_id = self.db.execute(
                        "INSERT INTO tasks(title, created_day, note, tag, source, ext_id, link) VALUES(?,?,?,?,?,?,?)",
                        (title, self.today, note, tag, source, ext, link)).lastrowid
                    self.db.execute("INSERT INTO days(task_id, day, title) VALUES(?,?,?)", (task_id, self.today, title))
                    added.append(task_id)
                    log.append(f"add      {title}" + (f"  [{tag}]" if tag else ""))
                    continue
                if not self.is_open(row):
                    if row["closed_by"] != "sync":
                        continue  # closed by hand: yours, never revived
                    self.db.execute("UPDATE tasks SET archived=0, closed_by='' WHERE id=?", (row["id"],))
                    self.db.execute("INSERT OR IGNORE INTO days(task_id, day, title) VALUES(?,?,?)",
                                    (row["id"], self.today, row["title"]))
                    self.db.execute("UPDATE days SET completed=0 WHERE task_id=? AND day=?", (row["id"], self.today))
                    log.append(f"back     {row['title']}  (open again at the source)")
                if title != row["title"] and not row["title_hand"]:
                    self.db.execute("UPDATE tasks SET title=? WHERE id=?", (title, row["id"]))
                    self.db.execute("UPDATE days SET title=? WHERE task_id=? AND day=?", (title, row["id"], self.today))
                    log.append(f"rename   {row['title']}  ->  {title}")
                if note != row["note"] and not row["note_hand"]:
                    self.db.execute("UPDATE tasks SET note=? WHERE id=?", (note, row["id"]))
                    log.append(f"note     {title}")
                if link != row["link"]:
                    self.db.execute("UPDATE tasks SET link=? WHERE id=?", (link, row["id"]))
                if tag != row["tag"] and not row["tag_hand"] and row["tag"] in ("", WAITING_TAG):
                    if tag:
                        self._ensure_tag(tag)
                    self.db.execute("UPDATE tasks SET tag=? WHERE id=?", (tag, row["id"]))
                    log.append(f"tag      {title}  ->  {tag or 'no tag'}")
            for ext, row in known.items():
                if ext in seen or not self.is_open(row):
                    continue
                if row["id"] == running:
                    log.append(f"wait     {row['title']}  (timer running - closes next run)")
                    continue
                self.db.execute("UPDATE days SET completed=1 WHERE task_id=? AND day=?", (row["id"], self.today))
                self.db.execute("UPDATE tasks SET closed_by='sync' WHERE id=?", (row["id"],))
                log.append(f"close    {row['title']}  (closed at the source)")
            if added:
                # New work goes to the top of the manual order, keeping the given order among itself.
                low = self.db.execute("SELECT COALESCE(MIN(position), 0) FROM tasks WHERE id NOT IN (%s)"
                                      % ",".join("?" * len(added)), added).fetchone()[0]
                for i, task_id in enumerate(added):
                    self.db.execute("UPDATE tasks SET position=? WHERE id=?", (low - len(added) + i, task_id))
        except BaseException:
            self.db.execute("ROLLBACK")
            raise
        self.db.execute("COMMIT" if apply else "ROLLBACK")
        return log
