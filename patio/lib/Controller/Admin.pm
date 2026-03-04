package LetterBBS::Controller::Admin;

#============================================================================
# LetterBBS ver2 - 管理画面コントローラー
#============================================================================

use strict;
use warnings;
use utf8;
use LetterBBS::Sanitize;
use LetterBBS::Auth;
use LetterBBS::Model::Thread;
use LetterBBS::Model::Post;
use LetterBBS::Model::User;
use LetterBBS::Model::AdminAuth;
use LetterBBS::Model::Setting;

sub new {
    my ($class, %ctx) = @_;
    return bless {
        config     => $ctx{config},
        db         => $ctx{db},
        session    => $ctx{session},
        template   => $ctx{template},
        cgi        => $ctx{cgi},
        thread_m   => LetterBBS::Model::Thread->new($ctx{db}),
        post_m     => LetterBBS::Model::Post->new($ctx{db}),
        user_m     => LetterBBS::Model::User->new($ctx{db}),
        admin_m    => LetterBBS::Model::AdminAuth->new($ctx{db}, $ctx{config}),
        setting_m  => LetterBBS::Model::Setting->new($ctx{db}),
    }, $class;
}

# ログインフォーム表示
sub login_form {
    my ($self) = @_;
    # 既にログイン済みならメニューへ
    if ($self->{session}->get('admin_login')) {
        return $self->menu();
    }
    my $html = $self->{template}->render('admin/login.html',
        $self->_admin_vars(),
        page_title => '管理画面ログイン',
        error_msg  => '',
    );
    $self->_output_html($html);
}

# ログイン実行
sub login {
    my ($self) = @_;
    my $login_id = LetterBBS::Sanitize::sanitize_input($self->{cgi}->param('login_id') || '');
    my $password = $self->{cgi}->param('password') || '';

    my $result = $self->{admin_m}->authenticate($login_id, $password);

    if ($result->{success}) {
        $self->{session}->regenerate();
        $self->{session}->set('admin_login', $login_id);
        print "Status: 302 Found\n";
        print "Location: " . $self->{config}->get('admin_url') . "?action=menu\n";
        print $self->{session}->cookie_header() . "\n" if $self->{session}->cookie_header();
        print "\n";
    } else {
        my $html = $self->{template}->render('admin/login.html',
            $self->_admin_vars(),
            page_title => '管理画面ログイン',
            error_msg  => $result->{reason},
        );
        $self->_output_html($html);
    }
}

# ログアウト
sub logout {
    my ($self) = @_;
    $self->{session}->destroy();
    print "Status: 302 Found\n";
    print "Location: " . $self->{config}->get('admin_url') . "\n";
    print $self->{session}->cookie_header() . "\n" if $self->{session}->cookie_header();
    print "\n";
}

# メニュー
sub menu {
    my ($self) = @_;
    return $self->_require_login() unless $self->{session}->get('admin_login');

    my $active_count   = $self->{thread_m}->count_by_status('active');
    my $archived_count = $self->{thread_m}->count_by_status('archived');
    my $user_count     = $self->{user_m}->count();

    # DB ファイルサイズ
    my $db_size = -s $self->{config}->get('db_file') || 0;
    my $db_size_mb = sprintf("%.2f", $db_size / 1024 / 1024);

    my $html = $self->{template}->render('admin/menu.html',
        $self->_admin_vars(),
        page_title     => '管理メニュー',
        active_count   => $active_count,
        archived_count => $archived_count,
        user_count     => $user_count,
        db_size        => $db_size_mb,
        login_id       => $self->{session}->get('admin_login'),
    );
    $self->_output_html($html);
}

# スレッド管理一覧
sub thread_list {
    my ($self) = @_;
    return $self->_require_login() unless $self->{session}->get('admin_login');

    my $page     = LetterBBS::Sanitize::to_uint($self->{cgi}->param('page'), 1);
    my $status   = $self->{cgi}->param('status') || 'active';
    $status = 'active' unless $status =~ /^(active|archived)$/;

    my $threads = $self->{thread_m}->list(status => $status, page => $page, per_page => 50);
    my $total   = $self->{thread_m}->count_by_status($status);

    for my $t (@$threads) {
        $t->{display_date} = _format_date($t->{updated_at});
    }

    my $html = $self->{template}->render('admin/threads.html',
        $self->_admin_vars(),
        page_title => 'スレッド管理',
        threads    => $threads,
        status     => $status,
        page       => $page,
        total      => $total,
    );
    $self->_output_html($html);
}

