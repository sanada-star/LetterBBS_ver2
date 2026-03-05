package LetterBBS::Model::Draft;

#============================================================================
# LetterBBS ver2 - 下書きモデル（文通デスク）
#============================================================================

use strict;
use warnings;
use utf8;

sub new {
    my ($class, $db) = @_;
    return bless { db => $db }, $class;
}

sub dbh { return $_[0]->{db}->dbh }

# 下書き取得
sub find {
    my ($self, $id) = @_;
    return $self->dbh->selectrow_hashref(
        "SELECT d.*, t.subject AS thread_subject, t.author AS thread_author, t.last_author
         FROM drafts d
         JOIN threads t ON t.id = d.thread_id
         WHERE d.id = ?",
        undef, $id
    );
}

# セッション別の下書き一覧
sub list_by_session {
    my ($self, $session_id) = @_;
    return $self->dbh->selectall_arrayref(
        "SELECT d.*, t.subject AS thread_subject, t.author AS thread_author, t.last_author
         FROM drafts d
         JOIN threads t ON t.id = d.thread_id
         WHERE d.session_id = ?
         ORDER BY d.updated_at DESC",
        { Slice => {} }, $session_id
    ) || [];
}

# 下書き作成
sub create {
    my ($self, %data) = @_;
    my $now = _now();
    $self->dbh->do(
        "INSERT INTO drafts (thread_id, session_id, author, subject, body, created_at, updated_at)
         VALUES (?, ?, ?, ?, ?, ?, ?)",
        undef,
        $data{thread_id}, $data{session_id},
        $data{author}  || '',
        $data{subject} || '',
        $data{body}    || '',
        $now, $now
    );
    return $self->dbh->last_insert_id("", "", "drafts", "");
}

# 下書き更新
sub update {
    my ($self, $id, %data) = @_;
    my @sets;
    my @vals;
    for my $key (qw(author subject body)) {
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
        "UPDATE drafts SET " . join(', ', @sets) . " WHERE id = ?",
        undef, @vals
    );
    return 1;
}

# 下書き削除
sub delete {
    my ($self, $id) = @_;
    $self->dbh->do("DELETE FROM drafts WHERE id = ?", undef, $id);
    return 1;
}

# セッションの全下書き削除
sub delete_by_session {
    my ($self, $session_id) = @_;
    $self->dbh->do("DELETE FROM drafts WHERE session_id = ?", undef, $session_id);
}

# 一括送信（トランザクション内で実行すること）
sub send_all {
    my ($self, $session_id, $post_model, $host, $password) = @_;
    my $drafts = $self->list_by_session($session_id);
    my @results;

    for my $draft (@$drafts) {
        next unless $draft->{body} && $draft->{body} =~ /\S/;

        my $post_id = $post_model->create(
            thread_id => $draft->{thread_id},
            author    => $draft->{author},
            subject   => $draft->{subject},
            body      => $draft->{body},
            password  => $password || '',
            host      => $host || '',
        );

        push @results, {
            draft_id  => $draft->{id},
            thread_id => $draft->{thread_id},
            post_id   => $post_id,
        };

        $self->dbh->do("DELETE FROM drafts WHERE id = ?", undef, $draft->{id});
    }

    return \@results;
}

sub _now {
    my @t = localtime;
    return sprintf("%04d-%02d-%02d %02d:%02d:%02d",
        $t[5]+1900, $t[4]+1, $t[3], $t[2], $t[1], $t[0]);
}

1;
