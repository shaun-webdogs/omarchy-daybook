#!/usr/bin/env python3
"""Daybook's local, transactional store and JSON-lines timer service. Stdlib only."""

import argparse
import csv
import datetime as dt
import fcntl
import io
import json
import os
from pathlib import Path
import select
import signal
import sqlite3
import sys
import time


def day_at(milliseconds):
    return dt.datetime.fromtimestamp(milliseconds / 1000).date().isoformat()


def next_midnight(milliseconds):
    tomorrow = dt.date.fromisoformat(day_at(milliseconds)) + dt.timedelta(days=1)
    return round(dt.datetime.combine(tomorrow, dt.time()).timestamp() * 1000)


def data_directory():
    return Path(os.environ.get("XDG_DATA_HOME", str(Path.home() / ".local/share"))) / "omarchy-daybook"


class Store:
    def __init__(self, path, now=None):
        self.now = now or (lambda: time.time_ns() // 1_000_000)
        self.path = Path(path)
        self.path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
        self.db = sqlite3.connect(self.path, timeout=5)
        self.db.row_factory = sqlite3.Row
        self.db.execute("PRAGMA journal_mode=WAL")
        self.db.execute("PRAGMA synchronous=FULL")
        self.db.execute("PRAGMA foreign_keys=ON")
        version = self.db.execute("PRAGMA user_version").fetchone()[0]
        if version not in (0, 1):
            raise ValueError("This database requires a newer version of Daybook.")
        self.db.executescript("""
            CREATE TABLE IF NOT EXISTS tasks (
                id INTEGER PRIMARY KEY, title TEXT NOT NULL,
                created_day TEXT NOT NULL, archived INTEGER NOT NULL DEFAULT 0
            );
            CREATE TABLE IF NOT EXISTS days (
                task_id INTEGER NOT NULL REFERENCES tasks(id), day TEXT NOT NULL,
                title TEXT NOT NULL, elapsed_ms INTEGER NOT NULL DEFAULT 0 CHECK(elapsed_ms >= 0),
                completed INTEGER NOT NULL DEFAULT 0,
                PRIMARY KEY(task_id, day)
            );
            CREATE INDEX IF NOT EXISTS days_by_date ON days(day);
            CREATE TABLE IF NOT EXISTS active (
                slot INTEGER PRIMARY KEY CHECK(slot = 1),
                task_id INTEGER NOT NULL REFERENCES tasks(id), checkpoint_ms INTEGER NOT NULL
            );
            CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);
            PRAGMA user_version=1;
        """)
        # Added columns keep user_version 1: older readers ignore them, and sync scripts still open the file.
        columns = {row[1] for row in self.db.execute("PRAGMA table_info(tasks)")}
        with self.db:
            if "position" not in columns:
                self.db.execute("ALTER TABLE tasks ADD COLUMN position INTEGER")
            if "note" not in columns:
                self.db.execute("ALTER TABLE tasks ADD COLUMN note TEXT NOT NULL DEFAULT ''")
            self._adopt_positions()
        self.notice = ""
        # Checkpoints already include their time in days. Never count offline time.
        with self.db:
            if self.db.execute("SELECT 1 FROM active").fetchone():
                self.notice = "Timer paused after restart. Your recorded time is safe; press play to continue."
                self.db.execute("DELETE FROM active")
            self._rollover(self.now())

    def _rollover(self, now):
        today = day_at(now)
        row = self.db.execute("SELECT value FROM meta WHERE key='day'").fetchone()
        previous = row[0] if row else today
        # A clock correction must not move the rollover cursor backwards.
        while previous < today:
            following = (dt.date.fromisoformat(previous) + dt.timedelta(days=1)).isoformat()
            self.db.execute("""
                INSERT OR IGNORE INTO days(task_id, day, title)
                SELECT d.task_id, ?, t.title FROM days d JOIN tasks t ON t.id=d.task_id
                WHERE d.day=? AND d.completed=0 AND t.archived=0
            """, (following, previous))
            previous = following
        if not row or previous != row[0]:
            self.db.execute("INSERT OR REPLACE INTO meta VALUES('day', ?)", (max(previous, today),))

    def _adopt_positions(self):
        # Tasks written by other tools have no position; queue them after everything else in id order.
        if self.db.execute("SELECT 1 FROM tasks WHERE position IS NULL LIMIT 1").fetchone():
            self.db.execute("UPDATE tasks SET position=id+(SELECT COALESCE(MAX(position),0) FROM tasks) WHERE position IS NULL")

    def _move(self, task_id, where, today):
        # Reorder inside the task's own group (open or completed) by reusing that group's position values.
        completed = self.db.execute("SELECT completed FROM days WHERE task_id=? AND day=?", (task_id, today)).fetchone()
        if not completed:
            raise ValueError("Add this task to today first.")
        group = [row[0] for row in self.db.execute("""
            SELECT t.id FROM days d JOIN tasks t ON t.id=d.task_id
            WHERE d.day=? AND d.completed=? AND t.archived=0 ORDER BY t.position, t.id
        """, (today, completed[0]))]
        slots = sorted(row[0] for row in self.db.execute(
            "SELECT position FROM tasks WHERE id IN (%s)" % ",".join("?" * len(group)), group))
        index = group.index(task_id)
        target = {"up": index - 1, "down": index + 1, "top": 0, "bottom": len(group) - 1}.get(where)
        if target is None:
            raise ValueError("Move a task up, down, top or bottom.")
        target = max(0, min(len(group) - 1, target))
        group.insert(target, group.pop(index))
        for slot, moved in zip(slots, group):
            self.db.execute("UPDATE tasks SET position=? WHERE id=?", (slot, moved))

    @staticmethod
    def milliseconds(value):
        if type(value) is not int or value < 0 or value > 86_400_000:
            raise ValueError("Enter a time between 0 and 24 hours.")
        return value

    @staticmethod
    def note(value):
        if not isinstance(value, str):
            raise ValueError("Enter a note.")
        value = value.replace("\r\n", "\n").strip()
        if len(value) > 4000:
            raise ValueError("Keep notes under 4000 characters.")
        return value

    def _checkpoint(self, now):
        active = self.db.execute("SELECT * FROM active").fetchone()
        if active:
            start = active["checkpoint_ms"]
            gap = now - start
            # Sleep, hibernation and large clock jumps are not focus time.
            if gap < 0 or gap > 15_000:
                self.db.execute("DELETE FROM active")
                self.notice = "Timer paused during sleep or a clock change. Recorded time is saved."
            else:
                task = self.db.execute("SELECT title FROM tasks WHERE id=?", (active["task_id"],)).fetchone()
                while start < now:
                    end = min(now, next_midnight(start))
                    day = day_at(start)
                    self.db.execute("INSERT OR IGNORE INTO days(task_id, day, title) VALUES(?,?,?)",
                                    (active["task_id"], day, task["title"]))
                    self.db.execute("UPDATE days SET elapsed_ms=elapsed_ms+? WHERE task_id=? AND day=?",
                                    (end - start, active["task_id"], day))
                    start = end
                self.db.execute("UPDATE active SET checkpoint_ms=?", (now,))
        self._rollover(now)

    def tick(self):
        with self.db:
            self._checkpoint(self.now())
            self._adopt_positions()

    @staticmethod
    def title(value):
        if not isinstance(value, str):
            raise ValueError("Enter a task name.")
        value = " ".join(value.split())
        if not value or len(value) > 240:
            raise ValueError("Use a task name between 1 and 240 characters.")
        return value

    def command(self, request):
        if not isinstance(request, dict):
            raise ValueError("Expected a JSON object.")
        action = request.get("action")
        now = self.now()
        today = day_at(now)
        result = {}
        with self.db:
            self._checkpoint(now)
            if action == "add":
                title = self.title(request.get("title"))
                task_id = self.db.execute("INSERT INTO tasks(title, created_day, position) VALUES(?,?,(SELECT COALESCE(MAX(position),0)+1 FROM tasks))", (title, today)).lastrowid
                self.db.execute("INSERT INTO days(task_id, day, title) VALUES(?,?,?)", (task_id, today, title))
                result["taskId"] = task_id
            elif action in ("start", "complete", "reopen", "rename", "archive", "restore", "move", "setTime", "setNote"):
                task_id = request.get("taskId")
                if type(task_id) is not int:
                    raise ValueError("Invalid task.")
                task = self.db.execute("SELECT * FROM tasks WHERE id=?", (task_id,)).fetchone()
                if not task:
                    raise ValueError("This task could not be found.")
                if action == "setNote":
                    self.db.execute("UPDATE tasks SET note=? WHERE id=?", (self.note(request.get("note")), task_id))
                elif action == "setTime":
                    day = request.get("day") or today
                    if not isinstance(day, str) or dt.date.fromisoformat(day).isoformat() != day or day > today:
                        raise ValueError("Choose today or a previous date (YYYY-MM-DD).")
                    elapsed = self.milliseconds(request.get("elapsed_ms"))
                    if not self.db.execute("SELECT 1 FROM days WHERE task_id=? AND day=?", (task_id, day)).fetchone():
                        raise ValueError("This task has no entry on that day.")
                    self.db.execute("UPDATE days SET elapsed_ms=? WHERE task_id=? AND day=?", (elapsed, task_id, day))
                elif action == "move":
                    if task["archived"]:
                        raise ValueError("Bring this task back to today before moving it.")
                    self._move(task_id, request.get("to"), today)
                elif action == "restore":
                    self.db.execute("UPDATE tasks SET archived=0 WHERE id=?", (task_id,))
                    self.db.execute("INSERT OR IGNORE INTO days(task_id, day, title) VALUES(?,?,?)", (task_id, today, task["title"]))
                    self.db.execute("UPDATE days SET completed=0 WHERE task_id=? AND day=?", (task_id, today))
                elif action == "archive":
                    self.db.execute("UPDATE tasks SET archived=1 WHERE id=?", (task_id,))
                    self.db.execute("DELETE FROM active WHERE task_id=?", (task_id,))
                else:
                    entry = self.db.execute("SELECT * FROM days WHERE task_id=? AND day=?", (task_id, today)).fetchone()
                    if not entry or task["archived"]:
                        raise ValueError("Add this task to today first.")
                    if action == "start":
                        if entry["completed"]:
                            raise ValueError("Reopen this task before starting its timer.")
                        self.db.execute("INSERT OR REPLACE INTO active VALUES(1,?,?)", (task_id, now))
                        self.notice = ""
                    elif action in ("complete", "reopen"):
                        self.db.execute("UPDATE days SET completed=? WHERE task_id=? AND day=?", (int(action == "complete"), task_id, today))
                        if action == "complete":
                            self.db.execute("DELETE FROM active WHERE task_id=?", (task_id,))
                    else:
                        title = self.title(request.get("title"))
                        self.db.execute("UPDATE tasks SET title=? WHERE id=?", (title, task_id))
                        self.db.execute("UPDATE days SET title=? WHERE task_id=? AND day=?", (title, task_id, today))
            elif action == "pause":
                self.db.execute("DELETE FROM active")
            elif action == "setPanel":
                for key in ("width", "height"):
                    value = request.get(key, 0)
                    if type(value) is not int or value < 0 or value > 8000:
                        raise ValueError("Panel size must be a whole number of pixels.")
                    self.db.execute("INSERT OR REPLACE INTO meta VALUES(?, ?)", ("panel_" + key, str(value)))
            elif action == "dismiss":
                self.notice = ""
            elif action != "snapshot":
                raise ValueError("Unknown action.")
        return result

    def snapshot(self, selected=None):
        today = day_at(self.now())
        selected = selected or today
        if dt.date.fromisoformat(selected).isoformat() != selected or selected > today:
            raise ValueError("Choose today or a previous date (YYYY-MM-DD).")
        active = self.db.execute("SELECT task_id FROM active").fetchone()
        active_id = active[0] if active else 0
        def rows_for(day):
            rows = [dict(row) for row in self.db.execute("""
                SELECT d.*, t.archived, t.note FROM days d JOIN tasks t ON t.id=d.task_id
                WHERE day=? ORDER BY t.archived, d.completed, t.position, d.task_id
            """, (day,))]
            for row in rows:
                row["running"] = row["task_id"] == active_id and day == today
            return rows
        rows = rows_for(selected)
        today_rows = rows if selected == today else rows_for(today)
        summary = dict(self.db.execute("""
            SELECT COALESCE(SUM(d.elapsed_ms),0) elapsed_ms,
                   COALESCE(SUM(CASE WHEN t.archived=0 THEN 1 ELSE 0 END),0) total,
                   COALESCE(SUM(CASE WHEN t.archived=0 THEN d.completed ELSE 0 END),0) completed
            FROM days d JOIN tasks t ON t.id=d.task_id WHERE day=?
        """, (today,)).fetchone())
        active_row = self.db.execute("SELECT * FROM days WHERE day=? AND task_id=?", (today, active_id)).fetchone()
        dates = [row[0] for row in self.db.execute("SELECT DISTINCT day FROM days ORDER BY day DESC")]
        week_start = (dt.date.fromisoformat(selected) - dt.timedelta(days=6)).isoformat()
        totals = {row["day"]: row["elapsed_ms"] for row in self.db.execute(
            "SELECT day, SUM(elapsed_ms) elapsed_ms FROM days WHERE day BETWEEN ? AND ? GROUP BY day", (week_start, selected))}
        week = []
        for offset in range(7):
            date = (dt.date.fromisoformat(week_start) + dt.timedelta(days=offset)).isoformat()
            week.append({"day": date, "elapsed_ms": totals.get(date, 0)})
        panel = {row[0][6:]: int(row[1]) for row in self.db.execute("SELECT key, value FROM meta WHERE key IN ('panel_width','panel_height')")}
        return {"today": today, "selected": selected, "tasks": rows, "today_tasks": today_rows, "dates": dates,
                "active": dict(active_row) if active_row else None, "summary": summary,
                "week": week, "notice": self.notice, "database": str(self.path),
                "panel": {"width": panel.get("width", 0), "height": panel.get("height", 0)}}

    def export_csv(self):
        output = io.StringIO()
        writer = csv.writer(output)
        writer.writerow(["date", "task_id", "task", "seconds", "duration", "status"])
        for row in self.db.execute("SELECT * FROM days ORDER BY day, task_id"):
            seconds = row["elapsed_ms"] // 1000
            title = row["title"]
            # Make task names safe to open in spreadsheet applications.
            if title.startswith(("=", "+", "-", "@")):
                title = "'" + title
            writer.writerow([row["day"], row["task_id"], title, f'{row["elapsed_ms"] / 1000:.3f}',
                             f"{seconds // 3600:02}:{seconds // 60 % 60:02}:{seconds % 60:02}",
                             "completed" if row["completed"] else "unfinished"])
        return output.getvalue()


def serve(path):
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    # Only one service writes timers, even with multiple monitors or hot reloads.
    with path.with_suffix(".lock").open("a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        store = Store(path)
        selected = None
        alive = True
        buffer = b""
        def stop(*_):
            nonlocal alive
            alive = False
        signal.signal(signal.SIGTERM, stop)
        signal.signal(signal.SIGINT, stop)
        def emit(**extra):
            print(json.dumps({"ok": True, "state": store.snapshot(selected), **extra}, ensure_ascii=False), flush=True)
        try:
            emit()
            last_emit = time.monotonic()
            while alive:
                ready, _, _ = select.select([sys.stdin], [], [], 1)
                if ready:
                    chunk = os.read(sys.stdin.fileno(), 65536)
                    if not chunk:
                        break
                    buffer += chunk
                    if len(buffer) > 1_000_000:
                        raise ValueError("Request too large.")
                    while b"\n" in buffer:
                        line, buffer = buffer.split(b"\n", 1)
                        request = {}
                        try:
                            request = json.loads(line)
                            if not isinstance(request, dict):
                                raise ValueError("Expected an object.")
                            if "date" in request:
                                desired = request["date"] or None
                                store.snapshot(desired)  # validate before changing selection
                                selected = desired
                            if request.get("action") == "export":
                                store.tick()
                                export_dir = path.parent / "exports"
                                export_dir.mkdir(exist_ok=True, mode=0o700)
                                export_path = export_dir / ("daybook-" + dt.datetime.now().strftime("%Y%m%d-%H%M%S-%f") + ".csv")
                                with export_path.open("x", newline="", encoding="utf-8") as output:
                                    output.write(store.export_csv())
                                emit(requestId=request.get("requestId"), exported=str(export_path))
                            else:
                                result = store.command(request)
                                emit(requestId=request.get("requestId"), **result)
                        except (ValueError, TypeError, OSError, sqlite3.Error) as error:
                            print(json.dumps({"ok": False, "error": str(error), "requestId": request.get("requestId") if isinstance(request, dict) else None}), flush=True)
                store.tick()
                if time.monotonic() - last_emit >= 1:
                    emit()
                    last_emit = time.monotonic()
        finally:
            with store.db:
                store._checkpoint(store.now())
                store.db.execute("DELETE FROM active")
            store.db.close()


def main():
    os.umask(0o077)
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--database", type=Path, default=data_directory() / "daybook.sqlite3")
    parser.add_argument("--serve", action="store_true")
    parser.add_argument("--export", action="store_true", help="Read all saved days as CSV without changing the running timer")
    args = parser.parse_args()
    if args.serve:
        serve(args.database)
    elif args.export:
        # A read-only connection never performs restart recovery or rollover.
        store = Store.__new__(Store)
        store.db = sqlite3.connect(args.database.resolve().as_uri() + "?mode=ro", uri=True)
        store.db.row_factory = sqlite3.Row
        try:
            print(store.export_csv(), end="")
        finally:
            store.db.close()
    else:
        parser.print_help()


if __name__ == "__main__":
    try:
        main()
    except BrokenPipeError:
        pass
    except (OSError, ValueError, sqlite3.Error) as error:
        print(json.dumps({"ok": False, "error": str(error)}), flush=True)
        sys.exit(1)
