package LetterBBS::Model::Thread;

#============================================================================
# LetterBBS ver2 - スレッドモデル
#============================================================================

use strict;
use warnings;
use utf8;

sub new {
    my ($class, $db) = @_;
    return bless { db => $db }, $class;
}

sub dbh { return $_[0]->{db}->dbh }

# スレッド取得（ID指定）
sub find {
    my ($self, $id) = @_;
    return $self->dbh->selectrow_hashref(
        "SELECT * FROM threads WHERE id = ?", undef, $id
    );
}

# スレッド一覧取得
sub list {
    my ($self, %opts) = @_;
    my $status   = $opts{status}   || 'active';
    my $page     = $opts{page}     || 1;
    my $per_page = $opts{per_page} || 50;
    my $offset   = ($page - 1) * $per_page;

    my $rows = $self->dbh->selectall_arrayref(
        "SELECT * FROM threads WHERE status = ? ORDER BY updated_at DESC LIMIT ? OFFSET ?",
        { Slice => {} }, $status, $per_page, $offset
    );
    return $rows || [];
}

# スレッド数カウント
sub count_by_status {
    my ($self, $status) = @_;
    my ($count) = $self->dbh->selectrow_array(
        "SELECT COUNT(*) FROM threads WHERE status = ?", undef, $status
    );
    return $count || 0;
}

# スレッド作成
sub create {
    my ($self, %data) = @_;
    my $now = _now();
    $self->dbh->do(
        "INSERT INTO threads (subject, author, email, status, created_at, updated_at) VALUES (?, ?, ?, 'active', ?, ?)",
        undef, $data{subject}, $data{author}, $data{email} || '', $now, $now
    );
    my $id = $self->dbh->last_insert_id("", "", "threads", "");

    # アクセスカウント初期化
    $self->dbh->do(
        "INSERT INTO access_counts (thread_id, count) VALUES (?, 0)", undef, $id
    );

    return $id;
}

# スレッド更新
sub update {
    my ($self, $id, %data) = @_;
    my @sets;
    my @vals;
    for my $key (qw(subject is_locked admin_note status has_image last_author)) {
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
        "UPDATE threads SET " . join(', ', @sets) . " WHERE id = ?",
        undef, @vals
    );
    return 1;
}

# スレッド削除（論理削除）
sub delete {
    my ($self, $id) = @_;
    $self->dbh->do(
        "UPDATE threads SET status = 'deleted', updated_at = ? WHERE id = ?",
        undef, _now(), $id
    );
    # 配下の投稿も論理削除
    $self->dbh->do(
        "UPDATE posts SET is_deleted = 1, updated_at = ? WHERE thread_id = ?",
        undef, _now(), $id
    );
    return 1;
}

# 古いスレッドをアーカイブ化
sub archive_old {
    my ($self, $max_active) = @_;
    my $count = $self->count_by_status('active');
    return 0 if $count <= $max_active;

    my $excess = $count - $max_active;
    my $rows = $self->dbh->selectall_arrayref(
        "SELECT id FROM threads WHERE status = 'active' ORDER BY updated_at ASC LIMIT ?",
        { Slice => {} }, $excess
    );
    for my $row (@$rows) {
        $self->dbh->do(
            "UPDATE threads SET status = 'archived', updated_at = ? WHERE id = ?",
            undef, _now(), $row->{id}
        );
    }
    return scalar @$rows;
}

# 過去ログの上限超過分を物理削除
sub purge_old {
    my ($self, $max_archived, $upl_dir) = @_;
    my $count = $self->count_by_status('archived');
    return 0 if $count <= $max_archived;

    my $excess = $count - $max_archived;
    my $rows = $self->dbh->selectall_arrayref(
        "SELECT id FROM threads WHERE status = 'archived' ORDER BY updated_at ASC LIMIT ?",
        { Slice => {} }, $excess
    );
    for my $row (@$rows) {
        $self->_delete_physical_images($row->{id}, $upl_dir);
        # CASCADE で posts, post_images, access_counts も削除される
        $self->dbh->do("DELETE FROM threads WHERE id = ?", undef, $row->{id});
    }
    return scalar @$rows;
}

# スレッド完全削除（物理削除と画像破棄）
sub destroy {
    my ($self, $id, $upl_dir) = @_;
    $self->_delete_physical_images($id, $upl_dir);
    $self->dbh->do("DELETE FROM threads WHERE id = ?", undef, $id);
    return 1;
}

# 内部: スレッドに紐づく画像ファイルを物理削除
sub _delete_physical_images {
    my ($self, $thread_id, $upl_dir) = @_;
    return unless $upl_dir && $thread_id;
    my $images = $self->dbh->selectall_arrayref(
        "SELECT pi.filename FROM post_images pi JOIN posts p ON p.id = pi.post_id WHERE p.thread_id = ?",
        { Slice => {} }, $thread_id
    );
    for my $img (@$images) {
        my $path = "$upl_dir/$img->{filename}";
        unlink $path if -f $path;
        my $thumb = $path;
        $thumb =~ s/\.(\w+)$/_thumb.$1/;
        unlink $thumb if -f $thumb;
    }
}

# アクセスカウント取得
sub get_access_count {
    my ($self, $thread_id) = @_;
    my ($count) = $self->dbh->selectrow_array(
        "SELECT count FROM access_counts WHERE thread_id = ?", undef, $thread_id
    );
    return $count || 0;
}

# アクセスカウント更新
sub increment_access_count {
    my ($self, $thread_id) = @_;
    $self->dbh->do(
        "INSERT INTO access_counts (thread_id, count) VALUES (?, 1) ON CONFLICT(thread_id) DO UPDATE SET count = count + 1",
        undef, $thread_id
    );
}

# 更新日時でフィルタ（通知API用）
sub list_since {
    my ($self, $since) = @_;
    if ($since) {
        return $self->dbh->selectall_arrayref(
            "SELECT * FROM threads WHERE status = 'active' AND updated_at > ? ORDER BY updated_at DESC",
            { Slice => {} }, $since
        ) || [];
    }
    return $self->dbh->selectall_arrayref(
        "SELECT * FROM threads WHERE status = 'active' ORDER BY updated_at DESC LIMIT 100",
        { Slice => {} }
    ) || [];
}

sub _now {
    my @t = localtime;
    return sprintf("%04d-%02d-%02d %02d:%02d:%02d",
        $t[5]+1900, $t[4]+1, $t[3], $t[2], $t[1], $t[0]);
}

1;
