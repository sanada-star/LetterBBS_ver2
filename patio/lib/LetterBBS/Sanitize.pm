package LetterBBS::Sanitize;

#============================================================================
# LetterBBS ver2 - 入力サニタイズ・バリデーションモジュール
#============================================================================

use strict;
use warnings;
use utf8;
use Encode qw(decode encode is_utf8);

# HTML特殊文字エスケープ
sub html_escape {
    my ($str) = @_;
    return '' unless defined $str;
    $str =~ s/&/&amp;/g;
    $str =~ s/</&lt;/g;
    $str =~ s/>/&gt;/g;
    $str =~ s/"/&quot;/g;
    $str =~ s/'/&#x27;/g;
    return $str;
}

# エスケープ解除
sub html_unescape {
    my ($str) = @_;
    return '' unless defined $str;
    $str =~ s/&#x27;/'/g;
    $str =~ s/&quot;/"/g;
    $str =~ s/&gt;/>/g;
    $str =~ s/&lt;/</g;
    $str =~ s/&amp;/&/g;
    return $str;
}

# 改行を <br> に変換
sub nl2br {
    my ($str) = @_;
    return '' unless defined $str;
    $str =~ s/\r\n/<br>/g;
    $str =~ s/\r/<br>/g;
    $str =~ s/\n/<br>/g;
    return $str;
}

# URLの自動リンク化（安全: https/http のみ、URLのXSSエスケープ済み）
sub autolink {
    my ($str) = @_;
    return '' unless defined $str;
    $str =~ s{(https?://[^\s<>"']+)}{
        my $url = $1;
        my $disp = $url;
        # href属性と表示文字の両方をエスケープ
        $url =~ s/&/&amp;/g; $url =~ s/"/&quot;/g; $url =~ s/'/&#x27;/g;
        $disp =~ s/&/&amp;/g; $disp =~ s/</&lt;/g; $disp =~ s/>/&gt;/g;
        # javascript: スキームを明示的に拒否
        if ($url =~ /^\s*javascript:/i) {
            $disp  # リンクなしでテキストのみ出力
        } else {
            "<a href=\"$url\" target=\"_blank\" rel=\"noopener noreferrer\">$disp</a>"
        }
    }ge;
    return $str;
}

# HTMLタグ除去
sub strip_tags {
    my ($str) = @_;
    return '' unless defined $str;
    $str =~ s/<[^>]*>//g;
    return $str;
}

# 文字列切り詰め
sub truncate {
    my ($str, $len, $suffix) = @_;
    $suffix = '...' unless defined $suffix;
    return '' unless defined $str;
    if (length($str) > $len) {
        return substr($str, 0, $len) . $suffix;
    }
    return $str;
}

# UTF-8 バリデーション・不正バイト除去
sub validate_utf8 {
    my ($str) = @_;
    return '' unless defined $str;

    if (!is_utf8($str)) {
        eval { $str = decode('UTF-8', $str, Encode::FB_QUIET); };
        $str = '' if $@;
    }

    # 制御文字除去（タブ・改行は残す）
    $str =~ s/[\x00-\x08\x0B\x0C\x0E-\x1F]//g;

    return $str;
}

# ファイル名の安全化
sub sanitize_filename {
    my ($str) = @_;
    return '' unless defined $str;
    $str =~ s/[^\w\.\-]/_/g;     # 英数字・ドット・ハイフン以外をアンダースコアに
    $str =~ s/\.{2,}/./g;        # 連続ドット除去（パストラバーサル防止）
    $str =~ s/^\.//;             # 先頭ドット除去
    return $str;
}

# メールアドレス形式チェック
sub is_valid_email {
    my ($str) = @_;
    return 0 unless defined $str && $str ne '';
    return $str =~ /^[a-zA-Z0-9._%+\-]+\@[a-zA-Z0-9.\-]+\.[a-zA-Z]{2,}$/ ? 1 : 0;
}

# CGI入力パラメータの一括サニタイズ
sub sanitize_input {
    my ($str) = @_;
    return '' unless defined $str;
    $str = validate_utf8($str);
    $str =~ s/^\s+//;   # 先頭空白trim
    $str =~ s/\s+$//;   # 末尾空白trim
    return $str;
}

# 整数値の安全な取得
sub to_int {
    my ($val, $default) = @_;
    $default = 0 unless defined $default;
    return $default unless defined $val;
    return $val =~ /^-?\d+$/ ? int($val) : $default;
}

# 正の整数値の安全な取得
sub to_uint {
    my ($val, $default) = @_;
    $default = 0 unless defined $default;
    return $default unless defined $val;
    return ($val =~ /^\d+$/ && $val > 0) ? int($val) : $default;
}

1;
