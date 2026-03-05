package LetterBBS::Database;

#============================================================================
# LetterBBS ver2 - データベース管理モジュール
# SQLite接続、スキーマ作成、マイグレーション、トランザクション管理
#============================================================================

use strict;
use warnings;
use utf8;
use DBI;

sub new {
    my ($class, $db_path) = @_;
    my $self = bless {
        db_path => $db_path,
        dbh     => undef,
    }, $class;
    $self->_connect();
    return $self;
}

sub _connect {
    my ($self) = @_;
    $self->{dbh} = DBI->connect(
        "dbi:SQLite:dbname=$self->{db_path}",
        "", "",
        {
            RaiseError     => 1,
            PrintError     => 0,
            AutoCommit     => 1,
            sqlite_unicode => 1,
        }
    ) or die "DB接続失敗: $DBI::errstr";

    $self->{dbh}->do("PRAGMA journal_mode = WAL");
    $self->{dbh}->do("PRAGMA busy_timeout = 5000");
    $self->{dbh}->do("PRAGMA foreign_keys = ON");
    $self->{dbh}->do("PRAGMA synchronous = NORMAL");
}

sub dbh { return $_[0]->{dbh} }

sub begin_transaction {
    my ($self) = @_;
    $self->{dbh}->begin_work;
}

sub commit {
    my ($self) = @_;
    $self->{dbh}->commit;
}

sub rollback {
    my ($self) = @_;
    eval { $self->{dbh}->rollback };
}

sub disconnect {
    my ($self) = @_;
    if ($self->{dbh}) {
        $self->{dbh}->disconnect;
        $self->{dbh} = undef;
    }
}

#--- スキーマ初期化 ---

sub initialize {
    my ($self) = @_;
    my $version = $self->_get_schema_version();

    if ($version == 0) {
        $self->_create_tables();
        $self->_create_indexes();
        $self->_create_fts();
        $self->_create_triggers();
        $self->_insert_defaults();
        $self->_set_schema_version(1);
    }
    # 将来のマイグレーション
    # if ($version < 2) { $self->_migrate_v2(); $self->_set_schema_version(2); }
}

sub _get_schema_version {
    my ($self) = @_;
    my $exists = $self->{dbh}->selectrow_array(
        "SELECT count(*) FROM sqlite_master WHERE type='table' AND name='schema_version'"
    );
    return 0 unless $exists;
    my $version = $self->{dbh}->selectrow_array(
        "SELECT MAX(version) FROM schema_version"
    );
    return $version || 0;
}

sub _set_schema_version {
    my ($self, $version) = @_;
    $self->{dbh}->do(
        "INSERT INTO schema_version (version, applied_at) VALUES (?, datetime('now'))",
        undef, $version
    );
}

