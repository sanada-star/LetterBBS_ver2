# LetterBBS ver2 — 詳細設計書: データベース設計

> **文書バージョン**: 1.0
> **作成日**: 2026-03-04

---

## 1. データベース概要

- **DBMS**: SQLite 3
- **ファイル**: `data/letterbbs.db`
- **文字コード**: UTF-8
- **ジャーナルモード**: WAL（Write-Ahead Logging）— 読み取り並行性の向上
- **外部キー制約**: 有効（`PRAGMA foreign_keys = ON`）
- **接続ライブラリ**: DBD::SQLite（Perl DBI経由）

### 1.1 WAL モードを採用する理由

CGI環境では、各リクエストが独立したプロセスとして実行される。
WALモードは複数の読み取りプロセスと1つの書き込みプロセスを同時実行でき、
フラットファイル＋flockの排他制御よりも高い並行性能を提供する。

```sql
PRAGMA journal_mode = WAL;
PRAGMA busy_timeout = 5000;  -- 5秒待機後にBUSYエラー
PRAGMA foreign_keys = ON;
```

---

## 2. ER図

```
┌─────────────┐       ┌──────────────┐
│  threads    │       │  posts       │
│─────────────│       │──────────────│
│ PK id       │──┐    │ PK id        │
│    subject   │  │    │ FK thread_id │──┐
│    author    │  └───<│    seq_no    │  │
│    status    │       │    author    │  │
│    is_locked │       │    body      │  │
│    post_count│       │    trip      │  │
│    created_at│       │    password  │  │
│    updated_at│       │    host      │  │
│    archived  │       │    created_at│  │
└──────┬──────┘       └──────┬───────┘  │
       │                     │          │
       │  ┌──────────────┐   │          │
       │  │  post_images │   │          │
       │  │──────────────│   │          │
       │  │ PK id        │   │          │
       │  │ FK post_id   │──<┘          │
       │  │    slot      │              │
       │  │    filename  │              │
       │  │    original  │              │
       │  │    width     │              │
       │  │    height    │              │
       │  │    thumb     │              │
       │  └──────────────┘              │
       │                                │
       │  ┌──────────────┐              │
       │  │  drafts      │              │
       │  │──────────────│              │
       │  │ PK id        │              │
       │  │ FK thread_id │──────────────┘
       │  │    author    │
       │  │    body      │
       │  │    session_id│
       │  │    created_at│
       │  │    updated_at│
       │  └──────────────┘
       │
       │  ┌──────────────┐
       │  │  users       │
       │  │──────────────│
       │  │ PK id        │
       │  │    login_id  │ UNIQUE
       │  │    password  │
       │  │    name      │
       │  │    rank      │
       │  │    created_at│
       │  └──────────────┘
       │
       │  ┌──────────────┐
       │  │  sessions    │
       │  │──────────────│
       │  │ PK id        │
       │  │    session_id│ UNIQUE
       │  │    data      │
       │  │    created_at│
       │  │    expires_at│
       │  └──────────────┘
       │
       │  ┌──────────────┐
       │  │  settings    │
       │  │──────────────│
       │  │ PK key       │
       │  │    value     │
       │  │    updated_at│
       │  └──────────────┘
       │
       │  ┌──────────────────┐
       │  │  admin_auth      │
       │  │──────────────────│
       │  │ PK id            │
       │  │    login_id      │ UNIQUE
       │  │    password_hash │
       │  │    fail_count    │
       │  │    locked_until  │
       │  │    updated_at    │
       │  └──────────────────┘
       │
       │  ┌──────────────────┐
       │  │  access_counts   │
       │  │──────────────────│
       │  │ PK thread_id     │
       │  │    count         │
       │  └──────────────────┘
```

---

## 3. テーブル定義

### 3.1 threads（スレッド）

スレッド（手紙の話題）の管理テーブル。

