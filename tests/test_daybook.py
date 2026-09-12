import datetime as dt
import io
import csv
import json
import os
from pathlib import Path
import select
import sqlite3
import subprocess
import sys
import tempfile
import time
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from daybook import Store, day_at, next_midnight


class StoreTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.path = Path(self.temp.name) / "test.sqlite3"
        self.now = int(dt.datetime(2026, 9, 6, 12).timestamp() * 1000)
        self.store = Store(self.path, now=lambda: self.now)

    def tearDown(self):
        self.store.db.close()
        self.temp.cleanup()

    def command(self, action, **values):
        return self.store.command({"action": action, **values})

    def add(self, title="Write the first draft"):
        return self.command("add", title=title)["taskId"]

    def advance(self, seconds):
        for _ in range(seconds):
            self.now += 1000
            self.store.tick()

    def test_zero_time_is_immediately_durable(self):
        task = self.add()
        with sqlite3.connect(self.path) as independent:
            self.assertEqual(independent.execute("SELECT elapsed_ms, completed FROM days WHERE task_id=?", (task,)).fetchone(), (0, 0))

    def test_complete_reopen_appends_without_reset(self):
        task = self.add()
        self.command("start", taskId=task)
        self.advance(70)
        self.command("complete", taskId=task)
        self.advance(30)
        self.command("reopen", taskId=task)
        self.command("start", taskId=task)
        self.advance(25)
        self.command("complete", taskId=task)
        row = self.store.snapshot()["tasks"][0]
        self.assertEqual(row["elapsed_ms"], 95_000)
        self.assertEqual(row["completed"], 1)
        self.assertIsNone(self.store.snapshot()["active"])

    def test_switching_timer_pauses_previous(self):
        first, second = self.add("First"), self.add("Second")
        self.command("start", taskId=first)
        self.advance(7)
        self.command("start", taskId=second)
        self.advance(3)
        self.command("pause")
        rows = self.store.snapshot()["tasks"]
        self.assertEqual([r["elapsed_ms"] for r in rows], [7000, 3000])

    def test_unfinished_and_zero_carry_through_offline_days(self):
        self.command("setSort", sort="manual")
        self.add("Untimed")
        task = self.add("Timed")
        self.command("start", taskId=task)
        self.advance(10)
        self.command("pause")
        done = self.add("Done")
        self.command("complete", taskId=done)
        self.now += 3 * 86400 * 1000
        self.store.tick()
        self.assertEqual(len(self.store.snapshot()["tasks"]), 2)
        for day in ("2026-09-07", "2026-09-08", "2026-09-09"):
            self.assertEqual([r["elapsed_ms"] for r in self.store.snapshot(day)["tasks"]], [0, 0])
        self.assertEqual(self.store.snapshot("2026-09-06")["tasks"][1]["elapsed_ms"], 10000)

    def test_midnight_splits_active_session(self):
        self.now = int(dt.datetime(2026, 9, 6, 23, 59, 57).timestamp() * 1000)
        task = self.add()
        self.command("start", taskId=task)
        self.now += 8000
        self.store.tick()
        self.assertEqual(self.store.snapshot("2026-09-06")["tasks"][0]["elapsed_ms"], 3000)
        self.assertEqual(self.store.snapshot()["tasks"][0]["elapsed_ms"], 5000)
        self.assertIsNotNone(self.store.snapshot()["active"])

    def test_restart_recovers_checkpoint_without_counting_offline(self):
        task = self.add()
        self.command("start", taskId=task)
        self.advance(8)
        self.store.db.close()
        self.now += 3600 * 1000
        self.store = Store(self.path, now=lambda: self.now)
        self.assertEqual(self.store.snapshot()["tasks"][0]["elapsed_ms"], 8000)
        self.assertIsNone(self.store.snapshot()["active"])
        self.assertIn("restart", self.store.notice)

    def test_sleep_gap_pauses_without_inflating_time(self):
        task = self.add()
        self.command("start", taskId=task)
        self.advance(5)
        self.now += 3600 * 1000
        self.store.tick()
        self.assertEqual(self.store.snapshot()["tasks"][0]["elapsed_ms"], 5000)
        self.assertIsNone(self.store.snapshot()["active"])

    def test_backwards_clock_pauses_and_never_subtracts(self):
        task = self.add()
        self.command("start", taskId=task)
        self.advance(5)
        self.now -= 10000
        self.store.tick()
        self.assertEqual(self.store.snapshot()["tasks"][0]["elapsed_ms"], 5000)
        self.assertIsNone(self.store.snapshot()["active"])

    def test_archive_and_restore_keep_history(self):
        task = self.add()
        self.command("start", taskId=task)
        self.advance(5)
        self.command("archive", taskId=task)
        self.assertEqual(self.store.snapshot()["summary"]["total"], 0)
        self.assertEqual(self.store.snapshot()["summary"]["elapsed_ms"], 5000)
        self.now += 86400 * 1000
        self.store.tick()
        self.assertEqual(self.store.snapshot()["tasks"], [])
        self.command("restore", taskId=task)
        self.assertEqual(self.store.snapshot()["tasks"][0]["elapsed_ms"], 0)
        self.assertEqual(self.store.snapshot("2026-09-06")["tasks"][0]["elapsed_ms"], 5000)

    def test_rename_preserves_past_title(self):
        task = self.add("Old title")
        self.now += 86400 * 1000
        self.store.tick()
        self.command("rename", taskId=task, title="New title")
        self.assertEqual(self.store.snapshot()["tasks"][0]["title"], "New title")
        self.assertEqual(self.store.snapshot("2026-09-06")["tasks"][0]["title"], "Old title")

    def test_duplicate_names_have_independent_timers(self):
        self.command("setSort", sort="manual")
        first, second = self.add("Same"), self.add("Same")
        self.assertNotEqual(first, second)
        self.command("start", taskId=second)
        self.advance(2)
        self.assertEqual([r["elapsed_ms"] for r in self.store.snapshot()["tasks"]], [0, 2000])

    def test_invalid_requests_do_not_create_or_reset_tasks(self):
        for title in ("", "  ", "x" * 241, None):
            with self.assertRaises(ValueError):
                self.add(title)
        task = self.add()
        self.command("complete", taskId=task)
        with self.assertRaises(ValueError):
            self.command("start", taskId=task)
        with self.assertRaises(ValueError):
            self.command("reopen", taskId=999)
        with self.assertRaises(ValueError):
            self.store.snapshot("2999-01-01")
        self.assertEqual(len(self.store.snapshot()["tasks"]), 1)

    def test_export_zero_time_unicode_and_formula_safety(self):
        self.add("=SUM(A1:A2)")
        self.add('Plan, "review" ☕')
        rows = list(csv.reader(io.StringIO(self.store.export_csv())))
        self.assertEqual(rows[1][2], "'=SUM(A1:A2)")
        self.assertEqual(rows[2][2], 'Plan, "review" ☕')
        self.assertEqual(rows[2][3:], ["0.000", "00:00:00", "unfinished"])

    def test_subsecond_time_is_preserved(self):
        task = self.add()
        self.command("start", taskId=task)
        self.now += 432
        self.command("pause")
        self.command("start", taskId=task)
        self.now += 789
        self.command("complete", taskId=task)
        self.assertEqual(self.store.snapshot()["tasks"][0]["elapsed_ms"], 1221)

    def test_dst_midnight_length_uses_local_calendar(self):
        prior = os.environ.get("TZ")
        try:
            os.environ["TZ"] = "America/New_York"
            time.tzset()
            start = round(dt.datetime(2026, 3, 8).timestamp() * 1000)
            self.assertEqual(next_midnight(start) - start, 23 * 3600000)
            start = round(dt.datetime(2026, 11, 1).timestamp() * 1000)
            self.assertEqual(next_midnight(start) - start, 25 * 3600000)
        finally:
            if prior is None:
                os.environ.pop("TZ", None)
            else:
                os.environ["TZ"] = prior
            time.tzset()

    def test_set_time_edits_today_and_past_days(self):
        task = self.add()
        self.command("start", taskId=task)
        self.advance(5)
        self.command("setTime", taskId=task, elapsed_ms=90_000)
        self.advance(2)
        self.assertEqual(self.store.snapshot()["tasks"][0]["elapsed_ms"], 92_000)
        self.assertIsNotNone(self.store.snapshot()["active"])
        self.now += 86400 * 1000
        self.store.tick()
        self.command("setTime", taskId=task, elapsed_ms=1_000, day="2026-09-06")
        self.assertEqual(self.store.snapshot("2026-09-06")["tasks"][0]["elapsed_ms"], 1_000)
        for bad in ({"elapsed_ms": -1}, {"elapsed_ms": 86_400_001}, {"elapsed_ms": "5"}, {"elapsed_ms": 0, "day": "2999-01-01"}, {"elapsed_ms": 0, "day": "2026-09-01"}):
            with self.assertRaises(ValueError):
                self.command("setTime", taskId=task, **bad)

    def test_notes_are_saved_per_task(self):
        task = self.add()
        self.command("setNote", taskId=task, note="  Call back after 2pm\r\nAsk about invoice  ")
        self.assertEqual(self.store.snapshot()["tasks"][0]["note"], "Call back after 2pm\nAsk about invoice")
        self.command("setNote", taskId=task, note="")
        self.assertEqual(self.store.snapshot()["tasks"][0]["note"], "")
        with self.assertRaises(ValueError):
            self.command("setNote", taskId=task, note="x" * 4001)
        with self.assertRaises(ValueError):
            self.command("setNote", taskId=task, note=None)

    def titles(self, day=None):
        return [r["title"] for r in self.store.snapshot(day)["tasks"]]

    def test_time_sort_is_default_and_follows_the_timer(self):
        self.assertEqual(self.store.snapshot()["sort"], "time")
        first, second, third = self.add("First"), self.add("Second"), self.add("Third")
        self.assertEqual(self.titles(), ["First", "Second", "Third"])
        self.command("start", taskId=third)
        self.advance(3)
        self.assertEqual(self.titles(), ["Third", "First", "Second"])
        self.command("start", taskId=second)
        self.advance(5)
        self.assertEqual(self.titles(), ["Second", "Third", "First"])
        self.command("complete", taskId=second)
        self.assertEqual(self.titles(), ["Third", "First", "Second"])
        self.command("setSort", sort="manual")
        self.assertEqual(self.store.snapshot()["sort"], "manual")
        self.assertEqual(self.titles(), ["First", "Third", "Second"])
        with self.assertRaises(ValueError):
            self.command("setSort", sort="alphabetical")

    def test_move_reorders_within_open_and_completed_groups(self):
        self.command("setSort", sort="manual")
        for title in "ABCD":
            self.add(title)
        self.command("move", taskId=3, to="up")
        self.assertEqual(self.titles(), ["A", "C", "B", "D"])
        self.command("move", taskId=4, to="top")
        self.assertEqual(self.titles(), ["D", "A", "C", "B"])
        self.command("move", taskId=4, to="bottom")
        self.assertEqual(self.titles(), ["A", "C", "B", "D"])
        self.command("move", taskId=1, to="up")  # already first: no change, no error
        self.assertEqual(self.titles(), ["A", "C", "B", "D"])
        self.command("complete", taskId=3)
        self.command("complete", taskId=1)
        self.assertEqual(self.titles(), ["B", "D", "A", "C"])
        self.command("move", taskId=3, to="up")
        self.assertEqual(self.titles(), ["B", "D", "C", "A"])
        self.command("reopen", taskId=3)
        self.assertEqual(self.titles(), ["C", "B", "D", "A"])
        with self.assertRaises(ValueError):
            self.command("move", taskId=2, to="sideways")
        self.now += 86400 * 1000
        self.store.tick()
        self.assertEqual(self.titles(), ["C", "B", "D"])

    def test_tasks_added_by_other_tools_queue_at_the_end(self):
        self.command("setSort", sort="manual")
        self.add("Mine")
        self.store.db.execute("INSERT INTO tasks(title, created_day) VALUES('Synced', '2026-09-06')")
        self.store.db.execute("INSERT INTO days(task_id, day, title) VALUES(2, '2026-09-06', 'Synced')")
        self.store.db.commit()
        self.store.tick()
        self.command("move", taskId=1, to="bottom")
        self.assertEqual(self.titles(), ["Synced", "Mine"])
        self.add("Newer")
        self.assertEqual(self.titles(), ["Synced", "Mine", "Newer"])
        self.assertEqual(self.store.db.execute("PRAGMA user_version").fetchone()[0], 1)

    def test_tags_are_listed_assigned_and_cleared_on_removal(self):
        self.assertEqual(self.store.snapshot()["tags"], ["Awaiting Client", "In Progress", "Blocked"])
        task = self.add()
        self.command("setTag", taskId=task, tag="Awaiting Client")
        self.assertEqual(self.store.snapshot()["tasks"][0]["tag"], "Awaiting Client")
        with self.assertRaises(ValueError):
            self.command("setTag", taskId=task, tag="Not a tag")
        self.command("setTags", tags=["Blocked", " Needs  Review "])
        self.assertEqual(self.store.snapshot()["tags"], ["Blocked", "Needs Review"])
        self.assertEqual(self.store.snapshot()["tasks"][0]["tag"], "")
        self.command("setTag", taskId=task, tag="Needs Review")
        self.command("setTag", taskId=task, tag="")
        self.assertEqual(self.store.snapshot()["tasks"][0]["tag"], "")
        for bad in (["a", "A"], [""], ["x" * 41], "Blocked", [1], ["t"] * 41):
            with self.assertRaises(ValueError):
                self.command("setTags", tags=bad)

    def test_panel_size_is_remembered(self):
        self.assertEqual(self.store.snapshot()["panel"], {"width": 0, "height": 0, "opacity": 100})
        self.command("setPanel", width=900, height=1200)
        self.command("setPanel", opacity=65)
        self.assertEqual(self.store.snapshot()["panel"], {"width": 900, "height": 1200, "opacity": 65})
        for bad in ({"width": -1, "height": 0}, {"width": "wide"}, {"opacity": 101}, {"opacity": 0.5}):
            with self.assertRaises(ValueError):
                self.command("setPanel", **bad)

    def test_existing_database_is_upgraded_in_place(self):
        self.store.db.close()
        path = Path(self.temp.name) / "old.sqlite3"
        with sqlite3.connect(path) as old:
            old.executescript("""
                CREATE TABLE tasks (id INTEGER PRIMARY KEY, title TEXT NOT NULL, created_day TEXT NOT NULL, archived INTEGER NOT NULL DEFAULT 0);
                CREATE TABLE days (task_id INTEGER NOT NULL REFERENCES tasks(id), day TEXT NOT NULL, title TEXT NOT NULL,
                    elapsed_ms INTEGER NOT NULL DEFAULT 0 CHECK(elapsed_ms >= 0), completed INTEGER NOT NULL DEFAULT 0, PRIMARY KEY(task_id, day));
                INSERT INTO tasks(title, created_day) VALUES('Old', '2026-09-06'), ('Older', '2026-09-06');
                INSERT INTO days(task_id, day, title) VALUES(1, '2026-09-06', 'Old'), (2, '2026-09-06', 'Older');
                PRAGMA user_version=1;
            """)
        self.store = Store(path, now=lambda: self.now)
        self.command("setSort", sort="manual")
        self.assertEqual(self.titles(), ["Old", "Older"])
        self.assertEqual(self.store.snapshot()["tasks"][0]["note"], "")
        self.command("move", taskId=2, to="top")
        self.assertEqual(self.titles(), ["Older", "Old"])


