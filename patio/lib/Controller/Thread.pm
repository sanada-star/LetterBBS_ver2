package LetterBBS::Controller::Thread;

#============================================================================
# LetterBBS ver2 - スレッド操作コントローラー
#============================================================================

use strict;
use warnings;
use utf8;
use LetterBBS::Sanitize;
use LetterBBS::Auth;
use LetterBBS::Upload;
use LetterBBS::Model::Thread;
use LetterBBS::Model::Post;

sub new {
    my ($class, %ctx) = @_;
    my $self = bless {
        config   => $ctx{config},
        db       => $ctx{db},
        session  => $ctx{session},
        template => $ctx{template},
        cgi      => $ctx{cgi},
        thread_m => LetterBBS::Model::Thread->new($ctx{db}),
        post_m   => LetterBBS::Model::Post->new($ctx{db}),
    }, $class;
    return $self;
}

# スレッド閲覧
sub read {
    my ($self) = @_;
    my $id   = LetterBBS::Sanitize::to_uint($self->{cgi}->param('id'));
    my $page = LetterBBS::Sanitize::to_uint($self->{cgi}->param('page'), 1);

    my $thread = $self->{thread_m}->find($id);
    unless ($thread && $thread->{status} ne 'deleted') {
        return $self->_error('スレッドが見つかりません。');
    }

    my $per_page = $self->{config}->get('pg_max') || 10;
    my ($parent, $replies) = $self->{post_m}->list_by_thread($id, page => $page, per_page => $per_page);
    my $total_replies = $self->{post_m}->count_replies($id);
    my $total_pages = int(($total_replies + $per_page - 1) / $per_page);
    $total_pages = 1 if $total_pages < 1;

    # アクセスカウント更新
    $self->{thread_m}->increment_access_count($id);

    # 親記事と返信に画像情報を付加
    my @all_posts = ($parent, @$replies);
    for my $post (@all_posts) {
        next unless $post;
        $post->{images} = $self->{post_m}->get_images($post->{id});
        $post->{display_date} = _format_date($post->{created_at});
        $post->{formatted_body} = LetterBBS::Sanitize::autolink(
            LetterBBS::Sanitize::nl2br(
                LetterBBS::Sanitize::html_escape($post->{body})
            )
        );
        $post->{has_trip} = ($post->{trip} && $post->{trip} ne '') ? 1 : 0;
        for my $img (@{$post->{images}}) {
            $img->{url} = $self->{config}->get('upl_url') . '/' . $img->{filename};
            my ($dw, $dh) = _resize_dims($img->{width}, $img->{height},
                $self->{config}->get('max_w') || 250,
                $self->{config}->get('max_h') || 250);
            $img->{display_width} = $dw;
            $img->{display_height} = $dh;
        }
    }

    # CSRF トークン（返信フォーム用）
    my $csrf_token = LetterBBS::Auth::generate_csrf_token(
        $self->{session}->id(), $self->{config}->get('csrf_secret')
    );

    # スレッド残量アラーム（90%超過）
    my $m_max = $self->{config}->get('m_max') || 1000;
    my $nearly_full = ($total_replies >= $m_max * 0.9) ? 1 : 0;

    my $base_url = $self->{config}->get('cgi_url') . "?action=read&id=$id";

    my $html = $self->{template}->render_with_layout('read.html',
        $self->_common_vars(),
        page_title   => $thread->{subject},
        thread       => $thread,
        parent       => $parent,
        replies      => $replies,
        page         => $page,
        total_pages  => $total_pages,
        total_replies => $total_replies,
        pagination   => LetterBBS::Controller::Board::_pagination($page, $total_pages, $base_url),
        csrf_token   => $csrf_token,
        is_locked    => $thread->{is_locked},
        nearly_full  => $nearly_full,
        access_count => $self->{thread_m}->get_access_count($id),
        image_upl    => $self->{config}->get('image_upl'),
        upl_url      => $self->{config}->get('upl_url'),
    );
    $self->_output_html($html);
}

