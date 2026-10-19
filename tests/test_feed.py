import datetime as dt
from pathlib import Path
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from daybook import WAITING_TAG, Store
from feed import Feed


def item(ext, title=None, waiting=False, note="", link=""):
    return {"ext_id": ext, "title": title or f"Ticket {ext}", "note": note, "link": link, "waiting": waiting}


class FeedTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.path = Path(self.temp.name) / "test.sqlite3"
        self.now = int(dt.datetime(2026, 10, 19, 12).timestamp() * 1000)
        self.store = Store(self.path, now=lambda: self.now)
        self.feed = Feed(self.path, today="2026-10-19")

    def tearDown(self):
        self.feed.close()
        self.store.db.close()
        self.temp.cleanup()

    def sync(self, *items, apply=True):
        return self.feed.reconcile("zendesk", list(items), apply=apply)

    def rows(self):
        return {r["ext_id"]: r for r in self.feed.tasks("zendesk").values()}

    def ui(self, action, ext, **values):
        return self.store.command({"action": action, "taskId": self.rows()[ext]["id"], **values})

    def test_adds_new_items_to_today_at_the_top(self):
        self.store.command({"action": "add", "title": "Typed by hand"})
        self.sync(item("1", link="https://x/1"), item("2"))
        rows = self.rows()
        self.assertEqual(rows["1"]["link"], "https://x/1")
        order = [r["title"] for r in self.store.snapshot()["tasks"]]
        self.assertEqual(order, ["Ticket 1", "Ticket 2", "Typed by hand"])
        self.assertEqual(self.store.snapshot()["tasks"][0]["origin"], "zendesk")

    def test_dry_run_writes_nothing(self):
        log = self.sync(item("1"), apply=False)
        self.assertEqual(len(log), 1)
        self.assertEqual(self.rows(), {})

    def test_missing_item_closes_and_comes_back_only_if_sync_closed_it(self):
        self.sync(item("1"), item("2"))
        self.sync(item("2"))
        self.assertEqual(self.rows()["1"]["closed_by"], "sync")
        self.assertTrue(self.rows()["1"]["completed"])
        self.sync(item("1"), item("2"))
        self.assertTrue(Feed.is_open(self.rows()["1"]))
        self.ui("complete", "2")
        self.sync(item("1"))
        self.sync(item("1"), item("2"))
        self.assertEqual(self.rows()["2"]["closed_by"], "you")
        self.assertFalse(Feed.is_open(self.rows()["2"]))

    def test_archived_by_hand_stays_archived(self):
        self.sync(item("1"), item("2"))
        self.ui("archive", "1")
        self.sync(item("1"), item("2"))
        self.assertTrue(self.rows()["1"]["archived"])

    def test_hand_edits_win_over_the_source(self):
        self.sync(item("1", note="from source"), item("2"))
        self.ui("rename", "1", title="My name")
        self.ui("setNote", "1", note="my note")
        self.sync(item("1", title="Source rename", note="newer source", waiting=True), item("2", title="Renamed"))
        rows = self.rows()
        self.assertEqual((rows["1"]["title"], rows["1"]["note"]), ("My name", "my note"))
        self.assertEqual(rows["1"]["tag"], WAITING_TAG)
        self.assertEqual(rows["2"]["title"], "Renamed")

    def test_waiting_tag_follows_source_unless_retagged(self):
        self.sync(item("1", waiting=True), item("2", waiting=True))
        self.assertIn(WAITING_TAG, self.store.tags())
        self.ui("setTag", "2", tag="")
        self.sync(item("1"), item("2", waiting=True))
        rows = self.rows()
        self.assertEqual((rows["1"]["tag"], rows["2"]["tag"]), ("", ""))

    def test_running_task_is_not_closed(self):
        self.sync(item("1"), item("2"))
        self.ui("start", "1")
        log = self.sync(item("2"))
        self.assertTrue(any(line.startswith("wait") for line in log))
        self.assertTrue(Feed.is_open(self.rows()["1"]))

    def test_empty_list_is_refused(self):
        self.sync(item("1"))
        with self.assertRaises(ValueError):
            self.sync()
        self.assertTrue(Feed.is_open(self.rows()["1"]))

    def test_sources_do_not_touch_each_other(self):
        self.sync(item("1"))
        self.feed.reconcile("wrike", [item("1")], apply=True)
        self.feed.reconcile("wrike", [item("9")], apply=True)
        self.assertTrue(Feed.is_open(self.rows()["1"]))


if __name__ == "__main__":
    unittest.main()