```sql
CREATE TABLE threads (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    subject     TEXT    NOT NULL,                    -- 件名
    author      TEXT    NOT NULL,                    -- 作成者名
    email       TEXT    DEFAULT '',                  -- メールアドレス（任意）
    status      TEXT    NOT NULL DEFAULT 'active',   -- active / archived / deleted
    is_locked   INTEGER NOT NULL DEFAULT 0,          -- 0:開放 1:ロック
    admin_note  INTEGER NOT NULL DEFAULT 0,          -- 0:なし 1:管理者コメント表示
    post_count  INTEGER NOT NULL DEFAULT 0,          -- 返信数（キャッシュ）
    has_image   INTEGER NOT NULL DEFAULT 0,          -- 0:なし 1:画像あり
    last_author TEXT    DEFAULT '',                  -- 最終投稿者名
    created_at  TEXT    NOT NULL,                    -- 作成日時 (ISO 8601)
    updated_at  TEXT    NOT NULL                     -- 更新日時 (ISO 8601)
);

-- インデックス
CREATE INDEX idx_threads_status     ON threads(status);
CREATE INDEX idx_threads_updated    ON threads(updated_at DESC);
CREATE INDEX idx_threads_author     ON threads(author);
CREATE INDEX idx_threads_created    ON threads(created_at DESC);
```

**status の状態遷移**:
```
active → archived   (スレッド数上限超過、または手動アーカイブ)
active → deleted    (管理者による削除)
archived → deleted  (過去ログ上限超過、または管理者による削除)
```

**ver1 との対応**:
| ver1 (index1.log) | ver2 (threads) |
|-------------------|----------------|
| スレッド番 | id |
| スレッド名 | subject |
| 返信数 | post_count |
| 作成者 | author |
| 更新日 | updated_at |
| 最終投稿者 | last_author |
| キー (0/1/2) | is_locked + admin_note |
| 画像有無 | has_image |
| index1 / index2 の区別 | status (active / archived) |

### 3.2 posts（投稿）

各スレッド内の個別投稿（親記事・返信）。

```sql
CREATE TABLE posts (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    thread_id   INTEGER NOT NULL,                    -- 所属スレッドID
    seq_no      INTEGER NOT NULL,                    -- スレッド内の連番（0=親記事, 1～=返信）
    author      TEXT    NOT NULL,                    -- 投稿者名
    email       TEXT    DEFAULT '',                  -- メールアドレス
    trip        TEXT    DEFAULT '',                  -- トリップ（◆xxx）
    subject     TEXT    DEFAULT '',                  -- 件名（返信時は空も可）
    body        TEXT    NOT NULL,                    -- 本文
    password    TEXT    NOT NULL DEFAULT '',          -- 編集/削除用パスワード（ハッシュ）
    host        TEXT    DEFAULT '',                  -- 投稿元ホスト（IPアドレス）
    url         TEXT    DEFAULT '',                  -- URL（任意）
    show_email  INTEGER NOT NULL DEFAULT 0,          -- メール表示 0:非表示 1:表示
    is_deleted  INTEGER NOT NULL DEFAULT 0,          -- 論理削除 0:通常 1:削除済
    created_at  TEXT    NOT NULL,                    -- 投稿日時 (ISO 8601)
    updated_at  TEXT    NOT NULL,                    -- 更新日時 (ISO 8601)

    FOREIGN KEY (thread_id) REFERENCES threads(id) ON DELETE CASCADE
);

-- インデックス
CREATE INDEX idx_posts_thread      ON posts(thread_id, seq_no);
CREATE INDEX idx_posts_author      ON posts(author);
CREATE INDEX idx_posts_created     ON posts(created_at);
CREATE UNIQUE INDEX idx_posts_thread_seq ON posts(thread_id, seq_no);
```