class ProtocolTests(unittest.TestCase):
    def test_service_roundtrip_errors_export_and_clean_eof(self):
        with tempfile.TemporaryDirectory() as directory:
            database = Path(directory) / "tasks.sqlite3"
            process = subprocess.Popen([sys.executable, "-B", str(Path(__file__).resolve().parents[1] / "daybook.py"), "--serve", "--database", str(database)], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
            try:
                def response():
                    self.assertTrue(select.select([process.stdout], [], [], 5)[0], "Service failed to reply")
                    return json.loads(process.stdout.readline())
                self.assertTrue(response()["ok"])
                process.stdin.write(json.dumps({"action": "add", "title": "Protocol test", "requestId": 1}) + "\n")
                process.stdin.flush()
                added = response()
                self.assertEqual(added["state"]["tasks"][0]["elapsed_ms"], 0)
                process.stdin.write('null\n')
                process.stdin.flush()
                self.assertFalse(response()["ok"])
                process.stdin.write('{"action":"export","requestId":2}\n')
                process.stdin.flush()
                exported = response()
                self.assertTrue(Path(exported["exported"]).is_file())
                process.stdin.close()
                self.assertEqual(process.wait(timeout=5), 0)
                self.assertEqual(process.stderr.read(), "")
            finally:
                if process.poll() is None:
                    process.terminate()
                    process.wait(timeout=5)
                process.stdout.close()
                process.stderr.close()


if __name__ == "__main__":
    unittest.main()
