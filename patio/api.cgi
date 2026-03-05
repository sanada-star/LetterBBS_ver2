#!/usr/local/bin/perl

#============================================================================
# LetterBBS ver2 - API CGI
# 通知ポーリング・文通デスクAPI（JSON応答）
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
use LetterBBS::Router;

# JSON Content-Type を先に出力
print "Content-Type: application/json; charset=utf-8\n";
print "X-Content-Type-Options: nosniff\n";
print "Cache-Control: no-cache, no-store\n";

eval {
    my %cf = set_init();

    my $db = LetterBBS::Database->new($cf{db_file});
    $db->initialize();

    my $config = LetterBBS::Config->new(\%cf, $db);

    my $session = LetterBBS::Session->new(
        $db, 'letterbbs_sid', $config->get('authtime')
    );
    $session->start();

    # セッションクッキーヘッダー
    if (my $cookie = $session->cookie_header()) {
        $cookie = "Set-Cookie: " . $cookie unless $cookie =~ /^Set-Cookie:/i;
        print "$cookie\n";
    }
    print "\n";  # ヘッダー終了

    # CGIパラメータ取得
    my $cgi = _build_api_cgi();

    # テンプレートはAPI側では不要だが、Router初期化用にダミー生成
    my $template;
    eval {
        require LetterBBS::Template;
        $template = LetterBBS::Template->new($config->get('tmpl_dir'));
    };

    my $router = LetterBBS::Router->new(
        config   => $config,
        db       => $db,
        session  => $session,
        template => $template,
        cgi      => $cgi,
    );

    my $api_action = _api_get_param('api') || '';
    $router->dispatch_api($api_action);

    $db->disconnect();
};
if ($@) {
    warn "[LetterBBS] API Fatal error: $@";
    # ヘッダーがまだ出力されていない可能性を考慮
    require JSON::PP;
    print JSON::PP::encode_json({
        success    => JSON::PP::false,
        error      => 'サーバー内部エラーが発生しました。',
        error_code => 'SERVER_ERROR',
    });
}

exit;

#--- API用CGIパラメータ取得 ---
{
    my %_api_params;
    my $_api_parsed = 0;

    sub _api_parse_params {
        return if $_api_parsed;
        $_api_parsed = 1;

        my $method = $ENV{REQUEST_METHOD} || 'GET';
        my $input = '';

        if ($method eq 'POST') {
            my $len = $ENV{CONTENT_LENGTH} || 0;
            if ($len > 0 && $len < 1_000_000) {
                read(STDIN, $input, $len);
            }
        }

        if ($ENV{QUERY_STRING}) {
            $input = $input ? "$input&$ENV{QUERY_STRING}" : $ENV{QUERY_STRING};
        }

        for my $pair (split /&/, $input) {
            my ($key, $val) = split /=/, $pair, 2;
            next unless defined $key;
            $key = _api_url_decode($key);
            $val = defined $val ? _api_url_decode($val) : '';
            $_api_params{$key} = $val;
        }
    }

    sub _api_get_param {
        _api_parse_params();
        my ($key) = @_;
        return $_api_params{$key};
    }

    sub _api_url_decode {
        my ($str) = @_;
        return '' unless defined $str;
        $str =~ tr/+/ /;
        $str =~ s/%([0-9A-Fa-f]{2})/chr(hex($1))/eg;
        eval {
            require Encode;
            $str = Encode::decode_utf8($str);
        };
        return $str;
    }

    sub _build_api_cgi {
        _api_parse_params();
        return bless {}, 'LetterBBS::ApiCGI';
    }
}

package LetterBBS::ApiCGI;

sub param {
    my ($self, $key) = @_;
    return main::_api_get_param($key) if defined $key;
    main::_api_parse_params();
    return keys %main::_api_params;
}

1;
