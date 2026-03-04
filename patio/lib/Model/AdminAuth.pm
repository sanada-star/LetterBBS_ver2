package LetterBBS::Model::AdminAuth;

#============================================================================
# LetterBBS ver2 - 管理者認証モデル
#============================================================================

use strict;
use warnings;
use utf8;
use LetterBBS::Auth;

sub new {
    my ($class, $db, $config) = @_;
    return bless {
        db     => $db,
        config => $config,
    }, $class;
}

sub dbh { return $_[0]->{db}->dbh }

# 管理者認証
sub authenticate {
    my ($self, $login_id, $password) = @_;

    my $admin = $self->dbh->selectrow_hashref(
        "SELECT * FROM admin_auth WHERE login_id = ?", undef, $login_id
    );
    unless ($admin) {
        return { success => 0, reason => 'アカウントが見つかりません。' };
    }

    # ロック状態チェック
    if ($admin->{locked_until}) {
        if ($admin->{locked_until} gt _now()) {
            return { success => 0, reason => 'アカウントがロックされています。しばらくお待ちください。' };
        }
        # ロック期限切れ → 解除
        $self->reset_lock($login_id);
        $admin->{fail_count} = 0;
    }

    # パスワード照合
    if (LetterBBS::Auth::verify_password($password, $admin->{password_hash})) {
        # 成功: カウンタリセット、ログイン日時記録
        $self->dbh->do(
            "UPDATE admin_auth SET fail_count = 0, last_login_at = ?, updated_at = ? WHERE login_id = ?",
            undef, _now(), _now(), $login_id
        );
        return { success => 1, login_id => $login_id };
    }

    # 失敗: カウンタ増加
    my $new_count = ($admin->{fail_count} || 0) + 1;
    my $max_fail = $self->{config} ? $self->{config}->get('max_failpass') || 10 : 10;

    if ($new_count >= $max_fail) {
        # ロック設定
        my $lock_days = $self->{config} ? $self->{config}->get('lock_days') || 14 : 14;
        my $locked_until = _future_days($lock_days);
        $self->dbh->do(
            "UPDATE admin_auth SET fail_count = ?, locked_until = ?, updated_at = ? WHERE login_id = ?",
            undef, $new_count, $locked_until, _now(), $login_id
        );
        return { success => 0, reason => 'パスワードの試行回数を超過しました。アカウントがロックされました。' };
    }

    $self->dbh->do(
        "UPDATE admin_auth SET fail_count = ?, updated_at = ? WHERE login_id = ?",
        undef, $new_count, _now(), $login_id
    );
    return { success => 0, reason => 'パスワードが正しくありません。' };
}

# パスワード変更
sub change_password {
    my ($self, $login_id, $old_password, $new_password) = @_;

    my $admin = $self->dbh->selectrow_hashref(
        "SELECT * FROM admin_auth WHERE login_id = ?", undef, $login_id
    );
    return { success => 0, reason => 'アカウントが見つかりません。' } unless $admin;

    unless (LetterBBS::Auth::verify_password($old_password, $admin->{password_hash})) {
        return { success => 0, reason => '現在のパスワードが正しくありません。' };
    }

    my $new_hash = LetterBBS::Auth::hash_password($new_password);
    $self->dbh->do(
        "UPDATE admin_auth SET password_hash = ?, fail_count = 0, locked_until = NULL, updated_at = ? WHERE login_id = ?",
        undef, $new_hash, _now(), $login_id
    );
    return { success => 1 };
}

# ロック解除
sub reset_lock {
    my ($self, $login_id) = @_;
    $self->dbh->do(
        "UPDATE admin_auth SET fail_count = 0, locked_until = NULL, updated_at = ? WHERE login_id = ?",
        undef, _now(), $login_id
    );
}

sub _now {
    my @t = localtime;
    return sprintf("%04d-%02d-%02d %02d:%02d:%02d",
        $t[5]+1900, $t[4]+1, $t[3], $t[2], $t[1], $t[0]);
}

sub _future_days {
    my ($days) = @_;
    my @t = localtime(time + $days * 86400);
    return sprintf("%04d-%02d-%02d %02d:%02d:%02d",
        $t[5]+1900, $t[4]+1, $t[3], $t[2], $t[1], $t[0]);
}

1;
