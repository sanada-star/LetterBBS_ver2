#!/usr/bin/perl
# ============================================================
# LetterBBS ver2 - CAPTCHA画像生成CGI
# トークン指定時は同じコードを描画し、未指定時は新規トークンを生成する
# ============================================================
use strict;
use warnings;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/lib";
}

require './init.cgi';

use LetterBBS::Captcha;
use LetterBBS::Config;
use LetterBBS::Database;

my %cf = set_init();
my $db = LetterBBS::Database->new($cf{db_file});
$db->initialize();
my $config = LetterBBS::Config->new(\%cf, $db);
my $captcha = LetterBBS::Captcha->new($config);

my $token = _get_param('token') || '';
my $code = '';

if ($token ne '') {
    my $decoded = $captcha->decode_token($token);
    unless ($decoded) {
        print "Status: 400 Bad Request\r\n";
        print "Content-Type: text/plain; charset=utf-8\r\n\r\n";
        print "invalid captcha token";
        $db->disconnect();
        exit;
    }
    $code = $decoded->{code};
} else {
    my $result = $captcha->generate();
    $code  = $result->{code};
    $token = $result->{token};
}

my $has_gd = eval { require GD; 1 };

if ($has_gd) {
    my $width  = 120;
    my $height = 40;
    my $img = GD::Image->new($width, $height);

    my $bg    = $img->colorAllocate(240, 235, 225);
    my $fg    = $img->colorAllocate(80, 60, 50);
    my $noise = $img->colorAllocate(200, 190, 175);

    $img->filledRectangle(0, 0, $width - 1, $height - 1, $bg);

    for (1 .. 5) {
        $img->line(
            int(rand($width)), int(rand($height)),
            int(rand($width)), int(rand($height)),
            $noise
        );
    }

    my @chars = split('', $code);
    my $x = 15;
    for my $ch (@chars) {
        my $y = 10 + int(rand(10));
        $img->string(GD::gdLargeFont(), $x, $y, $ch, $fg);
        $x += 22 + int(rand(5));
    }

    print "Content-Type: image/png\r\n";
    print "X-Captcha-Token: $token\r\n";
    print "Cache-Control: no-cache, no-store\r\n";
    print "\r\n";
    binmode(STDOUT);
    print $img->png;
} else {
    my $spaced_code = join(' ', split('', $code));
    print "Content-Type: image/svg+xml; charset=utf-8\r\n";
    print "X-Captcha-Token: $token\r\n";
    print "Cache-Control: no-cache, no-store\r\n";
    print "\r\n";
    print <<"SVG";
<svg xmlns="http://www.w3.org/2000/svg" width="120" height="40" viewBox="0 0 120 40">
  <rect width="120" height="40" rx="6" fill="#f0ebe1" />
  <line x1="8" y1="10" x2="112" y2="30" stroke="#c8bea9" stroke-width="1" />
  <line x1="18" y1="34" x2="96" y2="8" stroke="#d4cbb8" stroke-width="1" />
  <text x="60" y="26" text-anchor="middle" font-family="monospace" font-size="20" fill="#4d3e35">$spaced_code</text>
</svg>
SVG
}

$db->disconnect();
exit;

sub _get_param {
    my ($name) = @_;
    my $query = $ENV{QUERY_STRING} || '';
    for my $pair (split /&/, $query) {
        my ($key, $val) = split /=/, $pair, 2;
        next unless defined $key;
        $key = _url_decode($key);
        next unless $key eq $name;
        return defined $val ? _url_decode($val) : '';
    }
    return '';
}

sub _url_decode {
    my ($str) = @_;
    return '' unless defined $str;
    $str =~ tr/+/ /;
    $str =~ s/%([0-9A-Fa-f]{2})/chr(hex($1))/eg;
    return $str;
}
