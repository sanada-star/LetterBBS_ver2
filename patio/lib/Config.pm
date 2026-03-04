package LetterBBS::Config;

#============================================================================
# LetterBBS ver2 - 設定管理モジュール
# init.cgi (固定設定) と DB settings テーブル (動的設定) を統合管理
#============================================================================

use strict;
use warnings;
use utf8;

sub new {
    my ($class, $init_path) = @_;
    my $self = bless {
        cf => {},
    }, $class;

    # init.cgi の固定設定を読み込み
    if ($init_path && -f $init_path) {
        do $init_path;
        my %cf = set_init();
        $self->{cf} = \%cf;
    }

    return $self;
}

# DB の settings テーブルから動的設定を読み込み、マージ
sub load_db_settings {
    my ($self, $db) = @_;
    return unless $db && $db->dbh;

    eval {
        my $sth = $db->dbh->prepare("SELECT key, value FROM settings");
        $sth->execute();
        while (my $row = $sth->fetchrow_hashref) {
            $self->{cf}{$row->{key}} = $row->{value};
        }
    };
    if ($@) {
        warn "[LetterBBS Config] DB設定読み込みエラー: $@";
    }
}

sub get {
    my ($self, $key) = @_;
    return $self->{cf}{$key};
}

sub set {
    my ($self, $key, $value, $db) = @_;
    $self->{cf}{$key} = $value;
    if ($db && $db->dbh) {
        $db->dbh->do(
            "INSERT OR REPLACE INTO settings (key, value, updated_at) VALUES (?, ?, datetime('now','localtime'))",
            undef, $key, $value
        );
    }
}

sub all {
    my ($self) = @_;
    return %{$self->{cf}};
}

# テーマに応じたCSSファイルパスを返す
sub css_url {
    my ($self) = @_;
    my $theme = $self->get('theme') || 'standard';
    my %theme_css = (
        standard => './cmn/style.css',
        gloomy   => './cmn/style_gloomy.css',
        simple   => './cmn/style_simple.css',
        fox      => './cmn/style_fox.css',
    );
    return $theme_css{$theme} || $theme_css{standard};
}

1;
