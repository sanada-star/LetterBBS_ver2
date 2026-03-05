package LetterBBS::Session;

#============================================================================
# LetterBBS ver2 - セッション管理モジュール（SQLiteバックエンド）
#============================================================================

use strict;
use warnings;
use utf8;

# JSON::PP は Perl 5.14+ で標準
BEGIN {
    eval { require JSON::PP; JSON::PP->import(); };
    if ($@) { die "JSON::PP が見つかりません: $@"; }
}

use LetterBBS::Auth;

sub new {
    my ($class, $db, $cookie_name, $expire_minutes) = @_;
    $cookie_name    ||= 'letterbbs_sid';
    $expire_minutes ||= 60;

    my $self = bless {
        db              => $db,
        cookie_name     => $cookie_name,
        expire_minutes  => $expire_minutes,
        session_id      => undef,
        data            => {},
        is_new          => 0,
        _cookie_header  => '',
    }, $class;

    return $self;
}

# セッション開始（既存 or 新規）
sub start {
    my ($self, $env) = @_;

    # クッキーからセッションID取得
    my $cookie_str = $ENV{HTTP_COOKIE} || '';
    my $sid;
    if ($cookie_str =~ /(?:^|;\s*)\Q$self->{cookie_name}\E=([0-9a-f]{64})/) {
        $sid = $1;
    }

    if ($sid) {
        # 既存セッションの検証
        my $row = $self->{db}->dbh->selectrow_hashref(
            "SELECT session_id, data, expires_at FROM sessions WHERE session_id = ?",
            undef, $sid
        );
        if ($row && $row->{expires_at} ge _now()) {
            $self->{session_id} = $sid;
            $self->{data} = eval { JSON::PP::decode_json($row->{data}) } || {};
            # 有効期限を延長
            $self->_extend();
            return;
        }
        # 期限切れのセッションを削除
        $self->{db}->dbh->do("DELETE FROM sessions WHERE session_id = ?", undef, $sid) if $row;
    }

    # 新規セッション作成
    $self->_create();
}

# セッションデータ取得
sub get {
    my ($self, $key) = @_;
    return $self->{data}{$key};
}

# セッションデータ設定
sub set {
    my ($self, $key, $value) = @_;
    $self->{data}{$key} = $value;
    $self->_save();
}

# セッションID返却
sub id {
    return $_[0]->{session_id};
}

# セッション破棄
sub destroy {
    my ($self) = @_;
    if ($self->{session_id}) {
        $self->{db}->dbh->do("DELETE FROM sessions WHERE session_id = ?", undef, $self->{session_id});
    }
    my $cname = $self->{cookie_name};  # destroy前にローカルに保持
    $self->{session_id} = undef;
    $self->{data} = {};
    # クッキー削除（Max-Age=0 が確实。Expiresはブラウザ互換性のため併記）
    $self->{_cookie_header} = "Set-Cookie: $cname=deleted; Path=/; Max-Age=0; HttpOnly; SameSite=Lax";
}

# セッションIDを再生成（ログイン後のSession Fixation対策）
sub regenerate {
    my ($self) = @_;
    my $old_data = $self->{data};
    $self->destroy();
    $self->_create();
    $self->{data} = $old_data;
    $self->_save();
}

# Set-Cookie ヘッダー文字列
sub cookie_header {
    return $_[0]->{_cookie_header};
}

# 期限切れセッション一括削除（1/100の確率で実行）
sub cleanup {
    my ($self) = @_;
    return unless int(rand(100)) == 0;
    eval {
        $self->{db}->dbh->do("DELETE FROM sessions WHERE expires_at < ?", undef, _now());
    };
}

#--- 内部メソッド ---

sub _create {
    my ($self) = @_;
    my $sid = LetterBBS::Auth::generate_token();
    my $expires = _future($self->{expire_minutes});
    my $ip = $ENV{REMOTE_ADDR} || '';

    $self->{db}->dbh->do(
        "INSERT INTO sessions (session_id, data, ip_address, created_at, expires_at) VALUES (?, ?, ?, datetime('now','localtime'), ?)",
        undef, $sid, '{}', $ip, $expires
    );

    $self->{session_id} = $sid;
    $self->{data} = {};
    $self->{is_new} = 1;

    # HTTPS環境ではSecure属性を付加
    my $secure = ($ENV{HTTPS} && $ENV{HTTPS} eq 'on') ? '; Secure' : '';
    my $cookie = "Set-Cookie: $self->{cookie_name}=$sid; Path=/; HttpOnly; SameSite=Lax$secure";
    $self->{_cookie_header} = $cookie;
}

sub _save {
    my ($self) = @_;
    return unless $self->{session_id};

    my $json = JSON::PP::encode_json($self->{data});
    $self->{db}->dbh->do(
        "UPDATE sessions SET data = ?, expires_at = ? WHERE session_id = ?",
        undef, $json, _future($self->{expire_minutes}), $self->{session_id}
    );
}

sub _extend {
    my ($self) = @_;
    return unless $self->{session_id};
    $self->{db}->dbh->do(
        "UPDATE sessions SET expires_at = ? WHERE session_id = ?",
        undef, _future($self->{expire_minutes}), $self->{session_id}
    );
}

sub _now {
    my @t = localtime;
    return sprintf("%04d-%02d-%02d %02d:%02d:%02d",
        $t[5]+1900, $t[4]+1, $t[3], $t[2], $t[1], $t[0]);
}

sub _future {
    my ($minutes) = @_;
    my @t = localtime(time + $minutes * 60);
    return sprintf("%04d-%02d-%02d %02d:%02d:%02d",
        $t[5]+1900, $t[4]+1, $t[3], $t[2], $t[1], $t[0]);
}

1;