sub _create_tables {
    my ($self) = @_;
    my $dbh = $self->{dbh};

    $dbh->do("CREATE TABLE IF NOT EXISTS schema_version (
        version     INTEGER NOT NULL,
        applied_at  TEXT    NOT NULL
    )");

    $dbh->do("CREATE TABLE IF NOT EXISTS threads (
        id          INTEGER PRIMARY KEY AUTOINCREMENT,
        subject     TEXT    NOT NULL,
        author      TEXT    NOT NULL,
        email       TEXT    DEFAULT '',
        status      TEXT    NOT NULL DEFAULT 'active',
        is_locked   INTEGER NOT NULL DEFAULT 0,
        admin_note  INTEGER NOT NULL DEFAULT 0,
        post_count  INTEGER NOT NULL DEFAULT 0,
        has_image   INTEGER NOT NULL DEFAULT 0,
        last_author TEXT    DEFAULT '',
        created_at  TEXT    NOT NULL DEFAULT (datetime('now','localtime')),
        updated_at  TEXT    NOT NULL DEFAULT (datetime('now','localtime'))
    )");

    $dbh->do("CREATE TABLE IF NOT EXISTS posts (
        id          INTEGER PRIMARY KEY AUTOINCREMENT,
        thread_id   INTEGER NOT NULL,
        seq_no      INTEGER NOT NULL,
        author      TEXT    NOT NULL,
        email       TEXT    DEFAULT '',
        trip        TEXT    DEFAULT '',
        subject     TEXT    DEFAULT '',
        body        TEXT    NOT NULL,
        password    TEXT    NOT NULL DEFAULT '',
        host        TEXT    DEFAULT '',
        url         TEXT    DEFAULT '',
        show_email  INTEGER NOT NULL DEFAULT 0,
        is_deleted  INTEGER NOT NULL DEFAULT 0,
        created_at  TEXT    NOT NULL DEFAULT (datetime('now','localtime')),
        updated_at  TEXT    NOT NULL DEFAULT (datetime('now','localtime')),
        FOREIGN KEY (thread_id) REFERENCES threads(id) ON DELETE CASCADE
    )");

    $dbh->do("CREATE TABLE IF NOT EXISTS post_images (
        id          INTEGER PRIMARY KEY AUTOINCREMENT,
        post_id     INTEGER NOT NULL,
        slot        INTEGER NOT NULL,
        filename    TEXT    NOT NULL,
        original    TEXT    NOT NULL DEFAULT '',
        mime_type   TEXT    NOT NULL DEFAULT '',
        file_size   INTEGER NOT NULL DEFAULT 0,
        width       INTEGER DEFAULT NULL,
        height      INTEGER DEFAULT NULL,
        has_thumb   INTEGER NOT NULL DEFAULT 0,
        FOREIGN KEY (post_id) REFERENCES posts(id) ON DELETE CASCADE
    )");

    $dbh->do("CREATE TABLE IF NOT EXISTS drafts (
        id          INTEGER PRIMARY KEY AUTOINCREMENT,
        thread_id   INTEGER NOT NULL,
        session_id  TEXT    NOT NULL,
        author      TEXT    NOT NULL DEFAULT '',
        subject     TEXT    NOT NULL DEFAULT '',
        body        TEXT    NOT NULL DEFAULT '',
        created_at  TEXT    NOT NULL DEFAULT (datetime('now','localtime')),
        updated_at  TEXT    NOT NULL DEFAULT (datetime('now','localtime')),
        FOREIGN KEY (thread_id) REFERENCES threads(id) ON DELETE CASCADE
    )");

    $dbh->do("CREATE TABLE IF NOT EXISTS users (
        id          INTEGER PRIMARY KEY AUTOINCREMENT,
        login_id    TEXT    NOT NULL UNIQUE,
        password    TEXT    NOT NULL,
        name        TEXT    NOT NULL DEFAULT '',
        rank        INTEGER NOT NULL DEFAULT 2,
        is_active   INTEGER NOT NULL DEFAULT 1,
        created_at  TEXT    NOT NULL DEFAULT (datetime('now','localtime')),
        updated_at  TEXT    NOT NULL DEFAULT (datetime('now','localtime'))
    )");

    $dbh->do("CREATE TABLE IF NOT EXISTS sessions (
        id          INTEGER PRIMARY KEY AUTOINCREMENT,
        session_id  TEXT    NOT NULL UNIQUE,
        data        TEXT    NOT NULL DEFAULT '{}',
        ip_address  TEXT    DEFAULT '',
        created_at  TEXT    NOT NULL DEFAULT (datetime('now','localtime')),
        expires_at  TEXT    NOT NULL
    )");

    $dbh->do("CREATE TABLE IF NOT EXISTS admin_auth (
        id              INTEGER PRIMARY KEY AUTOINCREMENT,
        login_id        TEXT    NOT NULL UNIQUE,
        password_hash   TEXT    NOT NULL,
        fail_count      INTEGER NOT NULL DEFAULT 0,
        locked_until    TEXT    DEFAULT NULL,
        last_login_at   TEXT    DEFAULT NULL,
        updated_at      TEXT    NOT NULL DEFAULT (datetime('now','localtime'))
    )");

    $dbh->do("CREATE TABLE IF NOT EXISTS settings (
        key         TEXT    PRIMARY KEY,
        value       TEXT    NOT NULL DEFAULT '',
        updated_at  TEXT    NOT NULL DEFAULT (datetime('now','localtime'))
    )");

    $dbh->do("CREATE TABLE IF NOT EXISTS access_counts (
        thread_id   INTEGER PRIMARY KEY,
        count       INTEGER NOT NULL DEFAULT 0,
        FOREIGN KEY (thread_id) REFERENCES threads(id) ON DELETE CASCADE
    )");
}

sub _create_indexes {
    my ($self) = @_;
    my $dbh = $self->{dbh};

    $dbh->do("CREATE INDEX IF NOT EXISTS idx_threads_status     ON threads(status)");
    $dbh->do("CREATE INDEX IF NOT EXISTS idx_threads_updated    ON threads(updated_at DESC)");
    $dbh->do("CREATE INDEX IF NOT EXISTS idx_threads_author     ON threads(author)");
    $dbh->do("CREATE INDEX IF NOT EXISTS idx_threads_created    ON threads(created_at DESC)");

    $dbh->do("CREATE INDEX IF NOT EXISTS idx_posts_thread       ON posts(thread_id, seq_no)");
    $dbh->do("CREATE INDEX IF NOT EXISTS idx_posts_author       ON posts(author)");
    $dbh->do("CREATE INDEX IF NOT EXISTS idx_posts_created      ON posts(created_at)");
    $dbh->do("CREATE UNIQUE INDEX IF NOT EXISTS idx_posts_thread_seq ON posts(thread_id, seq_no)");

    $dbh->do("CREATE INDEX IF NOT EXISTS idx_images_post        ON post_images(post_id)");
    $dbh->do("CREATE INDEX IF NOT EXISTS idx_drafts_session     ON drafts(session_id)");
    $dbh->do("CREATE INDEX IF NOT EXISTS idx_drafts_thread      ON drafts(thread_id)");
    $dbh->do("CREATE INDEX IF NOT EXISTS idx_sessions_expires   ON sessions(expires_at)");
}

