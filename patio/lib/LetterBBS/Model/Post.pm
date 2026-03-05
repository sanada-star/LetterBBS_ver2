package LetterBBS::Model::Post;

#============================================================================
# LetterBBS ver2 - 投稿モデル
#============================================================================

use strict;
use warnings;
use utf8;

sub new {
    my ($class, $db) = @_;
    return bless { db => $db }, $class;
}

sub dbh { return $_[0]->{db}->dbh }

# 投稿取得（ID指定）
sub find {
    my ($self, $id) = @_;
    return $self->dbh->selectrow_hashref(
        "SELECT * FROM posts WHERE id = ?", undef, $id
    );
}

# 投稿取得（スレッドID + seq_no 指定）
sub find_by_thread_seq {
    my ($self, $thread_id, $seq_no) = @_;
    return $self->dbh->selectrow_hashref(
        "SELECT * FROM posts WHERE thread_id = ? AND seq_no = ?",
        undef, $thread_id, $seq_no
    );
}

# スレッド内の投稿一覧取得
sub list_by_thread {
    my ($self, $thread_id, %opts) = @_;
    my $page     = $opts{page}     || 1;
    my $per_page = $opts{per_page} || 10;
    my $offset   = ($page - 1) * $per_page;

    # 親記事(seq_no=0)は常に含める
    # 返信はページネーション対象
    my $include_deleted = $opts{include_deleted} ? '' : 'AND is_deleted = 0';

    # 親記事
    my $parent = $self->dbh->selectrow_hashref(
        "SELECT * FROM posts WHERE thread_id = ? AND seq_no = 0 $include_deleted",
        undef, $thread_id
    );

    # 返信
    my $replies = $self->dbh->selectall_arrayref(
        "SELECT * FROM posts WHERE thread_id = ? AND seq_no > 0 $include_deleted ORDER BY seq_no ASC LIMIT ? OFFSET ?",
        { Slice => {} }, $thread_id, $per_page, $offset
    ) || [];

    return ($parent, $replies);
}

# スレッド内の全投稿数カウント（返信のみ、削除除外）
sub count_replies {
    my ($self, $thread_id) = @_;
    my ($count) = $self->dbh->selectrow_array(
        "SELECT COUNT(*) FROM posts WHERE thread_id = ? AND seq_no > 0 AND is_deleted = 0",
        undef, $thread_id
    );
    return $count || 0;
}

# 投稿作成
sub create {
    my ($self, %data) = @_;
    my $now = _now();

    # seq_no 自動計算
    my ($max_seq) = $self->dbh->selectrow_array(
        "SELECT COALESCE(MAX(seq_no), -1) FROM posts WHERE thread_id = ?",
        undef, $data{thread_id}
    );
    my $seq_no = defined $data{seq_no} ? $data{seq_no} : ($max_seq + 1);

    $self->dbh->do(
        "INSERT INTO posts (thread_id, seq_no, author, email, trip, subject, body, password, host, url, show_email, created_at, updated_at)
         VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
        undef,
        $data{thread_id}, $seq_no,
        $data{author}    || '',
        $data{email}     || '',
        $data{trip}      || '',
        $data{subject}   || '',
        $data{body},
        $data{password}  || '',
        $data{host}      || '',
        $data{url}       || '',
        $data{show_email} || 0,
        $now, $now
    );
    return $self->dbh->last_insert_id("", "", "posts", "");
}

# 投稿更新
sub update {
    my ($self, $id, %data) = @_;
    my @sets;
    my @vals;
    for my $key (qw(subject body)) {
        if (exists $data{$key}) {
            push @sets, "$key = ?";
            push @vals, $data{$key};
        }
    }
    return 0 unless @sets;

    push @sets, "updated_at = ?";
    push @vals, _now();
    push @vals, $id;

    $self->dbh->do(
        "UPDATE posts SET " . join(', ', @sets) . " WHERE id = ?",
        undef, @vals
    );
    return 1;
}

# 論理削除（本文書き換え、画像物理削除）
sub soft_delete {
    my ($self, $id, $upl_dir) = @_;
    my $now = _now();

    # 画像があれば物理削除
    if ($upl_dir) {
        my $images = $self->dbh->selectall_arrayref(
            "SELECT filename FROM post_images WHERE post_id = ?",
            { Slice => {} }, $id
        );
        for my $img (@$images) {
            my $path = "$upl_dir/$img->{filename}";
            unlink $path if -f $path;
            my $thumb = $path;
            $thumb =~ s/\.(\w+)$/_thumb.$1/;
            unlink $thumb if -f $thumb;
        }
        $self->dbh->do("DELETE FROM post_images WHERE post_id = ?", undef, $id);
    }

    $self->dbh->do(
        "UPDATE posts SET body = 'この投稿は削除されました。', is_deleted = 1, updated_at = ? WHERE id = ?",
        undef, $now, $id
    );
    return 1;
}

# 全文検索（FTS5使用）
sub search_fts {
    my ($self, %opts) = @_;
    my $keyword  = $opts{keyword}  || return [];
    my $mode     = $opts{mode}     || 'AND';
    my $page     = $opts{page}     || 1;
    my $per_page = $opts{per_page} || 20;
    my $offset   = ($page - 1) * $per_page;

    # FTS5 クエリ構築（単語内のダブルクオートをエスケープ）
    my @words = split(/\s+/, $keyword);
    return [] unless @words;

    my $fts_query;
    if ($mode eq 'OR') {
        $fts_query = join(' OR ', map { my $w = $_; $w =~ s/"/""/g; "\"$w\"" } @words);
    } else {
        $fts_query = join(' ', map { my $w = $_; $w =~ s/"/""/g; "\"$w\"" } @words);
    }

    my $rows = $self->dbh->selectall_arrayref(
        "SELECT p.*, t.subject AS thread_subject, t.author AS thread_author, t.status AS thread_status
         FROM posts_fts fts
         JOIN posts p ON p.id = fts.rowid
         JOIN threads t ON t.id = p.thread_id
         WHERE posts_fts MATCH ?
           AND t.status != 'deleted'
           AND p.is_deleted = 0
         ORDER BY p.created_at DESC
         LIMIT ? OFFSET ?",
        { Slice => {} }, $fts_query, $per_page, $offset
    ) || [];

    return $rows;
}

