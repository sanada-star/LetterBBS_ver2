#!/usr/local/bin/perl

#============================================================================
# LetterBBS ver2 - 管理画面CGI
# 管理者ログイン・スレッド管理・会員管理・設定・デザイン変更
#============================================================================

use strict;
use warnings;
use utf8;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/lib";
}

require './init.cgi';

use LetterBBS::Database;
use LetterBBS::Config;
use LetterBBS::Session;
use LetterBBS::Template;
use LetterBBS::Router;

my ($db, $config, $session, $template, $router);

eval {
    my %cf = set_init();

    $db = LetterBBS::Database->new($cf{db_file});
    $db->initialize();

    $config = LetterBBS::Config->new(\%cf, $db);

    # 管理画面用セッション（クッキー名を分離）
    $session = LetterBBS::Session->new(
        $db, 'letterbbs_admin_sid', $config->get('authtime')
    );
    $session->start();
    $session->cleanup();

    $template = LetterBBS::Template->new($config->get('tmpl_dir'));
    my $cgi = _build_admin_cgi();

    $router = LetterBBS::Router->new(
        config   => $config,
        db       => $db,
        session  => $session,
        template => $template,
        cgi      => $cgi,
    );

    my $action = _admin_get_param('action') || '';
    $router->dispatch_admin($action);

    $db->disconnect();
};
if ($@) {
    my $err = $@;
    warn "[LetterBBS] Admin Fatal error: $err";
    print "Content-Type: text/html; charset=utf-8\n\n";
    print "<html><head><meta charset='UTF-8'></head><body>";
    print "<h1>システムエラー</h1>";
    print "<p>管理画面でエラーが発生しました。</p>";
    print "</body></html>";
}

exit;

#--- 管理画面用CGIパラメータ取得 ---
{
    my %_admin_params;
    my $_admin_parsed = 0;

    sub _admin_parse_params {
        return if $_admin_parsed;
        $_admin_parsed = 1;

        my $method = $ENV{REQUEST_METHOD} || 'GET';
        my $input = '';

        if ($method eq 'POST') {
            my $content_type = $ENV{CONTENT_TYPE} || '';
            if ($content_type =~ m{^multipart/form-data}) {
                _admin_parse_multipart();
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
            $key = _admin_url_decode($key);
            $val = defined $val ? _admin_url_decode($val) : '';
            $_admin_params{$key} = $val;
        }
    }

    sub _admin_parse_multipart {
        my $content_type = $ENV{CONTENT_TYPE} || '';
        my ($boundary) = $content_type =~ /boundary=(.+)/;
        return unless $boundary;

        my $len = $ENV{CONTENT_LENGTH} || 0;
        return if $len <= 0 || $len > 10_000_000;

        binmode STDIN;
        my $buf;
        read(STDIN, $buf, $len);

        if ($ENV{QUERY_STRING}) {
            for my $pair (split /&/, $ENV{QUERY_STRING}) {
                my ($key, $val) = split /=/, $pair, 2;
                next unless defined $key;
                $key = _admin_url_decode($key);
                $val = defined $val ? _admin_url_decode($val) : '';
                $_admin_params{$key} = $val;
            }
        }

        my @parts = split /--\Q$boundary\E/, $buf;
        shift @parts;

        for my $part (@parts) {
            next if $part =~ /^--/;
            next unless $part =~ /Content-Disposition:\s*form-data;\s*name="([^"]+)"/i;
            my $name = $1;
            my ($headers, $body) = split /\r?\n\r?\n/, $part, 2;
            $body =~ s/\r?\n$// if defined $body;
            $body = '' unless defined $body;
            utf8::decode($body) unless utf8::is_utf8($body);
            $_admin_params{$name} = $body;
        }
    }

    sub _admin_get_param {
        _admin_parse_params();
        my ($key) = @_;
        return $_admin_params{$key};
    }

    sub _admin_url_decode {
        my ($str) = @_;
        return '' unless defined $str;
        $str =~ tr/+/ /;
        $str =~ s/%([0-9A-Fa-f]{2})/chr(hex($1))/eg;
        utf8::decode($str) unless utf8::is_utf8($str);
        return $str;
    }

    sub _build_admin_cgi {
        _admin_parse_params();
        return bless {}, 'LetterBBS::AdminCGI';
    }
}

package LetterBBS::AdminCGI;

sub param {
    my ($self, $key) = @_;
    return main::_admin_get_param($key) if defined $key;
    main::_admin_parse_params();
    return keys %main::_admin_params;
}

1;
