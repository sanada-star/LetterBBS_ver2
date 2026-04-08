package LetterBBS::Captcha;

# CAPTCHA生成・検証モジュール
# 画像表示用の認証コードを生成し、RC4暗号化トークンで検証する

use strict;
use warnings;
use utf8;

use lib './lib';
use Crypt::RC4;

sub new {
    my ($class, $config) = @_;
    return bless {
        config     => $config,
        passphrase => $config->get('cap_phrase') || $config->get('csrf_secret') || 'letterbbs_captcha_key',
        expire     => $config->get('cap_time') || 1800,
        length     => $config->get('cap_len') || 4,
    }, $class;
}

sub generate {
    my ($self) = @_;

    my $length = $self->{length};
    $length = 4 unless $length =~ /^\d+$/ && $length > 0;
    my $max = 10 ** $length;
    my $code = sprintf('%0*d', $length, int(rand($max)));
    my $time = time();

    my $plain = "${code}|${time}";
    my $rc4 = Crypt::RC4->new($self->{passphrase});
    my $encrypted = $rc4->RC4($plain);
    my $token = unpack('H*', $encrypted);

    return {
        token => $token,
        code  => $code,
    };
}

sub decode_token {
    my ($self, $token) = @_;

    return undef unless defined $token;
    return undef unless $token =~ /^[0-9a-fA-F]+$/;

    my $encrypted = pack('H*', $token);
    my $rc4 = Crypt::RC4->new($self->{passphrase});
    my $plain = $rc4->RC4($encrypted);
    my ($code, $timestamp) = split(/\|/, $plain, 2);
    return undef unless defined $code && defined $timestamp;
    return undef unless $timestamp =~ /^\d+$/;

    return {
        code      => $code,
        timestamp => $timestamp,
    };
}

sub verify {
    my ($self, $input, $token) = @_;

    return -1 unless defined $input && defined $token;
    my $decoded = $self->decode_token($token);
    return -1 unless $decoded;
    my $code = $decoded->{code};
    my $timestamp = $decoded->{timestamp};

    if (time() - $timestamp > $self->{expire}) {
        return 0;
    }

    return $input eq $code ? 1 : -1;
}

1;