# 投稿フォーム表示
sub form {
    my ($self) = @_;
    my $thread_id = LetterBBS::Sanitize::to_uint($self->{cgi}->param('id'));
    my $quote_seq = LetterBBS::Sanitize::to_uint($self->{cgi}->param('quote'));

    my $thread = undef;
    my $quote_body = '';

    if ($thread_id) {
        $thread = $self->{thread_m}->find($thread_id);
        return $self->_error('スレッドが見つかりません。') unless $thread;
        return $self->_error('このスレッドはロックされています。') if $thread->{is_locked};

        # 引用
        if ($quote_seq) {
            my $quote_post = $self->{post_m}->find_by_thread_seq($thread_id, $quote_seq);
            if ($quote_post && !$quote_post->{is_deleted}) {
                my $body = LetterBBS::Sanitize::html_unescape($quote_post->{body});
                $body =~ s/<br>/\n/g;
                $quote_body = join("\n", map { "> $_" } split(/\n/, $body));
            }
        }
    }

    my $csrf_token = LetterBBS::Auth::generate_csrf_token(
        $self->{session}->id(), $self->{config}->get('csrf_secret')
    );

    # クッキーから前回の入力値を復元
    my $cookie_name  = _get_cookie('letterbbs_name');
    my $cookie_email = _get_cookie('letterbbs_email');

    my $html = $self->{template}->render_with_layout('form.html',
        $self->_common_vars(),
        page_title  => $thread ? '返信: ' . $thread->{subject} : '新規投稿',
        thread      => $thread,
        thread_id   => $thread_id || 0,
        is_reply    => $thread_id ? 1 : 0,
        csrf_token  => $csrf_token,
        form_name   => $cookie_name,
        form_email  => $cookie_email,
        form_body   => $quote_body,
        image_upl   => $self->{config}->get('image_upl'),
        use_captcha => $self->{config}->get('use_captcha'),
    );
    $self->_output_html($html);
}

