package LetterBBS::Auth;

#============================================================================
# LetterBBS ver2 - 認証・パスワード・トリップ・CSRFトークン管理
#============================================================================

use strict;
use warnings;
use utf8;

# Digest::SHA が使えなければ PurePerl にフォールバック
BEGIN {
    eval { require Digest::SHA; Digest::SHA->import('sha256_hex'); };
    if ($@) {
        require Digest::SHA::PurePerl;
        Digest::SHA::PurePerl->import('sha256_hex');
    }
}

# パスワードハッシュ生成 (SHA-256 + salt)
sub hash_password {
    my ($plain) = @_;
    my $salt = _random_hex(16);
    my $hash = sha256_hex($salt . $plain);
    return "\$sha256\$$salt\$$hash";
}

# パスワード照合 (SHA-256 および ver1互換の crypt)
sub verify_password {
    my ($plain, $stored) = @_;
    return 0 unless defined $plain && defined $stored && $stored ne '';

    if ($stored =~ /^\$sha256\$([0-9a-f]+)\$([0-9a-f]+)$/) {
        # ver2 形式 (SHA-256 + salt)
        my ($salt, $hash) = ($1, $2);
        return sha256_hex($salt . $plain) eq $hash ? 1 : 0;
    } else {
        # ver1 互換 (crypt)
        return crypt($plain, $stored) eq $stored ? 1 : 0;
    }
}

# ランダムsalt生成
sub generate_salt {
    return _random_hex(16);
}

# トリップ生成（ver1互換）
# 入力: "名前#パスワード" → 返却: ($name, $trip)
sub generate_trip {
    my ($name_with_key) = @_;
    return ($name_with_key, '') unless defined $name_with_key;

    if ($name_with_key =~ /^(.+?)#(.+)$/) {
        my ($name, $key) = ($1, $2);
        my $salt = substr($key . 'H.', 1, 2);
        $salt =~ s/[^\.-z]/\./g;
        $salt =~ tr/:;<=>?@[\\]^_`/ABCDEFGabcdef/;
        my $trip = substr(crypt($key, $salt), -10);
        return ($name, $trip);
    }
    return ($name_with_key, '');
}

# CSRFトークン生成
sub generate_csrf_token {
    my ($session_id, $secret) = @_;
    die "csrf_secret が設定されていません" unless $secret;
    my $time = int(time() / 3600);  # 1時間単位
    return substr(sha256_hex("$secret:$session_id:$time"), 0, 32);
}

# CSRFトークン検証（タイミング攻撃耐性: 定数時間比較）
sub verify_csrf_token {
    my ($token, $session_id, $secret) = @_;
    return 0 unless defined $token && length($token) == 32;
    return 0 unless $secret;

    # 現在のトークンと1つ前（1時間前）のトークンを許可
    my $time_now  = int(time() / 3600);
    my $time_prev = $time_now - 1;

    my $current  = substr(sha256_hex("$secret:$session_id:$time_now"), 0, 32);
    my $previous = substr(sha256_hex("$secret:$session_id:$time_prev"), 0, 32);

    # 定数時間比較（タイミング攻撃防止）
    return (_const_eq($token, $current) | _const_eq($token, $previous)) ? 1 : 0;
}

# ランダムトークン生成（セッションID等）
# /dev/urandom → 利用可否でフォールバック
sub generate_token {
    return sha256_hex(_random_bytes(32) . time() . $$);
}

# 内部: 暗号学的乱数バイト列
sub _random_bytes {
    my ($n) = @_;
    my $buf = '';
    if (open my $fh, '<:raw', '/dev/urandom') {
        read($fh, $buf, $n);
        close $fh;
        return $buf if length($buf) == $n;
    }
    # フォールバック: rand() (品質は劣るが動作は保証)
    for (1..$n) { $buf .= chr(int(rand(256))); }
    return $buf;
}

# 内部: ランダム16進文字列
sub _random_hex {
    my ($bytes) = @_;
    return unpack('H*', _random_bytes($bytes));
}

# 内部: 定数時間文字列比較（タイミング攻撃防止）
sub _const_eq {
    my ($a, $b) = @_;
    return 0 if length($a) != length($b);
    my $diff = 0;
    $diff |= ord(substr($a, $_, 1)) ^ ord(substr($b, $_, 1))
        for 0 .. length($a) - 1;
    return $diff == 0 ? 1 : 0;
}

1;