# スレッド内記事管理
sub thread_detail {
    my ($self) = @_;
    return $self->_require_login() unless $self->{session}->get('admin_login');

    my $id = LetterBBS::Sanitize::to_uint($self->{cgi}->param('id'));
    my $thread = $self->{thread_m}->find($id);
    return $self->_admin_error('スレッドが見つかりません。') unless $thread;

    my ($parent, $replies) = $self->{post_m}->list_by_thread($id, page => 1, per_page => 999999, include_deleted => 1);

    my $html = $self->{template}->render('admin/thread_detail.html',
        $self->_admin_vars(),
        page_title => '記事管理: ' . $thread->{subject},
        thread     => $thread,
        parent     => $parent,
        replies    => $replies,
    );
    $self->_output_html($html);
}

# スレッド操作実行（削除・ロック・アーカイブ）
sub thread_exec {
    my ($self) = @_;
    return $self->_require_login() unless $self->{session}->get('admin_login');

    my $cgi    = $self->{cgi};
    my $csrf_token = $cgi->param('csrf_token') || '';
    unless (LetterBBS::Auth::verify_csrf_token($csrf_token, $self->{session}->id(), $self->{config}->get('csrf_secret'))) {
        return $self->_admin_error('セッションがタイムアウトしたか、不正なリクエストです。');
    }

    my $action = $cgi->param('exec') || '';
    my $id     = LetterBBS::Sanitize::to_uint($cgi->param('thread_id') || $cgi->param('ids'));
    
    # 配列から最初の値を取る（複数選択時は全てに適用）
    my @ids = $cgi->param('ids');
    @ids = ($id) if !@ids && $id;

    if ($action eq 'delete') {
        for my $target_id (@ids) {
            $self->{thread_m}->destroy($target_id, $self->{config}->get('upl_dir'));
        }
    } elsif ($action eq 'lock') {
        for my $target_id (@ids) {
            $self->{thread_m}->update($target_id, is_locked => 1);
        }
    } elsif ($action eq 'unlock') {
        for my $target_id (@ids) {
            $self->{thread_m}->update($target_id, is_locked => 0);
        }
    } elsif ($action eq 'archive') {
        for my $target_id (@ids) {
            $self->{thread_m}->update($target_id, status => 'archived');
        }
    } elsif ($action eq 'restore') {
        for my $target_id (@ids) {
            $self->{thread_m}->update($target_id, status => 'active');
        }
    } elsif ($action eq 'delete_posts') {
        my @post_ids = $cgi->param('post_ids');
        for my $post_id (@post_ids) {
            my $clean_id = LetterBBS::Sanitize::to_uint($post_id);
            $self->{post_m}->soft_delete($clean_id) if $clean_id;
        }
    }

    print "Status: 302 Found\n";
    print "Location: " . $self->{config}->get('admin_url') . "?action=threads\n";
    print $self->{session}->cookie_header() . "\n" if $self->{session}->cookie_header();
    print "\n";
}

# 会員管理一覧
sub member_list {
    my ($self) = @_;
    return $self->_require_login() unless $self->{session}->get('admin_login');

    my $users = $self->{user_m}->list();
    my $html = $self->{template}->render('admin/members.html',
        $self->_admin_vars(),
        page_title => '会員管理',
        users      => $users,
    );
    $self->_output_html($html);
}

