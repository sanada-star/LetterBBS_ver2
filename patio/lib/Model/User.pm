package LetterBBS::Model::User;

#============================================================================
# LetterBBS ver2 - ユーザーモデル（会員認証モード用）
#============================================================================

use strict;
use warnings;
use utf8;
use LetterBBS::Auth;

sub new {
    my ($class, $db) = @_;
    return bless { db => $db }, $class;
}

sub dbh { return $_[0]->{db}->dbh }

sub find {
    my ($self, $id) = @_;
    return $self->dbh->selectrow_hashref(
        "SELECT id, login_id, name, rank, is_active, created_at, updated_at FROM users WHERE id = ?",
        undef, $id
    );
}

sub find_by_login_id {
    my ($self, $login_id) = @_;
    return $self->dbh->selectrow_hashref(
        "SELECT * FROM users WHERE login_id = ?", undef, $login_id
    );
}

sub list {
    my ($self, %opts) = @_;
    my $page     = $opts{page}     || 1;
    my $per_page = $opts{per_page} || 50;
    my $offset   = ($page - 1) * $per_page;

    return $self->dbh->selectall_arrayref(
        "SELECT id, login_id, name, rank, is_active, created_at, updated_at FROM users ORDER BY id ASC LIMIT ? OFFSET ?",
        { Slice => {} }, $per_page, $offset
    ) || [];
}

sub create {
    my ($self, %data) = @_;
    my $now = _now();
    my $password_hash = LetterBBS::Auth::hash_password($data{password});

    $self->dbh->do(
        "INSERT INTO users (login_id, password, name, rank, is_active, created_at, updated_at)
         VALUES (?, ?, ?, ?, 1, ?, ?)",
        undef,
        $data{login_id}, $password_hash, $data{name} || '', $data{rank} || 2,
        $now, $now
    );
    return $self->dbh->last_insert_id("", "", "users", "");
}

sub update {
    my ($self, $id, %data) = @_;
    my @sets;
    my @vals;

    for my $key (qw(name rank is_active)) {
        if (exists $data{$key}) {
            push @sets, "$key = ?";
            push @vals, $data{$key};
        }
    }
    if (exists $data{password} && $data{password} ne '') {
        push @sets, "password = ?";
        push @vals, LetterBBS::Auth::hash_password($data{password});
    }
    return 0 unless @sets;

    push @sets, "updated_at = ?";
    push @vals, _now();
    push @vals, $id;

    $self->dbh->do(
        "UPDATE users SET " . join(', ', @sets) . " WHERE id = ?",
        undef, @vals
    );
    return 1;
}

sub delete {
    my ($self, $id) = @_;
    $self->dbh->do("DELETE FROM users WHERE id = ?", undef, $id);
    return 1;
}

sub authenticate {
    my ($self, $login_id, $password) = @_;
    my $user = $self->find_by_login_id($login_id);
    return undef unless $user;
    return undef unless $user->{is_active};
    return undef unless LetterBBS::Auth::verify_password($password, $user->{password});

    # パスワードハッシュは返さない
    delete $user->{password};
    return $user;
}

sub count {
    my ($self) = @_;
    my ($c) = $self->dbh->selectrow_array("SELECT COUNT(*) FROM users");
    return $c || 0;
}

sub _now {
    my @t = localtime;
    return sprintf("%04d-%02d-%02d %02d:%02d:%02d",
        $t[5]+1900, $t[4]+1, $t[3], $t[2], $t[1], $t[0]);
}

1;
