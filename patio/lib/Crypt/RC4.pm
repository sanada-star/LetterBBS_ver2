package Crypt::RC4;

# RC4暗号化モジュール（CAPTCHA用）
# ver1互換のCAPTCHAトークン暗号化に使用

use strict;
use warnings;

sub new {
    my ($class, $key) = @_;
    my @state = (0..255);
    my @k = unpack('C*', $key);
    my $j = 0;
    for my $i (0..255) {
        $j = ($j + $state[$i] + $k[$i % scalar @k]) % 256;
        @state[$i, $j] = @state[$j, $i];
    }
    return bless { state => \@state, i => 0, j => 0 }, $class;
}

sub RC4 {
    my ($self, $data) = @_;

    # 関数的呼び出し: RC4($key, $data)
    if (!ref $self) {
        my $key = $self;
        $data = $_[1];
        $self = __PACKAGE__->new($key);
    }

    my @state = @{$self->{state}};
    my ($i, $j) = ($self->{i}, $self->{j});
    my @in = unpack('C*', $data);
    my @out;

    for my $byte (@in) {
        $i = ($i + 1) % 256;
        $j = ($j + $state[$i]) % 256;
        @state[$i, $j] = @state[$j, $i];
        my $k = $state[($state[$i] + $state[$j]) % 256];
        push @out, $byte ^ $k;
    }

    $self->{state} = \@state;
    $self->{i} = $i;
    $self->{j} = $j;

    return pack('C*', @out);
}

# エクスポート用
sub import {
    my $caller = caller;
    no strict 'refs';
    *{"${caller}::RC4"} = sub { RC4(@_) };
}

1;