sub _create_fts {
    my ($self) = @_;
    my $dbh = $self->{dbh};

    # FTS5 がサポートされているか確認
    eval {
        $dbh->do("CREATE VIRTUAL TABLE IF NOT EXISTS posts_fts USING fts5(
            subject,
            body,
            author,
            content='posts',
            content_rowid='id',
            tokenize='unicode61'
        )");
    };
    if ($@) {
        warn "[LetterBBS] FTS5が利用できません。全文検索は LIKE 検索にフォールバックします: $@";
        $self->{fts_available} = 0;
    } else {
        $self->{fts_available} = 1;
    }
}

sub fts_available { return $_[0]->{fts_available} || 0 }

sub _create_triggers {
    my ($self) = @_;
    my $dbh = $self->{dbh};

    # post_count 自動更新: 投稿追加時
    $dbh->do("CREATE TRIGGER IF NOT EXISTS trg_post_count_insert
        AFTER INSERT ON posts
        WHEN new.is_deleted = 0 AND new.seq_no > 0
        BEGIN
            UPDATE threads SET
                post_count = post_count + 1,
                updated_at = datetime('now','localtime'),
                last_author = new.author
            WHERE id = new.thread_id;
        END
    ");

    # post_count 自動更新: 論理削除時
    $dbh->do("CREATE TRIGGER IF NOT EXISTS trg_post_count_delete
        AFTER UPDATE OF is_deleted ON posts
        WHEN old.is_deleted = 0 AND new.is_deleted = 1 AND new.seq_no > 0
        BEGIN
            UPDATE threads SET
                post_count = post_count - 1,
                updated_at = datetime('now','localtime')
            WHERE id = new.thread_id;
        END
    ");

    # FTS 自動更新
    if ($self->{fts_available}) {
        $dbh->do("CREATE TRIGGER IF NOT EXISTS trg_fts_insert
            AFTER INSERT ON posts
            BEGIN
                INSERT INTO posts_fts(rowid, subject, body, author)
                VALUES (new.id, new.subject, new.body, new.author);
            END
        ");
        $dbh->do("CREATE TRIGGER IF NOT EXISTS trg_fts_delete
            AFTER DELETE ON posts
            BEGIN
                INSERT INTO posts_fts(posts_fts, rowid, subject, body, author)
                VALUES ('delete', old.id, old.subject, old.body, old.author);
            END
        ");
        $dbh->do("CREATE TRIGGER IF NOT EXISTS trg_fts_update
            AFTER UPDATE OF subject, body, author ON posts
            BEGIN
                INSERT INTO posts_fts(posts_fts, rowid, subject, body, author)
                VALUES ('delete', old.id, old.subject, old.body, old.author);
                INSERT INTO posts_fts(rowid, subject, body, author)
                VALUES (new.id, new.subject, new.body, new.author);
            END
        ");
    }
}

sub _insert_defaults {
    my ($self) = @_;
    my $dbh = $self->{dbh};

    # 初期管理者アカウント: 初期パスワード "password"（設置後すぐに変更すること）
    require LetterBBS::Auth;
    my $password_hash = LetterBBS::Auth::hash_password('password');

    $dbh->do(
        "INSERT OR IGNORE INTO admin_auth (login_id, password_hash, updated_at) VALUES (?, ?, datetime('now','localtime'))",
        undef, 'admin', $password_hash
    );

    # デフォルト設定値
    my %defaults = (
        theme       => 'standard',
        bbs_title   => '私書箱',
        i_max       => '1000',
        p_max       => '3000',
        m_max       => '1000',
        pg_max      => '10',
        pgmax_now   => '50',
        pgmax_past  => '100',
        authkey     => '0',
        authtime    => '60',
        image_upl   => '0',
        thumbnail   => '0',
        use_captcha => '0',
        wait        => '15',
        max_failpass => '10',
        lock_days   => '14',
    );

    my $sth = $dbh->prepare(
        "INSERT OR IGNORE INTO settings (key, value, updated_at) VALUES (?, ?, datetime('now','localtime'))"
    );
    for my $key (keys %defaults) {
        $sth->execute($key, $defaults{$key});
    }
}

sub _random_hex {
    my ($bytes) = @_;
    my $hex = '';
    for (1..$bytes) {
        $hex .= sprintf("%02x", int(rand(256)));
    }
    return $hex;
}

1;
