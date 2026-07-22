import re
import sqlite3
import unittest
from pathlib import Path


DATABASE_PM = Path(__file__).parents[1] / "patio" / "lib" / "LetterBBS" / "Database.pm"
POST_PM = Path(__file__).parents[1] / "patio" / "lib" / "LetterBBS" / "Model" / "Post.pm"


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


def load_fts_trigger_sql(name):
    source = DATABASE_PM.read_text(encoding="utf-8")
    match = re.search(
        rf'\$dbh->do\("(CREATE TRIGGER IF NOT EXISTS {name}.*?END\s*)"\);',
        source,
        re.DOTALL,
    )
    if not match:
        raise AssertionError(f"{name} SQL was not found in Database.pm")
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


class SearchConsistencyTest(unittest.TestCase):
    def setUp(self):
        self.db = sqlite3.connect(":memory:")
        self.addCleanup(self.db.close)
        try:
            self.db.executescript(
                """
                CREATE TABLE threads (
                    id INTEGER PRIMARY KEY,
                    subject TEXT NOT NULL,
                    author TEXT NOT NULL,
                    status TEXT NOT NULL DEFAULT 'active'
                );
                CREATE TABLE posts (
                    id INTEGER PRIMARY KEY,
                    thread_id INTEGER NOT NULL,
                    seq_no INTEGER NOT NULL,
                    subject TEXT NOT NULL,
                    body TEXT NOT NULL,
                    author TEXT NOT NULL,
                    is_deleted INTEGER NOT NULL DEFAULT 0
                );
                CREATE VIRTUAL TABLE posts_fts USING fts5(
                    subject, body, author,
                    content='posts', content_rowid='id', tokenize='unicode61'
                );
                """
            )
        except sqlite3.OperationalError as error:
            self.skipTest(f"SQLite FTS5 is unavailable: {error}")

        for name in ("trg_fts_insert", "trg_fts_delete", "trg_fts_update"):
            self.db.execute(load_fts_trigger_sql(name))
        self.db.execute(
            "INSERT INTO threads (id, subject, author, status) VALUES (1, 'thread', 'parent', 'active')"
        )

    def search(self, keyword):
        return self.db.execute(
            """
            SELECT p.id FROM posts_fts
            JOIN posts p ON p.id = posts_fts.rowid
            JOIN threads t ON t.id = p.thread_id
            WHERE posts_fts MATCH ?
              AND t.status != 'deleted'
              AND p.is_deleted = 0
            """,
            (f'"{keyword}"',),
        ).fetchall()

    def test_create_edit_and_soft_delete_stay_search_consistent(self):
        self.db.execute(
            """
            INSERT INTO posts (id, thread_id, seq_no, subject, body, author, is_deleted)
            VALUES (1, 1, 0, 'CREATED_TOKEN', 'before EDIT_OLD_TOKEN', 'author', 0)
            """
        )
        self.assertEqual(self.search("CREATED_TOKEN"), [(1,)])
        self.assertEqual(self.search("EDIT_OLD_TOKEN"), [(1,)])

        self.db.execute("UPDATE posts SET body = 'after EDIT_NEW_TOKEN' WHERE id = 1")
        self.assertEqual(self.search("EDIT_OLD_TOKEN"), [])
        self.assertEqual(self.search("EDIT_NEW_TOKEN"), [(1,)])

        self.db.execute(
            "UPDATE posts SET body = 'この投稿は削除されました。', is_deleted = 1 WHERE id = 1"
        )
        self.assertEqual(self.search("EDIT_NEW_TOKEN"), [])

    def test_model_search_paths_both_filter_deleted_posts(self):
        source = POST_PM.read_text(encoding="utf-8")
        fts = re.search(r"sub search_fts\s*\{(.*?)\n\}", source, re.DOTALL)
        like = re.search(r"sub search_like\s*\{(.*?)\n\}", source, re.DOTALL)
        self.assertIsNotNone(fts)
        self.assertIsNotNone(like)
        self.assertIn("p.is_deleted = 0", fts.group(1))
        self.assertIn("p.is_deleted = 0", like.group(1))

    def test_schema_v3_rebuilds_the_fts_index_once(self):
        source = DATABASE_PM.read_text(encoding="utf-8")
        self.assertRegex(source, r"sub _migrate_v3\b")
        self.assertRegex(
            source,
            r"INSERT INTO posts_fts\(posts_fts\) VALUES \('rebuild'\)",
        )


if __name__ == "__main__":
    unittest.main()
