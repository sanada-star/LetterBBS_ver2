package LetterBBS::Router;

#============================================================================
# LetterBBS ver2 - ルーティングモジュール
# URLパラメータからアクションを判定し、対応するControllerメソッドを呼び出す
#============================================================================

use strict;
use warnings;
use utf8;

use LetterBBS::Controller::Board;
use LetterBBS::Controller::Thread;
use LetterBBS::Controller::Desk;
use LetterBBS::Controller::Notification;
use LetterBBS::Controller::Admin;
use LetterBBS::Controller::Page;

sub new {
    my ($class, %args) = @_;
    my $self = bless {
        config   => $args{config},
        db       => $args{db},
        session  => $args{session},
        template => $args{template},
        cgi      => $args{cgi},
    }, $class;

    # コントローラー初期化
    my %ctx = (
        config   => $self->{config},
        db       => $self->{db},
        session  => $self->{session},
        template => $self->{template},
        cgi      => $self->{cgi},
    );

    $self->{controllers} = {
        Board        => LetterBBS::Controller::Board->new(%ctx),
        Thread       => LetterBBS::Controller::Thread->new(%ctx),
        Desk         => LetterBBS::Controller::Desk->new(%ctx),
        Notification => LetterBBS::Controller::Notification->new(%ctx),
        Admin        => LetterBBS::Controller::Admin->new(%ctx),
        Page         => LetterBBS::Controller::Page->new(%ctx),
    };

    return $self;
}

# メインCGI (patio.cgi) のルーティング
my %PAGE_ROUTES = (
    ''          => ['Board',   'list'],
    'list'      => ['Board',   'list'],
    'read'      => ['Thread',  'read'],
    'form'      => ['Thread',  'form'],
    'post'      => ['Thread',  'post'],
    'pwd'       => ['Thread',  'pwd_form'],
    'edit'      => ['Thread',  'edit_form'],
    'edit_exec' => ['Thread',  'edit_exec'],
    'delete'    => ['Thread',  'delete'],
    'lock'      => ['Thread',  'lock'],
    'search'    => ['Board',   'search'],
    'past'      => ['Board',   'past'],
    'desk'      => ['Desk',    'show'],
    'archive'   => ['Thread',  'archive'],
    'manual'    => ['Page',    'manual'],
    'note'      => ['Page',    'note'],
    'enter'     => ['Page',    'enter'],
    'login'     => ['Page',    'login'],
    'logout'    => ['Page',    'logout'],
);

sub dispatch {
    my ($self, $action) = @_;
    $action = '' unless defined $action;

    my $route = $PAGE_ROUTES{$action};
    unless ($route) {
        $self->_error_page("不正なアクションです。");
        return;
    }

    my ($ctrl_name, $method) = @$route;
    my $ctrl = $self->{controllers}{$ctrl_name};

    eval { $ctrl->$method() };
    if ($@) {
        require Encode;
        my $err = Encode::encode_utf8($@);
        warn "[LetterBBS] dispatch error ($action): $err";
        $self->_error_page("内部エラーが発生しました。") unless $self->{config}->get('debug');
        $self->_error_page("エラー: $err") if $self->{config}->get('debug');
    }
}

# API (api.cgi) のルーティング
my %API_ROUTES = (
    'threads'     => ['Notification', 'thread_list'],
    'timeline'    => ['Notification', 'timeline'],
    'desk_list'   => ['Desk',         'api_list'],
    'desk_save'   => ['Desk',         'api_save'],
    'desk_delete' => ['Desk',         'api_delete'],
    'desk_send'   => ['Desk',         'api_send'],
);

sub dispatch_api {
    my ($self, $api_action) = @_;
    $api_action = '' unless defined $api_action;

    my $route = $API_ROUTES{$api_action};
    unless ($route) {
        $self->_json_error("不正なAPIです。", "INVALID_API");
        return;
    }

    my ($ctrl_name, $method) = @$route;
    my $ctrl = $self->{controllers}{$ctrl_name};

    eval { $ctrl->$method() };
    if ($@) {
        require Encode;
        warn "[LetterBBS] API error ($api_action): " . Encode::encode_utf8($@);
        $self->_json_error("内部エラーが発生しました。", "SERVER_ERROR");
    }
}

# 管理画面 (admin.cgi) のルーティング
my %ADMIN_ROUTES = (
    ''              => ['Admin', 'login_form'],
    'login'         => ['Admin', 'login'],
    'logout'        => ['Admin', 'logout'],
    'menu'          => ['Admin', 'menu'],
    'threads'       => ['Admin', 'thread_list'],
    'thread_detail' => ['Admin', 'thread_detail'],
    'thread_exec'   => ['Admin', 'thread_exec'],
    'members'       => ['Admin', 'member_list'],
    'member_exec'   => ['Admin', 'member_exec'],
    'settings'      => ['Admin', 'settings'],
    'settings_exec' => ['Admin', 'settings_exec'],
    'design'        => ['Admin', 'design'],
    'design_exec'   => ['Admin', 'design_exec'],
    'password'      => ['Admin', 'password_form'],
    'password_exec' => ['Admin', 'password_exec'],
    'size_check'    => ['Admin', 'size_check'],
);

sub dispatch_admin {
    my ($self, $action) = @_;
    $action = '' unless defined $action;

    my $route = $ADMIN_ROUTES{$action};
    unless ($route) {
        $self->_error_page("不正なアクションです。");
        return;
    }

    my ($ctrl_name, $method) = @$route;
    my $ctrl = $self->{controllers}{$ctrl_name};

    eval { $ctrl->$method() };
    if ($@) {
        require Encode;
        warn "[LetterBBS] admin error ($action): " . Encode::encode_utf8($@);
        $self->_error_page("内部エラーが発生しました。");
    }
}

sub _error_page {
    my ($self, $msg) = @_;
    my $html = $self->{template}->render_with_layout('error.html',
        error_title   => 'エラー',
        error_message => $msg,
        back_url      => $self->{config}->get('cgi_url'),
        bbs_title     => $self->{config}->get('bbs_title'),
        css_url       => $self->{config}->css_url(),
        cgi_url       => $self->{config}->get('cgi_url'),
        page_title    => 'エラー',
    );
    print "Content-Type: text/html; charset=utf-8\n";
    if (my $cookie = $self->{session}->cookie_header()) {
        $cookie = "Set-Cookie: " . $cookie unless $cookie =~ /^Set-Cookie:/i;
        print "$cookie\n";
    }
    print "\n";
    binmode STDOUT, ":utf8";
    print $html;
}

sub _json_error {
    my ($self, $msg, $code) = @_;
    require JSON::PP;
    my $json = JSON::PP::encode_json({
        success    => JSON::PP::false,
        error      => $msg,
        error_code => $code || 'UNKNOWN',
    });
    # ヘッダーは呼び出し元で出力済みの前提
    print $json;
}

1;