# 会員操作
sub member_exec {
    my ($self) = @_;
    return $self->_require_login() unless $self->{session}->get('admin_login');

    my $cgi    = $self->{cgi};
    my $csrf_token = $cgi->param('csrf_token') || '';
    unless (LetterBBS::Auth::verify_csrf_token($csrf_token, $self->{session}->id(), $self->{config}->get('csrf_secret'))) {
        return $self->_admin_error('セッションがタイムアウトしたか、不正なリクエストです。');
    }

    my $action = $cgi->param('exec') || '';

    if ($action eq 'add') {
        my $login_id = LetterBBS::Sanitize::sanitize_input($cgi->param('login_id') || '');
        my $password = $cgi->param('password') || '';
        my $name     = LetterBBS::Sanitize::sanitize_input($cgi->param('name') || '');
        my $rank     = LetterBBS::Sanitize::to_uint($cgi->param('rank'), 2);
        if ($login_id ne '' && $password ne '') {
            eval { $self->{user_m}->create(login_id => $login_id, password => $password, name => $name, rank => $rank); };
        }
    } elsif ($action eq 'delete') {
        my $user_id = LetterBBS::Sanitize::to_uint($cgi->param('user_id'));
        $self->{user_m}->delete($user_id) if $user_id;
    }

    print "Status: 302 Found\n";
    print "Location: " . $self->{config}->get('admin_url') . "?action=members\n";
    print $self->{session}->cookie_header() . "\n" if $self->{session}->cookie_header();
    print "\n";
}

# 設定画面
sub settings {
    my ($self) = @_;
    return $self->_require_login() unless $self->{session}->get('admin_login');

    my $all = $self->{setting_m}->get_all();
    my $html = $self->{template}->render('admin/settings.html',
        $self->_admin_vars(),
        page_title => '設定',
        settings   => $all,
        %$all,
    );
    $self->_output_html($html);
}

# 設定保存
sub settings_exec {
    my ($self) = @_;
    return $self->_require_login() unless $self->{session}->get('admin_login');

    my $cgi = $self->{cgi};
    my $csrf_token = $cgi->param('csrf_token') || '';
    unless (LetterBBS::Auth::verify_csrf_token($csrf_token, $self->{session}->id(), $self->{config}->get('csrf_secret'))) {
        return $self->_admin_error('セッションがタイムアウトしたか、不正なリクエストです。');
    }

    my %save;
    for my $key (qw(bbs_title i_max p_max m_max pg_max pgmax_now pgmax_past authkey authtime image_upl use_captcha wait max_failpass lock_days)) {
        my $val = LetterBBS::Sanitize::sanitize_input($cgi->param($key) || '');
        $save{$key} = $val if $val ne '';
    }
    $self->{setting_m}->set_bulk(%save) if %save;
    $self->{config}->load_db_settings($self->{db});

    print "Status: 302 Found\n";
    print "Location: " . $self->{config}->get('admin_url') . "?action=settings\n";
    print $self->{session}->cookie_header() . "\n" if $self->{session}->cookie_header();
    print "\n";
}

# テーマ設定
sub design {
    my ($self) = @_;
    return $self->_require_login() unless $self->{session}->get('admin_login');

    my $current = $self->{setting_m}->get('theme') || 'standard';
    my $html = $self->{template}->render('admin/design.html',
        $self->_admin_vars(),
        page_title    => 'デザイン設定',
        current_theme => $current,
        is_standard   => ($current eq 'standard' ? 1 : 0),
        is_gloomy     => ($current eq 'gloomy'   ? 1 : 0),
        is_simple     => ($current eq 'simple'   ? 1 : 0),
        is_fox        => ($current eq 'fox'      ? 1 : 0),
    );
    $self->_output_html($html);
}

# テーマ変更実行
sub design_exec {
    my ($self) = @_;
    return $self->_require_login() unless $self->{session}->get('admin_login');

    my $cgi = $self->{cgi};
    my $csrf_token = $cgi->param('csrf_token') || '';
    unless (LetterBBS::Auth::verify_csrf_token($csrf_token, $self->{session}->id(), $self->{config}->get('csrf_secret'))) {
        return $self->_admin_error('セッションがタイムアウトしたか、不正なリクエストです。');
    }

    my $theme = $cgi->param('theme') || 'standard';
    $theme = 'standard' unless $theme =~ /^(standard|gloomy|simple|fox)$/;

    $self->{setting_m}->set('theme', $theme);
    $self->{config}->load_db_settings($self->{db});

    print "Status: 302 Found\n";
    print "Location: " . $self->{config}->get('admin_url') . "?action=design\n";
    print $self->{session}->cookie_header() . "\n" if $self->{session}->cookie_header();
    print "\n";
}

# パスワード変更フォーム
sub password_form {
    my ($self) = @_;
    return $self->_require_login() unless $self->{session}->get('admin_login');

    my $html = $self->{template}->render('admin/password.html',
        $self->_admin_vars(),
        page_title => 'パスワード変更',
        error_msg  => '',
        success    => 0,
    );
    $self->_output_html($html);
}

