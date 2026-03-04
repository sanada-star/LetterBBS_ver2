#!/usr/bin/perl
# ============================================================
# LetterBBS ver2 — CAPTCHA画像生成CGI
# 数字4桁の認証画像を動的生成し、暗号化トークンを付与する
# ============================================================
use strict;
use warnings;
use lib './lib';

require './init.cgi';

use LetterBBS::Captcha;
use LetterBBS::Config;

my $config = LetterBBS::Config->new();
my $captcha = LetterBBS::Captcha->new($config);

# CAPTCHA生成
my $result = $captcha->generate();
my $code   = $result->{code};
my $token  = $result->{token};

# 画像生成（GD or 純テキストフォールバック）
my $has_gd = eval { require GD; 1 };

if ($has_gd) {
    # GDライブラリが利用可能: PNG画像を生成
    my $width  = 120;
    my $height = 40;
    my $img = GD::Image->new($width, $height);

    # 色定義
    my $bg      = $img->colorAllocate(240, 235, 225);
    my $fg      = $img->colorAllocate(80, 60, 50);
    my $noise   = $img->colorAllocate(200, 190, 175);

    $img->filledRectangle(0, 0, $width-1, $height-1, $bg);

    # ノイズライン
    for (1..5) {
        $img->line(
            int(rand($width)), int(rand($height)),
            int(rand($width)), int(rand($height)),
            $noise
        );
    }

    # 文字描画（各桁をランダムに少しずらす）
    my @chars = split('', $code);
    my $x = 15;
    for my $ch (@chars) {
        my $y = 10 + int(rand(10));
        $img->string(GD::gdLargeFont(), $x, $y, $ch, $fg);
        $x += 22 + int(rand(5));
    }

    # 出力
    print "Content-Type: image/png\r\n";
    print "X-Captcha-Token: $token\r\n";
    print "Cache-Control: no-cache, no-store\r\n";
    print "\r\n";
    binmode(STDOUT);
    print $img->png;

} else {
    # GD非対応: HTMLテキスト形式のCAPTCHAをJSON返却
    # フロントエンド側でスタイル付き描画する想定
    my $spaced_code = join(' ', split('', $code));

    print "Content-Type: application/json; charset=utf-8\r\n";
    print "Cache-Control: no-cache, no-store\r\n";
    print "\r\n";
    print "{\"success\":true,\"token\":\"$token\",\"display\":\"$spaced_code\",\"mode\":\"text\"}";
}

exit;