# LIKE検索（FTS5が使えない場合のフォールバック）
sub search_like {
    my ($self, %opts) = @_;
    my $keyword  = $opts{keyword}  || return [];
    my $mode     = $opts{mode}     || 'AND';
    my $page     = $opts{page}     || 1;
    my $per_page = $opts{per_page} || 20;
    my $offset   = ($page - 1) * $per_page;

    my @words = split(/\s+/, $keyword);
    return [] unless @words;

    my @conditions;
    my @params;
    my $join = ($mode eq 'OR') ? ' OR ' : ' AND ';

    for my $w (@words) {
        # LIKEメタ文字（%_）をエスケープ
        (my $esc_w = $w) =~ s/([%_\\])/\\$1/g;
        my $like = "%$esc_w%";
        push @conditions, "(p.subject LIKE ? ESCAPE '\\' OR p.body LIKE ? ESCAPE '\\' OR p.author LIKE ? ESCAPE '\\')";
        push @params, $like, $like, $like;
    }

    my $where = join($join, @conditions);
    push @params, $per_page, $offset;

    my $rows = $self->dbh->selectall_arrayref(
        "SELECT p.*, t.subject AS thread_subject, t.author AS thread_author, t.status AS thread_status
         FROM posts p
         JOIN threads t ON t.id = p.thread_id
         WHERE ($where)
           AND t.status != 'deleted'
           AND p.is_deleted = 0
         ORDER BY p.created_at DESC
         LIMIT ? OFFSET ?",
        { Slice => {} }, @params
    ) || [];

    return $rows;
}

# タイムライン取得（自分と相手のやり取り）
sub timeline {
    my ($self, $my_name, $partner_name) = @_;
    return [] unless $my_name && $partner_name;

    my $rows = $self->dbh->selectall_arrayref(
        "SELECT
            p.id, p.thread_id, p.seq_no, p.author, p.subject, p.body, p.created_at,
            t.subject AS thread_subject, t.author AS thread_author,
            CASE WHEN p.author = ? THEN 'sent' ELSE 'received' END AS direction
         FROM posts p
         JOIN threads t ON t.id = p.thread_id
         WHERE t.status != 'deleted'
           AND p.is_deleted = 0
           AND (
               (t.author = ? AND (p.author = ? OR p.seq_no = 0))
               OR
               (t.author = ? AND (p.author = ? OR p.seq_no = 0))
           )
         ORDER BY p.created_at ASC",
        { Slice => {} },
        $my_name,           # CASE WHEN
        $my_name, $partner_name,    # 自分のスレッドに相手が返信
        $partner_name, $my_name     # 相手のスレッドに自分が返信
    ) || [];

    return $rows;
}

# 連続投稿チェック
sub check_flood {
    my ($self, $host, $wait_seconds) = @_;
    return 1 unless $host && $wait_seconds;

    my $row = $self->dbh->selectrow_hashref(
        "SELECT created_at FROM posts WHERE host = ? ORDER BY created_at DESC LIMIT 1",
        undef, $host
    );
    return 1 unless $row;

    my $last_time = _parse_datetime($row->{created_at});
    return 1 unless $last_time;

    my $elapsed = time() - $last_time;
    return ($elapsed >= $wait_seconds) ? 1 : 0;
}

# 投稿に紐づく画像一覧
sub get_images {
    my ($self, $post_id) = @_;
    return $self->dbh->selectall_arrayref(
        "SELECT * FROM post_images WHERE post_id = ? ORDER BY slot",
        { Slice => {} }, $post_id
    ) || [];
}

# 画像追加
sub add_image {
    my ($self, %data) = @_;
    $self->dbh->do(
        "INSERT INTO post_images (post_id, slot, filename, original, mime_type, file_size, width, height, has_thumb)
         VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)",
        undef,
        $data{post_id}, $data{slot}, $data{filename}, $data{original} || '',
        $data{mime_type} || '', $data{file_size} || 0,
        $data{width}, $data{height}, $data{has_thumb} || 0
    );
}

# 画像削除
sub delete_image {
    my ($self, $image_id) = @_;
    my $img = $self->dbh->selectrow_hashref(
        "SELECT * FROM post_images WHERE id = ?", undef, $image_id
    );
    $self->dbh->do("DELETE FROM post_images WHERE id = ?", undef, $image_id) if $img;
    return $img;  # 呼び出し元でファイル削除用に返す
}

# 日時文字列をepochに変換
sub _parse_datetime {
    my ($str) = @_;
    return undef unless $str;
    if ($str =~ /^(\d{4})-(\d{2})-(\d{2}) (\d{2}):(\d{2}):(\d{2})/) {
        require POSIX;
        return POSIX::mktime($6, $5, $4, $3, $2-1, $1-1900);
    }
    return undef;
}

sub _now {
    my @t = localtime;
    return sprintf("%04d-%02d-%02d %02d:%02d:%02d",
        $t[5]+1900, $t[4]+1, $t[3], $t[2], $t[1], $t[0]);
}

1;
