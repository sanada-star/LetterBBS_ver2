package LetterBBS::Controller::Page;

#============================================================================
# LetterBBS ver2 - 静的ページコントローラー
#============================================================================

use strict;
use warnings;
use utf8;
use LetterBBS::Sanitize;
use LetterBBS::Auth;
use LetterBBS::Model::User;

sub new {
    my ($class, %ctx) = @_;
    return bless {
        config   => $ctx{config},
        db       => $ctx{db},
        session  => $ctx{session},
        template => $ctx{template},
        cgi      => $ctx{cgi},
        user_m   => LetterBBS::Model::User->new($ctx{db}),
    }, $class;
}

# マニュアル表示
sub manual {
    my ($self) = @_;
    my $html = $self->{template}->render_with_layout('manual.html',
        $self->_common_vars(),
        page_title => '使い方・マニュアル',
    );
    $self->_output_html($html);
}

# 留意事項表示
sub note {
    my ($self) = @_;
    my $html = $self->{template}->render_with_layout('note.html',
        $self->_common_vars(),
        page_title => '留意事項',
    );
    $self->_output_html($html);
}

# ログイン画面（会員認証モード）
sub enter {
    my ($self) = @_;
    unless ($self->{config}->get('authkey')) {
        # 認証モードでない場合はトップへ
        print "Status: 302 Found\n";
        print "Location: " . $self->{config}->get('cgi_url') . "\n\n";
        return;
    }

    my $html = $self->{template}->render_with_layout('enter.html',
        $self->_common_vars(),
        page_title => 'ログイン',
        error_msg  => '',
    );
    $self->_output_html($html);
}

# 会員ログイン実行
sub login {
    my ($self) = @_;
    unless ($self->{config}->get('authkey')) {
        print "Status: 302 Found\n";
        print "Location: " . $self->{config}->get('cgi_url') . "\n\n";
        return;
    }

    my $login_id = LetterBBS::Sanitize::sanitize_input($self->{cgi}->param('login_id') || '');
    my $password = $self->{cgi}->param('password') || '';

    my $user = $self->{user_m}->authenticate($login_id, $password);
    if ($user) {
        $self->{session}->regenerate();
        $self->{session}->set('user_id', $user->{id});
        $self->{session}->set('user_name', $user->{name});
        $self->{session}->set('user_rank', $user->{rank});

        print "Status: 302 Found\n";
        print "Location: " . $self->{config}->get('cgi_url') . "\n";
        print $self->{session}->cookie_header() . "\n" if $self->{session}->cookie_header();
        print "\n";
    } else {
        my $html = $self->{template}->render_with_layout('enter.html',
            $self->_common_vars(),
            page_title => 'ログイン',
            error_msg  => 'ログインIDまたはパスワードが正しくありません。',
        );
        $self->_output_html($html);
    }
}

# 会員ログアウト
sub logout {
    my ($self) = @_;
    $self->{session}->destroy();
    print "Status: 302 Found\n";
    print "Location: " . $self->{config}->get('cgi_url') . "\n";
    print $self->{session}->cookie_header() . "\n" if $self->{session}->cookie_header();
    print "\n";
}

#--- 内部メソッド ---

sub _common_vars {
    my ($self) = @_;
    return (
        bbs_title => $self->{config}->get('bbs_title') || '',
        css_url   => $self->{config}->css_url() || '',
        cgi_url   => $self->{config}->get('cgi_url') || '',
        api_url   => $self->{config}->get('api_url') || '',
        admin_url => $self->{config}->get('admin_url') || '',
    );
}

sub _output_html {
    my ($self, $html) = @_;
    print "Content-Type: text/html; charset=utf-8\n";
    print "X-Content-Type-Options: nosniff\n";
    print "X-Frame-Options: DENY\n";
    print "Referrer-Policy: same-origin\n";
    if (my $cookie = $self->{session}->cookie_header()) {
        $cookie = "Set-Cookie: " . $cookie unless $cookie =~ /^Set-Cookie:/i;
        print "$cookie\n";
    }
    print "\n";
    binmode STDOUT, ":utf8";
    print $html;
}

1;