# 投稿実行
sub post {
    my ($self) = @_;
    my $cgi = $self->{cgi};

    # CSRF検証
    my $csrf_token = $cgi->param('csrf_token') || '';
    unless (LetterBBS::Auth::verify_csrf_token($csrf_token, $self->{session}->id(), $self->{config}->get('csrf_secret'))) {
        return $self->_error('セッションが無効です。ページを再読み込みしてください。');
    }

    # 入力取得
    my $thread_id = LetterBBS::Sanitize::to_uint($cgi->param('thread_id'));
    my $name    = LetterBBS::Sanitize::sanitize_input($cgi->param('name') || '');
    my $email   = LetterBBS::Sanitize::sanitize_input($cgi->param('email') || '');
    my $subject = LetterBBS::Sanitize::sanitize_input($cgi->param('subject') || '');
    my $body    = LetterBBS::Sanitize::sanitize_input($cgi->param('body') || '');
    my $pwd     = $cgi->param('pwd') || '';
    my $url     = LetterBBS::Sanitize::sanitize_input($cgi->param('url') || '');

    # バリデーション
    return $self->_error('名前を入力してください。') if $name eq '';
    return $self->_error('本文を入力してください。') if $body eq '';
    if (!$thread_id && $subject eq '') {
        return $self->_error('件名を入力してください。');
    }

    # スレッドの存在・ロックチェック（返信時）
    my $thread;
    if ($thread_id) {
        $thread = $self->{thread_m}->find($thread_id);
        return $self->_error('スレッドが見つかりません。') unless $thread;
        return $self->_error('このスレッドはロックされています。') if $thread->{is_locked};

        # 返信数上限チェック
        my $m_max = $self->{config}->get('m_max') || 1000;
        if ($thread->{post_count} >= $m_max) {
            return $self->_error('このスレッドの返信数が上限に達しています。');
        }
    }

    # 連続投稿チェック
    my $host = $ENV{REMOTE_ADDR} || '';
    my $wait = $self->{config}->get('wait') || 15;
    unless ($self->{post_m}->check_flood($host, $wait)) {
        return $self->_error("連続投稿はできません。${wait}秒後にお試しください。");
    }

    # トリップ処理
    my ($clean_name, $trip) = LetterBBS::Auth::generate_trip($name);

    # パスワードハッシュ
    my $pwd_hash = '';
    if ($pwd ne '') {
        $pwd_hash = LetterBBS::Auth::hash_password($pwd);
    }

    # 本文のHTMLエスケープ
    my $escaped_body = LetterBBS::Sanitize::html_escape($body);

    # DB操作（トランザクション）
    eval {
        $self->{db}->begin_transaction();

        my $target_thread_id = $thread_id;

        unless ($thread_id) {
            # 新規スレッド作成
            $target_thread_id = $self->{thread_m}->create(
                subject => $subject,
                author  => $clean_name,
                email   => $email,
            );
        }

        # 投稿作成
        my $seq_no = $thread_id ? undef : 0;  # 新規は0、返信は自動計算
        my $post_id = $self->{post_m}->create(
            thread_id  => $target_thread_id,
            seq_no     => $seq_no,
            author     => $clean_name,
            email      => $email,
            trip       => $trip,
            subject    => $subject,
            body       => $escaped_body,
            password   => $pwd_hash,
            host       => $host,
            url        => $url,
            show_email => ($email ne '' ? 1 : 0),
        );

        # 画像アップロード処理
        if ($self->{config}->get('image_upl')) {
            my $uploader = LetterBBS::Upload->new(
                upl_dir  => $self->{config}->get('upl_dir'),
                upl_url  => $self->{config}->get('upl_url'),
                max_size => $self->{config}->get('max_upload_size') || 5_120_000,
            );
            my $has_image = 0;
            for my $slot (1 .. ($self->{config}->get('max_image_count') || 3)) {
                my $result = $uploader->process($cgi, "file$slot", $target_thread_id, $slot);
                next unless $result;
                if ($result->{error}) {
                    $self->{db}->rollback();
                    return $self->_error($result->{error});
                }
                $self->{post_m}->add_image(
                    post_id   => $post_id,
                    slot      => $slot,
                    filename  => $result->{filename},
                    original  => $result->{original},
                    mime_type => $result->{mime_type},
                    file_size => $result->{file_size},
                    width     => $result->{width},
                    height    => $result->{height},
                );
                $has_image = 1;

                # サムネイル生成
                if ($self->{config}->get('thumbnail')) {
                    $uploader->make_thumbnail($result->{filename},
                        $self->{config}->get('thumb_w'), $self->{config}->get('thumb_h'));
                }
            }
            if ($has_image) {
                $self->{thread_m}->update($target_thread_id, has_image => 1);
            }
        }
        # スレッド数上限チェック → アーカイブ
        my $i_max = $self->{config}->get('i_max') || 1000;
        $self->{thread_m}->archive_old($i_max);

        # 過去ログの上限超過プロセス
        my $p_max = $self->{config}->get('p_max') || 1000;
        $self->{thread_m}->purge_old($p_max, $self->{config}->get('upl_dir'));

        $self->{db}->commit();

    # クッキー保存（パスワードは保存しない）
        _set_cookies($clean_name, $email);

        # リダイレクト
        my $redirect_url = $self->{config}->get('cgi_url') . "?action=read&id=$target_thread_id";
        print "Status: 302 Found\n";
        print "Location: $redirect_url\n";
        print $self->{session}->cookie_header() . "\n" if $self->{session}->cookie_header();
        print "\n";
    };
    if ($@) {
        eval { $self->{db}->rollback() };
        warn "[LetterBBS] post error: $@";
        return $self->_error('投稿の保存に失敗しました。もう一度お試しください。');
    }
}