**ver1 との対応**:
| ver1 (log/*.cgi の各行) | ver2 (posts) |
|------------------------|--------------|
| 記事番 | seq_no |
| 件名 | subject |
| 投稿者名 | author |
| メール | email |
| 本文 | body |
| 日付 | created_at |
| ホスト | host |
| パスワード | password |
| URL | url |
| メール表示 | show_email |
| ID | — (不要、trips で代替) |
| タイムスタンプ | created_at (ISO 8601化) |
| 画像1～3 | → post_images テーブルに分離 |

### 3.3 post_images（投稿画像）

投稿に紐づく画像ファイル（最大3枚/投稿）。

```sql
CREATE TABLE post_images (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    post_id     INTEGER NOT NULL,                    -- 投稿ID
    slot        INTEGER NOT NULL,                    -- スロット番号 (1, 2, 3)
    filename    TEXT    NOT NULL,                    -- 保存ファイル名
    original    TEXT    NOT NULL DEFAULT '',          -- 元ファイル名
    mime_type   TEXT    NOT NULL DEFAULT '',          -- MIMEタイプ
    file_size   INTEGER NOT NULL DEFAULT 0,          -- ファイルサイズ（バイト）
    width       INTEGER DEFAULT NULL,                -- 画像幅（px）
    height      INTEGER DEFAULT NULL,                -- 画像高さ（px）
    has_thumb   INTEGER NOT NULL DEFAULT 0,          -- サムネイル有無

    FOREIGN KEY (post_id) REFERENCES posts(id) ON DELETE CASCADE
);

CREATE INDEX idx_images_post ON post_images(post_id);
```

### 3.4 drafts（下書き — 文通デスク）

文通デスク機能で使用する下書きデータ。

```sql
CREATE TABLE drafts (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    thread_id   INTEGER NOT NULL,                    -- 返信先スレッドID
    session_id  TEXT    NOT NULL,                    -- 所有セッション（誰の下書きか）
    author      TEXT    NOT NULL DEFAULT '',          -- 投稿者名
    subject     TEXT    NOT NULL DEFAULT '',          -- 件名
    body        TEXT    NOT NULL DEFAULT '',          -- 本文
    created_at  TEXT    NOT NULL,                    -- 作成日時
    updated_at  TEXT    NOT NULL,                    -- 更新日時

    FOREIGN KEY (thread_id) REFERENCES threads(id) ON DELETE CASCADE
);

CREATE INDEX idx_drafts_session ON drafts(session_id);
CREATE INDEX idx_drafts_thread  ON drafts(thread_id);
```

**設計意図**:
- session_id でユーザーを識別（会員モード時は user_id にもできるが、ゲストモードでも使えるよう session_id を使用）
- 一括送信時は、drafts から読み出し → posts に INSERT → drafts から DELETE をトランザクションで実行

### 3.5 users（ユーザー — 会員認証モード用）

会員認証モード（authkey=1）時に使用。

```sql
CREATE TABLE users (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    login_id    TEXT    NOT NULL UNIQUE,              -- ログインID
    password    TEXT    NOT NULL,                     -- パスワードハッシュ (SHA-256 + salt)
    name        TEXT    NOT NULL DEFAULT '',          -- 表示名
    rank        INTEGER NOT NULL DEFAULT 2,           -- 1:閲覧のみ 2:書込可
    is_active   INTEGER NOT NULL DEFAULT 1,           -- 有効/無効
    created_at  TEXT    NOT NULL,
    updated_at  TEXT    NOT NULL
);
```

### 3.6 sessions（セッション）

サーバー側セッション管理。CGI::Session に依存せず自前で実装し、SQLiteに保存する。

```sql
CREATE TABLE sessions (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    session_id  TEXT    NOT NULL UNIQUE,              -- セッションID（ランダム文字列）
    data        TEXT    NOT NULL DEFAULT '{}',        -- セッションデータ（JSON）
    ip_address  TEXT    DEFAULT '',                   -- 作成時のIPアドレス
    created_at  TEXT    NOT NULL,
    expires_at  TEXT    NOT NULL                      -- 有効期限
);

CREATE INDEX idx_sessions_expires ON sessions(expires_at);
```

### 3.7 admin_auth（管理者認証）

管理者ログイン情報とロック機構。

```sql
CREATE TABLE admin_auth (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    login_id        TEXT    NOT NULL UNIQUE,          -- 管理者ログインID
    password_hash   TEXT    NOT NULL,                 -- パスワード (SHA-256 + salt)
    fail_count      INTEGER NOT NULL DEFAULT 0,       -- 連続失敗回数
    locked_until    TEXT    DEFAULT NULL,              -- ロック解除日時（NULLなら非ロック）
    last_login_at   TEXT    DEFAULT NULL,              -- 最終ログイン日時
    updated_at      TEXT    NOT NULL
);
```

### 3.8 settings（管理設定）

管理画面から変更可能な設定値をKVS形式で保存。

```sql
CREATE TABLE settings (
    key         TEXT    PRIMARY KEY,                  -- 設定キー
    value       TEXT    NOT NULL DEFAULT '',          -- 設定値
    updated_at  TEXT    NOT NULL
);
```

**初期データ例**:
```sql
INSERT INTO settings (key, value, updated_at) VALUES
    ('theme',       'standard',  datetime('now')),
    ('bbs_title',   '私書箱',    datetime('now')),
    ('i_max',       '1000',      datetime('now')),
    ('p_max',       '3000',      datetime('now')),
    ('m_max',       '1000',      datetime('now')),
    ('pgmax_now',   '50',        datetime('now')),
    ('pgmax_past',  '100',       datetime('now')),
    ('pg_max',      '10',        datetime('now')),
    ('authkey',     '0',         datetime('now')),
    ('image_upl',   '0',         datetime('now')),
    ('use_captcha', '0',         datetime('now'));
```

### 3.9 access_counts（アクセスカウント）

スレッドごとのアクセス数。

```sql
CREATE TABLE access_counts (
    thread_id   INTEGER PRIMARY KEY,
    count       INTEGER NOT NULL DEFAULT 0,

    FOREIGN KEY (thread_id) REFERENCES threads(id) ON DELETE CASCADE
);
```

---

## 4. 全文検索（FTS）

SQLite の FTS5 拡張を使用して高速な全文検索を実現する。

```sql
CREATE VIRTUAL TABLE posts_fts USING fts5(
    subject,
    body,
    author,
    content='posts',
    content_rowid='id',
    tokenize='unicode61'
);

-- posts テーブル更新時に FTS インデックスを自動更新するトリガー
CREATE TRIGGER posts_fts_insert AFTER INSERT ON posts BEGIN
    INSERT INTO posts_fts(rowid, subject, body, author)
    VALUES (new.id, new.subject, new.body, new.author);
END;

CREATE TRIGGER posts_fts_delete AFTER DELETE ON posts BEGIN
    INSERT INTO posts_fts(posts_fts, rowid, subject, body, author)
    VALUES ('delete', old.id, old.subject, old.body, old.author);
END;

CREATE TRIGGER posts_fts_update AFTER UPDATE ON posts BEGIN
    INSERT INTO posts_fts(posts_fts, rowid, subject, body, author)
    VALUES ('delete', old.id, old.subject, old.body, old.author);
    INSERT INTO posts_fts(rowid, subject, body, author)
    VALUES (new.id, new.subject, new.body, new.author);
END;
```

**検索クエリ例**:
```sql
-- AND 検索
SELECT p.*, t.subject AS thread_subject
FROM posts_fts fts
JOIN posts p ON p.id = fts.rowid
JOIN threads t ON t.id = p.thread_id
WHERE posts_fts MATCH 'キーワード1 キーワード2'
  AND t.status != 'deleted'
ORDER BY p.created_at DESC;

-- OR 検索
WHERE posts_fts MATCH 'キーワード1 OR キーワード2'
```

---

## 5. タイムライン取得クエリ

文通デスク・タイムライン表示で、特定の2者間のやり取りを抽出する。
これが ver1 でバグの原因となっていた機能で、ver2 ではサーバー側のSQLで正確に実行する。

### 5.1 タイムライン抽出ロジック

「自分 = A」「相手 = B」とした場合、以下の投稿を時系列で取得する：

1. **A が作成したスレッドに B が返信した投稿**
2. **B が作成したスレッドに A が返信した投稿**
3. **A が作成したスレッドの親記事**（B への手紙）
4. **B が作成したスレッドの親記事**（A への手紙）

```sql
-- タイムライン取得
SELECT
    p.id,
    p.thread_id,
    p.seq_no,
    p.author,
    p.subject,
    p.body,
    p.created_at,
    t.subject AS thread_subject,
    t.author AS thread_author,
    CASE
        WHEN p.author = :my_name THEN 'sent'
        ELSE 'received'
    END AS direction
FROM posts p
JOIN threads t ON t.id = p.thread_id
WHERE t.status != 'deleted'
  AND p.is_deleted = 0
  AND (
    -- A のスレッドに B が返信、または A の親記事
    (t.author = :my_name AND (p.author = :partner_name OR p.seq_no = 0))
    OR
    -- B のスレッドに A が返信、または B の親記事
    (t.author = :partner_name AND (p.author = :my_name OR p.seq_no = 0))
  )
ORDER BY p.created_at ASC;
```

### 5.2 ver1 のバグ原因との対比

**ver1 の問題**:
- クライアント側（JavaScript/LocalStorage）で複数スレッドの記事を結合
- 「自分のスレッド内の自分の投稿」が抽出条件から漏れるケースがあった
- ブラウザのLocalStorageのデータが不完全になると表示が壊れる

**ver2 での解決**:
- サーバー側SQLで一貫して取得するため、ロジックが明確
- `t.author` と `p.author` の組み合わせで漏れなく抽出
- セッションIDに紐づけるため、ブラウザを変えても正確に動作

---

## 6. マイグレーション

### 6.1 初期スキーマ作成

`Database.pm` の `initialize()` メソッドで、テーブルが存在しない場合に自動作成する。

```perl
sub initialize {
    my ($self) = @_;
    my $version = $self->_get_schema_version();

    if ($version == 0) {
        $self->_create_tables();
        $self->_insert_defaults();
        $self->_set_schema_version(1);
    }
    # 将来のマイグレーション
    # if ($version < 2) { $self->_migrate_v2(); ... }
}
```

### 6.2 スキーマバージョン管理

```sql
CREATE TABLE schema_version (
    version     INTEGER NOT NULL,
    applied_at  TEXT    NOT NULL
);
```

### 6.3 ver1 データ移行ツール

ver1 のフラットファイルからver2のSQLiteへデータを移行するスクリプトを別途提供する。

```
migrate.cgi  ← ver1 → ver2 移行ツール
  1. data/index1.log を読み込み → threads テーブルに INSERT (status='active')
  2. data/index2.log を読み込み → threads テーブルに INSERT (status='archived')
  3. data/log/*.cgi を読み込み → posts テーブルに INSERT
  4. data/memdata.cgi を読み込み → users テーブルに INSERT
  5. 管理者パスワード（pass.dat）→ admin_auth テーブルに INSERT
  6. FTS インデックス再構築
```

---

## 7. バックアップ・リストア

### 7.1 バックアップ

SQLiteは単一ファイルのため、`data/letterbbs.db` をコピーするだけでバックアップ完了。

```bash
cp data/letterbbs.db data/backup/letterbbs_$(date +%Y%m%d).db
```

### 7.2 WAL ファイルの注意

WALモード使用時は以下の3ファイルがセットで存在する：
- `letterbbs.db` — メインDBファイル
- `letterbbs.db-wal` — WALログ
- `letterbbs.db-shm` — 共有メモリ

バックアップ時は3ファイルすべてをコピーするか、
SQLiteの `.backup` コマンドで安全にバックアップを取る。

---

## 8. パフォーマンス考慮

### 8.1 インデックス設計のポイント

| クエリパターン | 使用インデックス |
|---------------|-----------------|
| スレッド一覧（最新順） | `idx_threads_updated` |
| 過去ログ一覧 | `idx_threads_status` + `idx_threads_created` |
| スレッド内記事取得 | `idx_posts_thread` |
| 名前検索 | `idx_posts_author` + `idx_threads_author` |
| 全文検索 | `posts_fts` (FTS5) |
| セッション検証 | `sessions.session_id` (UNIQUE) |
| 下書き取得 | `idx_drafts_session` |

### 8.2 post_count キャッシュ

`threads.post_count` は posts テーブルの COUNT() と同期する必要がある。
投稿・削除時にトリガーで自動更新する：

```sql
CREATE TRIGGER update_post_count_insert AFTER INSERT ON posts
WHEN new.is_deleted = 0 AND new.seq_no > 0
BEGIN
    UPDATE threads SET
        post_count = post_count + 1,
        updated_at = datetime('now'),
        last_author = new.author
    WHERE id = new.thread_id;
END;

CREATE TRIGGER update_post_count_delete AFTER UPDATE ON posts
WHEN old.is_deleted = 0 AND new.is_deleted = 1
BEGIN
    UPDATE threads SET
        post_count = post_count - 1,
        updated_at = datetime('now')
    WHERE id = new.thread_id;
END;
```
