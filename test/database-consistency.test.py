import re
import sqlite3
import unittest
from pathlib import Path


DATABASE_PM = Path(__file__).parents[1] / "patio" / "lib" / "LetterBBS" / "Database.pm"


def load_delete_trigger_sql():
    source = DATABASE_PM.read_text(encoding="utf-8")
    match = re.search(
        r'\$dbh->do\("(CREATE TRIGGER IF NOT EXISTS trg_post_count_delete.*?END\s*)"\);',
        source,
        re.DOTALL,
    )
    if not match:
        raise AssertionError("trg_post_count_delete SQL was not found in Database.pm")
    return match.group(1)


def load_v2_backfill_sql():
    source = DATABASE_PM.read_text(encoding="utf-8")
    match = re.search(
        r'\$dbh->do\("(UPDATE threads SET.*?WHERE status = \'active\'\s*)"\);',
        source,
        re.DOTALL,
    )
    if not match:
        raise AssertionError("v2 thread activity backfill SQL was not found in Database.pm")
    return match.group(1)


class DeleteTriggerTest(unittest.TestCase):
    def setUp(self):
        self.db = sqlite3.connect(":memory:")
        self.db.executescript(
            """
            CREATE TABLE threads (
                id INTEGER PRIMARY KEY,
                author TEXT NOT NULL,
                post_count INTEGER NOT NULL,
                last_author TEXT NOT NULL,
                created_at TEXT NOT NULL,
                updated_at TEXT NOT NULL
            );
            CREATE TABLE posts (
                id INTEGER PRIMARY KEY,
                thread_id INTEGER NOT NULL,
                seq_no INTEGER NOT NULL,
                author TEXT NOT NULL,
                is_deleted INTEGER NOT NULL DEFAULT 0,
                created_at TEXT NOT NULL
            );
            INSERT INTO threads
                (id, author, post_count, last_author, created_at, updated_at)
            VALUES
                (1, 'parent', 2, 'latest reply',
                 '2026-07-18 09:00:00', '2026-07-20 11:00:00');
            INSERT INTO posts
                (id, thread_id, seq_no, author, is_deleted, created_at)
            VALUES
                (1, 1, 0, 'parent', 0, '2026-07-18 09:00:00'),
                (2, 1, 1, 'old reply', 0, '2026-07-19 10:00:00'),
                (3, 1, 2, 'latest reply', 0, '2026-07-20 11:00:00');
            """
        )
        self.db.execute(load_delete_trigger_sql())

    def tearDown(self):
        self.db.close()

    def thread_activity(self):
        return self.db.execute(
            "SELECT post_count, last_author, updated_at FROM threads WHERE id = 1"
        ).fetchone()

    def test_deleting_latest_reply_restores_previous_activity(self):
        self.db.execute("UPDATE posts SET is_deleted = 1 WHERE id = 3")
        self.assertEqual(
            self.thread_activity(),
            (1, "old reply", "2026-07-19 10:00:00"),
        )

    def test_deleting_non_latest_reply_keeps_latest_activity(self):
        self.db.execute("UPDATE posts SET is_deleted = 1 WHERE id = 2")
        self.assertEqual(
            self.thread_activity(),
            (1, "latest reply", "2026-07-20 11:00:00"),
        )

    def test_deleting_last_reply_restores_parent_activity(self):
        self.db.execute("UPDATE posts SET is_deleted = 1 WHERE id IN (2, 3)")
        self.assertEqual(
            self.thread_activity(),
            (0, "parent", "2026-07-18 09:00:00"),
        )


class BackfillTest(unittest.TestCase):
    def test_backfill_repairs_only_active_threads(self):
        db = sqlite3.connect(":memory:")
        self.addCleanup(db.close)
        db.executescript(
            """
            CREATE TABLE threads (
                id INTEGER PRIMARY KEY,
                author TEXT NOT NULL,
                status TEXT NOT NULL,
                post_count INTEGER NOT NULL,
                last_author TEXT NOT NULL,
                created_at TEXT NOT NULL,
                updated_at TEXT NOT NULL
            );
            CREATE TABLE posts (
                id INTEGER PRIMARY KEY,
                thread_id INTEGER NOT NULL,
                seq_no INTEGER NOT NULL,
                author TEXT NOT NULL,
                is_deleted INTEGER NOT NULL DEFAULT 0,
                created_at TEXT NOT NULL
            );
            INSERT INTO threads VALUES
                (1, 'parent', 'active', 99, 'deleted author',
                 '2026-07-18 09:00:00', '2026-07-21 12:00:00'),
                (2, 'archived parent', 'archived', 99, 'unchanged',
                 '2026-07-18 08:00:00', '2026-07-21 12:00:00');
            INSERT INTO posts VALUES
                (1, 1, 0, 'parent', 0, '2026-07-18 09:00:00'),
                (2, 1, 1, 'old reply', 0, '2026-07-19 10:00:00'),
                (3, 1, 2, 'deleted author', 1, '2026-07-20 11:00:00');
            """
        )

        db.execute(load_v2_backfill_sql())

        active = db.execute(
            "SELECT post_count, last_author, updated_at FROM threads WHERE id = 1"
        ).fetchone()
        archived = db.execute(
            "SELECT post_count, last_author, updated_at FROM threads WHERE id = 2"
        ).fetchone()
        self.assertEqual(active, (1, "old reply", "2026-07-19 10:00:00"))
        self.assertEqual(archived, (99, "unchanged", "2026-07-21 12:00:00"))


if __name__ == "__main__":
    unittest.main()