# パスワード確認フォーム
sub pwd_form {
    my ($self) = @_;
    my $thread_id = LetterBBS::Sanitize::to_uint($self->{cgi}->param('id'));
    my $seq       = LetterBBS::Sanitize::to_uint($self->{cgi}->param('seq'));

    my $csrf_token = LetterBBS::Auth::generate_csrf_token(
        $self->{session}->id(), $self->{config}->get('csrf_secret')
    );

    my $html = $self->{template}->render_with_layout('pwd.html',
        $self->_common_vars(),
        page_title  => 'パスワード確認',
        thread_id   => $thread_id,
        seq         => $seq,
        csrf_token  => $csrf_token,
    );
    $self->_output_html($html);
}

# 編集フォーム表示
sub edit_form {
    my ($self) = @_;
    my $thread_id = LetterBBS::Sanitize::to_uint($self->{cgi}->param('thread_id'));
    my $seq       = LetterBBS::Sanitize::to_uint($self->{cgi}->param('seq'));
    my $pwd       = $self->{cgi}->param('pwd') || '';

    # CSRF検証
    my $csrf_token = $self->{cgi}->param('csrf_token') || '';
    unless (LetterBBS::Auth::verify_csrf_token($csrf_token, $self->{session}->id(), $self->{config}->get('csrf_secret'))) {
        return $self->_error('セッションが無効です。');
    }

    my $post = $self->{post_m}->find_by_thread_seq($thread_id, $seq);
    return $self->_error('記事が見つかりません。') unless $post;
    return $self->_error('パスワードが正しくありません。') unless LetterBBS::Auth::verify_password($pwd, $post->{password});

    # body を表示用に逆変換
    my $edit_body = $post->{body};
    $edit_body =~ s/<br>/\n/g;
    $edit_body = LetterBBS::Sanitize::html_unescape($edit_body);

    my $new_csrf = LetterBBS::Auth::generate_csrf_token(
        $self->{session}->id(), $self->{config}->get('csrf_secret')
    );

    my $images = $self->{post_m}->get_images($post->{id});

    my $html = $self->{template}->render_with_layout('edit.html',
        $self->_common_vars(),
        page_title  => '記事編集',
        thread_id   => $thread_id,
        seq         => $seq,
        post        => $post,
        edit_body   => $edit_body,
        images      => $images,
        csrf_token  => $new_csrf,
        pwd         => $pwd,
        upl_url     => $self->{config}->get('upl_url'),
    );
    $self->_output_html($html);
}

# 編集実行
sub edit_exec {
    my ($self) = @_;
    my $cgi = $self->{cgi};

    my $csrf_token = $cgi->param('csrf_token') || '';
    unless (LetterBBS::Auth::verify_csrf_token($csrf_token, $self->{session}->id(), $self->{config}->get('csrf_secret'))) {
        return $self->_error('セッションが無効です。');
    }

    my $thread_id = LetterBBS::Sanitize::to_uint($cgi->param('thread_id'));
    my $seq       = LetterBBS::Sanitize::to_uint($cgi->param('seq'));
    my $pwd       = $cgi->param('pwd') || '';
    my $subject   = LetterBBS::Sanitize::sanitize_input($cgi->param('subject') || '');
    my $body      = LetterBBS::Sanitize::sanitize_input($cgi->param('body') || '');

    return $self->_error('本文を入力してください。') if $body eq '';

    my $post = $self->{post_m}->find_by_thread_seq($thread_id, $seq);
    return $self->_error('記事が見つかりません。') unless $post;
    return $self->_error('パスワードが正しくありません。') unless LetterBBS::Auth::verify_password($pwd, $post->{password});

    my $escaped_body = LetterBBS::Sanitize::html_escape($body);
    $self->{post_m}->update($post->{id}, subject => $subject, body => $escaped_body);

    my $redirect_url = $self->{config}->get('cgi_url') . "?action=read&id=$thread_id";
    print "Status: 302 Found\n";
    print "Location: $redirect_url\n";
    print $self->{session}->cookie_header() . "\n" if $self->{session}->cookie_header();
    print "\n";
}

