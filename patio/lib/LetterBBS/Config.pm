package LetterBBS::Config;

#============================================================================
# LetterBBS ver2 - 設定管理モジュール
# init.cgi (固定設定) と DB settings テーブル (動的設定) を統合管理
#============================================================================

use strict;
use warnings;
use utf8;

sub new {
    my ($class, $init, $db) = @_;
    my $self = bless {
        cf => {},
    }, $class;

    # ハッシュリファレンスが渡された場合はそれを使用
    if (ref $init eq 'HASH') {
        $self->{cf} = { %$init };
    }
    # init.cgi の固定設定を読み込み
    elsif ($init && -f $init) {
        do $init;
        if (defined &set_init) {
            my %cf = set_init();
            $self->{cf} = \%cf;
        }
    }

    # DBオブジェクトがあれば動的設定を読み込み
    if ($db) {
        $self->load_db_settings($db);
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

    # csrf_secretが未設定の場合、自動生成して保存
    unless ($self->get('csrf_secret')) {
        require LetterBBS::Auth;
        my $secret = LetterBBS::Auth::generate_token();
        $self->set('csrf_secret', $secret, $db);
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
        cool     => './cmn/style_cool.css',
        dark     => './cmn/style_dark.css',
        punk     => './cmn/style_punk.css',
        fox      => './cmn/style_fox.css',
        # 後方互換性用
        gloomy   => './cmn/style_cool.css',
        simple   => './cmn/style.css',
    );
    return $theme_css{$theme} || $theme_css{standard};
}

1;