# パスワード変更実行
sub password_exec {
    my ($self) = @_;
    return $self->_require_login() unless $self->{session}->get('admin_login');

    my $cgi = $self->{cgi};
    my $csrf_token = $cgi->param('csrf_token') || '';
    unless (LetterBBS::Auth::verify_csrf_token($csrf_token, $self->{session}->id(), $self->{config}->get('csrf_secret'))) {
        return $self->_admin_error('セッションがタイムアウトしたか、不正なリクエストです。');
    }

    my $login_id = $self->{session}->get('admin_login');
    my $old_pass = $cgi->param('old_password') || '';
    my $new_pass = $cgi->param('new_password') || '';
    my $confirm  = $cgi->param('confirm_password') || '';

    my $error = '';
    if ($new_pass eq '') {
        $error = '新しいパスワードを入力してください。';
    } elsif ($new_pass ne $confirm) {
        $error = '新しいパスワードが一致しません。';
    } elsif (length($new_pass) < 4) {
        $error = 'パスワードは4文字以上にしてください。';
    }

    unless ($error) {
        my $result = $self->{admin_m}->change_password($login_id, $old_pass, $new_pass);
        $error = $result->{reason} unless $result->{success};
    }

    my $html = $self->{template}->render('admin/password.html',
        $self->_admin_vars(),
        page_title => 'パスワード変更',
        error_msg  => $error,
        success    => ($error eq '' ? 1 : 0),
    );
    $self->_output_html($html);
}

# 容量確認
sub size_check {
    my ($self) = @_;
    return $self->_require_login() unless $self->{session}->get('admin_login');

    my $db_file = $self->{config}->get('db_file');
    my $upl_dir = $self->{config}->get('upl_dir');

    my $db_size = -s $db_file || 0;
    my $upl_size = 0;
    if (opendir my $dh, $upl_dir) {
        while (my $f = readdir $dh) {
            next if $f =~ /^\./;
            $upl_size += -s "$upl_dir/$f" || 0;
        }
        closedir $dh;
    }

    my $html = $self->{template}->render('admin/size_check.html',
        $self->_admin_vars(),
        page_title => '容量確認',
        db_size    => sprintf("%.2f MB", $db_size / 1024 / 1024),
        upl_size   => sprintf("%.2f MB", $upl_size / 1024 / 1024),
        total_size => sprintf("%.2f MB", ($db_size + $upl_size) / 1024 / 1024),
    );
    $self->_output_html($html);
}

#--- 内部メソッド ---

sub _require_login {
    my ($self) = @_;
    print "Status: 302 Found\n";
    print "Location: " . $self->{config}->get('admin_url') . "\n";
    print "\n";
}

sub _admin_vars {
    my ($self) = @_;
    my $csrf_token = LetterBBS::Auth::generate_csrf_token(
        $self->{session}->id(), $self->{config}->get('csrf_secret')
    );
    return (
        bbs_title  => $self->{config}->get('bbs_title'),
        admin_url  => $self->{config}->get('admin_url'),
        cgi_url    => $self->{config}->get('cgi_url'),
        css_url    => './cmn/admin.css',
        csrf_token => $csrf_token,
    );
}

sub _output_html {
    my ($self, $html) = @_;
    print "Content-Type: text/html; charset=utf-8\n";
    print "X-Content-Type-Options: nosniff\n";
    print "X-Frame-Options: DENY\n";
    print $self->{session}->cookie_header() . "\n" if $self->{session}->cookie_header();
    print "\n";
    print $html;
}

sub _admin_error {
    my ($self, $msg) = @_;
    my $html = "<html><body><h2>エラー</h2><p>$msg</p><p><a href='" . $self->{config}->get('admin_url') . "?action=menu'>メニューに戻る</a></p></body></html>";
    $self->_output_html($html);
}

sub _format_date {
    my ($dt) = @_;
    return '' unless $dt;
    $dt =~ s/^(\d{4})-(\d{2})-(\d{2}) (\d{2}):(\d{2}).*/$1\/$2\/$3 $4:$5/;
    return $dt;
}

1;