# 記事削除
sub delete {
    my ($self) = @_;
    my $cgi = $self->{cgi};

    my $csrf_token = $cgi->param('csrf_token') || '';
    unless (LetterBBS::Auth::verify_csrf_token($csrf_token, $self->{session}->id(), $self->{config}->get('csrf_secret'))) {
        return $self->_error('セッションが無効です。');
    }

    my $thread_id = LetterBBS::Sanitize::to_uint($cgi->param('thread_id'));
    my $seq       = LetterBBS::Sanitize::to_uint($cgi->param('seq'));
    my $pwd       = $cgi->param('pwd') || '';

    my $post = $self->{post_m}->find_by_thread_seq($thread_id, $seq);
    return $self->_error('記事が見つかりません。') unless $post;
    return $self->_error('パスワードが正しくありません。') unless LetterBBS::Auth::verify_password($pwd, $post->{password});

    # 画像ファイル削除
    my $images = $self->{post_m}->get_images($post->{id});
    my $uploader = LetterBBS::Upload->new(
        upl_dir => $self->{config}->get('upl_dir'),
    );
    for my $img (@$images) {
        $uploader->delete_file($img->{filename});
    }

    $self->{post_m}->soft_delete($post->{id});

    my $redirect_url = $self->{config}->get('cgi_url') . "?action=read&id=$thread_id";
    print "Status: 302 Found\n";
    print "Location: $redirect_url\n";
    print $self->{session}->cookie_header() . "\n" if $self->{session}->cookie_header();
    print "\n";
}

# スレッドロック切替
sub lock {
    my ($self) = @_;
    # 管理者のみ実行可能（admin.cgi 経由）
    return $self->_error('この操作は管理画面から行ってください。');
}

# メモリーボックス（アーカイブダウンロード）
sub archive {
    my ($self) = @_;
    my $thread_id = LetterBBS::Sanitize::to_uint($self->{cgi}->param('id'));
    my $partner   = LetterBBS::Sanitize::sanitize_input($self->{cgi}->param('partner') || '');

    my $thread = $self->{thread_m}->find($thread_id);
    return $self->_error('スレッドが見つかりません。') unless $thread;

    # 全投稿を取得
    my ($parent, $replies) = $self->{post_m}->list_by_thread($thread_id, page => 1, per_page => 999999);
    my @all_posts = ($parent, @$replies);

    # HTML生成
    my $archive_html = $self->_generate_archive_html($thread, \@all_posts);

    # ダウンロードヘッダー
    my $filename = "letterbbs_$thread_id.html";
    print "Content-Type: text/html; charset=utf-8\n";
    print "Content-Disposition: attachment; filename=\"$filename\"\n";
    print "\n";
    print $archive_html;
}

#--- 内部メソッド ---

