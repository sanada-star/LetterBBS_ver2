package LetterBBS::Captcha;

# CAPTCHA生成・検証モジュール
# 画像認証コードを生成し、RC4暗号化トークンで検証する

use strict;
use warnings;
use utf8;

use lib './lib';
use Crypt::RC4;

# コンストラクタ
# 引数: $config - LetterBBS::Config オブジェクト
sub new {
    my ($class, $config) = @_;
    return bless {
        config     => $config,
        passphrase => $config->get('csrf_secret') || 'letterbbs_captcha_key',
        expire     => 1800,  # 有効期限: 30分
    }, $class;
}

# CAPTCHA認証コードとトークンを生成
# 返却: { token => "暗号化トークン(hex)", code => "認証コード(数字4桁)" }
sub generate {
    my ($self) = @_;

    # 認証コード: 4桁のランダム数字
    my $code = sprintf('%04d', int(rand(10000)));
    my $time = time();

    # トークン: RC4(passphrase, "コード|タイムスタンプ")
    my $plain = "${code}|${time}";
    my $rc4 = Crypt::RC4->new($self->{passphrase});
    my $encrypted = $rc4->RC4($plain);
    my $token = unpack('H*', $encrypted);

    return {
        token => $token,
        code  => $code,
    };
}

# CAPTCHA検証
# 引数: $input - ユーザー入力, $token - 暗号化トークン(hex)
# 返却: 1(一致) / 0(期限切れ) / -1(不一致)
sub verify {
    my ($self, $input, $token) = @_;

    return -1 unless defined $input && defined $token;
    return -1 unless $token =~ /^[0-9a-fA-F]+$/;

    # トークンを復号化
    my $encrypted = pack('H*', $token);
    my $rc4 = Crypt::RC4->new($self->{passphrase});
    my $plain = $rc4->RC4($encrypted);

    # "コード|タイムスタンプ" を分解
    my ($code, $timestamp) = split(/\|/, $plain, 2);
    return -1 unless defined $code && defined $timestamp;

    # 有効期限チェック
    if (time() - $timestamp > $self->{expire}) {
        return 0;  # 期限切れ
    }

    # コード照合
    if ($input eq $code) {
        return 1;   # 一致
    } else {
        return -1;  # 不一致
    }
}

1;
