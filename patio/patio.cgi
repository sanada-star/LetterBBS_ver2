#!/usr/local/bin/perl

#============================================================================
# LetterBBS ver2 - メインCGI
# スレッド一覧・閲覧・投稿・編集・検索・文通デスク・静的ページ
#============================================================================

use strict;
use warnings;
use utf8;

BEGIN {
    my $lib_dir = './lib';
    unshift @INC, $lib_dir;
}

require './init.cgi';

use LetterBBS::Database;
use LetterBBS::Config;
use LetterBBS::Session;
use LetterBBS::Template;
use LetterBBS::Router;

eval {
    # 設定読み込み
    my %cf = set_init();

    # データベース接続
    my $db = LetterBBS::Database->new($cf{db_file});
    $db->initialize();

    # 設定マネージャ初期化（DB設定をマージ）
    my $config = LetterBBS::Config->new(\%cf, $db);

    # セッション開始
    my $session = LetterBBS::Session->new(
        $db, 'letterbbs_sid', $config->get('authtime')
    );
    $session->start();
    $session->cleanup();

    # 会員認証チェック
    if ($config->get('authkey')) {
        my $action = _get_param('mode') || '';
        # ログイン画面・ログイン実行・マニュアル・留意事項は認証不要
        unless ($action =~ /^(?:enter|login|manual|note)$/ || $session->get('user_id')) {
            # 未認証 → ログイン画面へリダイレクト
            print "Status: 302 Found\n";
            print "Location: " . $config->get('cgi_url') . "?mode=enter\n";
            print $session->cookie_header() . "\n" if $session->cookie_header();
            print "\n";
            $db->disconnect();
            exit;
        }
    }

    # テンプレートエンジン初期化
    my $template = LetterBBS::Template->new($config->get('tmpl_dir'));

    # CGIパラメータ取得用の簡易オブジェクト
    my $cgi = _build_cgi();

    # ルーター初期化・ディスパッチ
    my $router = LetterBBS::Router->new(
        config   => $config,
        db       => $db,
        session  => $session,
        template => $template,
        cgi      => $cgi,
    );

    my $mode = _get_param('mode') || '';
    $router->dispatch($mode);

    $db->disconnect();
};
if ($@) {
    warn "[LetterBBS] Fatal error: $@";
    print "Content-Type: text/html; charset=utf-8\n\n";
    print "<html><body><h1>システムエラー</h1><p>申し訳ございません。システムエラーが発生しました。</p></body></html>";
}

exit;

#--- CGIパラメータ取得ユーティリティ ---

{
    my %_params;
    my $_parsed = 0;

    sub _parse_params {
        return if $_parsed;
        $_parsed = 1;

        my $method = $ENV{REQUEST_METHOD} || 'GET';
        my $input = '';

        if ($method eq 'POST') {
            my $content_type = $ENV{CONTENT_TYPE} || '';
            if ($content_type =~ m{^multipart/form-data}) {
                # multipart は Upload.pm 側で処理
                # ここでは boundary 以外のフィールドを簡易取得
                _parse_multipart();
                return;
            }
            my $len = $ENV{CONTENT_LENGTH} || 0;
            if ($len > 0 && $len < 10_000_000) {
                read(STDIN, $input, $len);
            }
        }

        if ($ENV{QUERY_STRING}) {
            $input = $input ? "$input&$ENV{QUERY_STRING}" : $ENV{QUERY_STRING};
        }

        for my $pair (split /&/, $input) {
            my ($key, $val) = split /=/, $pair, 2;
            next unless defined $key;
            $key = _url_decode($key);
            $val = defined $val ? _url_decode($val) : '';
            if (exists $_params{$key}) {
                # 複数値はカンマ区切りで保持
                $_params{$key} .= ",$val";
            } else {
                $_params{$key} = $val;
            }
        }
    }

    sub _parse_multipart {
        my $content_type = $ENV{CONTENT_TYPE} || '';
        my ($boundary) = $content_type =~ /boundary=(.+)/;
        return unless $boundary;

        my $len = $ENV{CONTENT_LENGTH} || 0;
        return if $len <= 0 || $len > 10_000_000;

        binmode STDIN;
        my $buf;
        read(STDIN, $buf, $len);

        # クエリストリングも取得
        if ($ENV{QUERY_STRING}) {
            for my $pair (split /&/, $ENV{QUERY_STRING}) {
                my ($key, $val) = split /=/, $pair, 2;
                next unless defined $key;
                $key = _url_decode($key);
                $val = defined $val ? _url_decode($val) : '';
                $_params{$key} = $val;
            }
        }

        # 各パートを解析
        my @parts = split /--\Q$boundary\E/, $buf;
        shift @parts;  # 先頭の空要素を除去

        for my $part (@parts) {
            next if $part =~ /^--/;  # 終端マーカー
            next unless $part =~ /Content-Disposition:\s*form-data;\s*name="([^"]+)"/i;
            my $name = $1;

            if ($part =~ /filename="([^"]+)"/i) {
                # ファイルフィールド → ここでは名前だけ記録
                # 実際のファイルデータは Upload.pm で再取得
                $_params{"${name}_filename"} = $1;
                # バイナリデータ部分を取得
                my ($headers, $body) = split /\r?\n\r?\n/, $part, 2;
                $body =~ s/\r?\n$// if defined $body;
                $_params{"${name}_data"} = $body;
            } else {
                # テキストフィールド
                my ($headers, $body) = split /\r?\n\r?\n/, $part, 2;
                $body =~ s/\r?\n$// if defined $body;
                $body = '' unless defined $body;
                # UTF-8 としてデコード
                utf8::decode($body) unless utf8::is_utf8($body);
                $_params{$name} = $body;
            }
        }
    }

    sub _get_param {
        _parse_params();
        my ($key) = @_;
        return $_params{$key};
    }

    sub _get_all_params {
        _parse_params();
        return %_params;
    }

    sub _url_decode {
        my ($str) = @_;
        return '' unless defined $str;
        $str =~ tr/+/ /;
        $str =~ s/%([0-9A-Fa-f]{2})/chr(hex($1))/eg;
        utf8::decode($str) unless utf8::is_utf8($str);
        return $str;
    }

    sub _build_cgi {
        _parse_params();
        return bless {}, 'LetterBBS::SimpleCGI';
    }
}

# 簡易CGIオブジェクト（Controller互換用）
package LetterBBS::SimpleCGI;

sub param {
    my ($self, $key) = @_;
    return main::_get_param($key) if defined $key;
    # キー一覧を返す
    my %p = main::_get_all_params();
    return keys %p;
}

sub upload_data {
    my ($self, $field) = @_;
    return main::_get_param("${field}_data");
}

sub upload_filename {
    my ($self, $field) = @_;
    return main::_get_param("${field}_filename");
}

1;