sub _generate_archive_html {
    my ($self, $thread, $posts) = @_;

    my $title  = LetterBBS::Sanitize::html_escape($thread->{subject});
    my $t_author = LetterBBS::Sanitize::html_escape($thread->{author} || '');
    my $html = <<"HTML";
<!DOCTYPE html>
<html lang="ja">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>$title - LetterBBS Archive</title>
<style>
body { font-family: 'Helvetica Neue', Arial, sans-serif; max-width: 800px; margin: 0 auto; padding: 20px; background: #f5f5f5; }
h1 { color: #333; border-bottom: 2px solid #ff4757; padding-bottom: 10px; }
.post { background: #fff; margin: 10px 0; padding: 15px; border-radius: 8px; box-shadow: 0 1px 3px rgba(0,0,0,0.1); }
.post-header { display: flex; justify-content: space-between; margin-bottom: 8px; color: #666; font-size: 0.9em; }
.post-author { font-weight: bold; color: #333; }
.post-body { line-height: 1.6; }
.post-image { max-width: 100%; border-radius: 4px; margin: 8px 0; }
footer { text-align: center; color: #999; margin-top: 30px; font-size: 0.8em; }
</style>
</head>
<body>
<h1>$title</h1>
<p>作成者: $t_author | 投稿数: $thread->{post_count}</p>
HTML

    for my $post (@$posts) {
        next unless $post && !$post->{is_deleted};
        my $author = LetterBBS::Sanitize::html_escape($post->{author});
        my $trip = $post->{trip} ? "◆$post->{trip}" : '';
        my $date = $post->{created_at} || '';
        my $body = $post->{body} || '';

        $html .= qq{<div class="post">\n};
        $html .= qq{<div class="post-header"><span class="post-author">$author$trip</span><span>$date</span></div>\n};
        $html .= qq{<div class="post-body">$body</div>\n};
        $html .= qq{</div>\n};
    }

    $html .= "<footer>LetterBBS Archive - Generated at " . _now() . "</footer>\n";
    $html .= "</body></html>";

    return $html;
}

sub _common_vars {
    my ($self) = @_;
    return (
        bbs_title  => $self->{config}->get('bbs_title'),
        css_url    => $self->{config}->css_url(),
        cgi_url    => $self->{config}->get('cgi_url'),
        api_url    => $self->{config}->get('api_url'),
        admin_url  => $self->{config}->get('admin_url'),
    );
}

sub _output_html {
    my ($self, $html) = @_;
    print "Content-Type: text/html; charset=utf-8\n";
    print "X-Content-Type-Options: nosniff\n";
    print "X-Frame-Options: DENY\n";
    print "Referrer-Policy: same-origin\n";
    print $self->{session}->cookie_header() . "\n" if $self->{session}->cookie_header();
    print "\n";
    print $html;
}

sub _error {
    my ($self, $msg) = @_;
    my $html = $self->{template}->render_with_layout('error.html',
        $self->_common_vars(),
        page_title    => 'エラー',
        error_title   => 'エラー',
        error_message => $msg,
        back_url      => $self->{config}->get('cgi_url'),
    );
    $self->_output_html($html);
}

sub _resize_dims {
    my ($w, $h, $max_w, $max_h) = @_;
    return ($max_w, $max_h) unless $w && $h;
    return ($w, $h) if $w <= $max_w && $h <= $max_h;
    my $ratio = ($w / $max_w > $h / $max_h) ? $max_w / $w : $max_h / $h;
    return (int($w * $ratio), int($h * $ratio));
}

sub _format_date {
    my ($dt) = @_;
    return '' unless $dt;
    if ($dt =~ /^(\d{4})-(\d{2})-(\d{2}) (\d{2}):(\d{2})/) {
        return "$1/$2/$3 $4:$5";
    }
    return $dt;
}

sub _now {
    my @t = localtime;
    return sprintf("%04d-%02d-%02d %02d:%02d:%02d",
        $t[5]+1900, $t[4]+1, $t[3], $t[2], $t[1], $t[0]);
}

sub _get_cookie {
    my ($name) = @_;
    my $cookie = $ENV{HTTP_COOKIE} || '';
    if ($cookie =~ /(?:^|;\s*)$name=([^;]*)/) {
        my $val = $1;
        $val =~ s/\+/ /g;
        $val =~ s/%([0-9A-Fa-f]{2})/chr(hex($1))/ge;
        return $val;
    }
    return '';
}

# 名前・メールアドレスのみクッキーに保存（パスワードは保存しない）
sub _set_cookies {
    my ($name, $email) = @_;
    my $expires = _cookie_expires(30);
    for my $pair (['letterbbs_name', $name], ['letterbbs_email', $email]) {
        my $val = $pair->[1] || '';
        $val =~ s/([^\w\-\.~])/sprintf("%%%02X", ord($1))/ge;
        print "Set-Cookie: $pair->[0]=$val; Path=/; Expires=$expires; SameSite=Lax\n";
    }
}

sub _cookie_expires {
    my ($days) = @_;
    my @t = gmtime(time + $days * 86400);
    my @wday = qw(Sun Mon Tue Wed Thu Fri Sat);
    my @mon  = qw(Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec);
    return sprintf("%s, %02d-%s-%04d %02d:%02d:%02d GMT",
        $wday[$t[6]], $t[3], $mon[$t[4]], $t[5]+1900, $t[2], $t[1], $t[0]);
}

1;
