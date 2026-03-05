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

    # 親記事と返信に画像情報・相手スレッドID を付加
    my %author_thread_cache;  # 著者→スレッドIDのキャッシュ
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

        # 投稿者のスレッド（私書箱）を検索して author_thread_id を付加
        my $post_author = $post->{author} || '';
        if ($post_author ne '' && !exists $author_thread_cache{$post_author}) {
            my $at = $self->{thread_m}->find_by_author($post_author);
            $author_thread_cache{$post_author} = $at ? $at->{id} : 0;
        }
        $post->{author_thread_id} = $author_thread_cache{$post_author} || 0;
    }

    # CSRF トークン（返信フォーム用）
    my $csrf_token = LetterBBS::Auth::generate_csrf_token(
        $self->{session}->id(), $self->{config}->get('csrf_secret')
    );

    # スレッド残量アラーム（90%超過）
    my $m_max = $self->{config}->get('m_max') || 1000;
    my $nearly_full = ($total_replies >= $m_max * 0.9) ? 1 : 0;

    my $base_url = ($self->{config}->get('cgi_url') || '') . "?mode=read&id=$id";

    # クッキーから前回の入力値を復元（返信フォーム用）
    my $cookie_name = $self->_get_cookie('letterbbs_name');

    # $parent が undef の場合のガード
    my $p_author = $parent ? ($parent->{author} || '') : '';
    my $p_trip   = $parent ? ($parent->{trip} || '') : '';
    my $p_has_trip = $parent ? ($parent->{has_trip} || 0) : 0;
    my $p_display_date = $parent ? ($parent->{display_date} || '') : '';
    my $p_formatted_body = $parent ? ($parent->{formatted_body} || '') : '';
    my $p_images = $parent ? ($parent->{images} || []) : [];

    my $html = $self->{template}->render_with_layout('read.html',
        $self->_common_vars(),
        page_title   => $thread->{subject},
        thread_id    => $id,
        thread       => $thread,
        parent       => $parent,
        parent_author => $p_author,
        parent_trip   => $p_trip,
        parent_has_trip => $p_has_trip,
        parent_display_date => $p_display_date,
        parent_formatted_body => $p_formatted_body,
        parent_images => $p_images,
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
        form_name    => $cookie_name,
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

        # 引用（クロススレッド対応: quote_from で引用元スレッドを指定可能）
        if ($quote_seq) {
            my $quote_from = LetterBBS::Sanitize::to_uint($self->{cgi}->param('quote_from'));
            my $source_thread = $quote_from || $thread_id;
            my $quote_post = $self->{post_m}->find_by_thread_seq($source_thread, $quote_seq);
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
    my $cookie_name  = $self->_get_cookie('letterbbs_name');
    my $cookie_email = $self->_get_cookie('letterbbs_email');

    my $html = $self->{template}->render_with_layout('form.html',
        $self->_common_vars(),
        page_title     => $thread ? '返信: ' . $thread->{subject} : '新規投稿',
        thread_subject => $thread ? $thread->{subject} : '',
        thread         => $thread,
        thread_id      => $thread_id || 0,
        is_reply       => $thread_id ? 1 : 0,
        csrf_token     => $csrf_token,
        form_name      => $cookie_name,
        form_email     => $cookie_email,
        form_body      => $quote_body,
        image_upl      => $self->{config}->get('image_upl'),
        use_captcha    => $self->{config}->get('use_captcha'),
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
    my $target_thread_id;
    eval {
        $self->{db}->begin_transaction();

        $target_thread_id = $thread_id;

        unless ($thread_id) {
            # 新規スレッド作成
            $target_thread_id = $self->{thread_m}->create(
                subject => $subject,
                author  => $clean_name,
                email   => $email,
            );
            # トリガーはseq_no>0のみ発火するため、親投稿のメタデータを明示設定
            $self->{thread_m}->update($target_thread_id, last_author => $clean_name);
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
    };
    if ($@) {
        eval { $self->{db}->rollback() };
        warn "[LetterBBS] post error: $@";
        return $self->_error('投稿の保存に失敗しました。もう一度お試しください。');
    }

    # クッキー保存（トランザクション外で出力）
    _set_cookies($clean_name, $email);

    # リダイレクト
    my $redirect_url = ($self->{config}->get('cgi_url') || '') . "?mode=read&id=$target_thread_id";
    print "Status: 302 Found\n";
    print "Location: $redirect_url\n";
    print $self->{session}->cookie_header() . "\n" if $self->{session}->cookie_header();
    print "\n";
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

    my $redirect_url = ($self->{config}->get('cgi_url') || '') . "?mode=read&id=$thread_id";
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

    my $redirect_url = ($self->{config}->get('cgi_url') || '') . "?mode=read&id=$thread_id";
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

    # 相手の一覧を抽出
    my %partners;
    for my $post (@$posts) {
        next unless $post && !$post->{is_deleted};
        my $author = $post->{author} || '';
        # 自分が書いたものではないなら相手として記録
        if ($author ne $thread->{author} && $author ne '') {
            $partners{$author} = 1;
        }
    }
    my @partner_list = sort keys %partners;

    my $html = <<"HTML";
<!DOCTYPE html>
<html lang="ja">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>$title - LetterBBS Archive</title>
<style>
body { font-family: 'Helvetica Neue', Arial, sans-serif; background: #f5f5f5; margin: 0; padding: 0; display: flex; height: 100vh; overflow: hidden; }
.sidebar { width: 250px; background: #fff; box-shadow: 1px 0 5px rgba(0,0,0,0.1); overflow-y: auto; display: flex; flex-direction: column; z-index: 10; padding-top: 20px; flex-shrink: 0; }
.sidebar h2 { font-size: 1.1em; color: #333; margin: 0 0 10px 0; padding: 0 15px; }
.menu-item { padding: 10px 15px; cursor: pointer; border-bottom: 1px solid #eee; color: #555; transition: background 0.2s; word-break: break-all; }
.menu-item:hover { background: #f9f9f9; }
.menu-item.active { background: #ff4757; color: #fff; border-bottom: none; font-weight: bold; }
.main-content { flex: 1; overflow-y: auto; padding: 20px; position: relative; }
.pane { display: none; max-width: 800px; margin: 0 auto; }
.pane.active { display: block; }

h1 { color: #333; border-bottom: 2px solid #ff4757; padding-bottom: 10px; margin-top: 0; }
.post { background: #fff; margin: 15px 0; padding: 20px; border-radius: 8px; box-shadow: 0 1px 3px rgba(0,0,0,0.1); }
.post-title { font-size: 1.15em; font-weight: bold; color: #ff4757; margin-bottom: 8px; padding-bottom: 8px; border-bottom: 1px solid #eee; }
.post-header { display: flex; flex-wrap: wrap; justify-content: space-between; align-items: baseline; margin-bottom: 12px; color: #666; font-size: 0.95em; }
.post-author { font-weight: bold; color: #333; margin-right: 15px; font-size: 1.05em; }
.post-date { color: #888; text-align: right; margin-left: auto; }
.post-body { line-height: 1.8; word-break: break-word; font-size: 1em; margin-top: 5px; }
.post-image { max-width: 100%; border-radius: 4px; margin: 8px 0; }
footer { text-align: center; color: #999; margin-top: 30px; font-size: 0.8em; padding-bottom: 20px; }

/* タイムラインレイアウト */
.timeline-sent .post { border-left: 5px solid #3498db; background: #fdfefe; }
.timeline-received .post { border-left: 5px solid #ff4757; background: #fff; }

\@media (max-width: 768px) {
  body { flex-direction: column; }
  .sidebar { width: 100%; height: auto; max-height: 200px; border-bottom: 2px solid #ff4757; padding-top: 10px; }
  .main-content { height: calc(100vh - 200px); }
}
</style>
<script>
function switchPane(paneId) {
    document.querySelectorAll('.menu-item').forEach(function(el) { el.classList.remove('active'); });
    document.querySelectorAll('.pane').forEach(function(el) { el.classList.remove('active'); });
    var btn = document.querySelector('[data-target="' + paneId + '"]');
    if (btn) btn.classList.add('active');
    var pane = document.getElementById(paneId);
    if (pane) pane.classList.add('active');
}
</script>
</head>
<body>

<div class="sidebar">
    <h2>思い出を保存</h2>
    <div class="menu-item active" data-target="pane-all" onclick="switchPane('pane-all')">📖 スレッド全件表示</div>
HTML

    if (@partner_list) {
        $html .= "    <h2 style='margin-top:20px;'>タイムライン表示</h2>\n";
        my $idx = 0;
        for my $partner (@partner_list) {
            my $p_esc = LetterBBS::Sanitize::html_escape($partner);
            $html .= qq{    <div class="menu-item" data-target="pane-tl-$idx" onclick="switchPane('pane-tl-$idx')">💬 $p_esc とのやり取り</div>\n};
            $idx++;
        }
    }

    $html .= <<"HTML";
</div>

<div class="main-content">
<!-- スレッド全件表示ペイン -->
<div id="pane-all" class="pane active">
    <h1>$title</h1>
    <p>作成者: $t_author | 投稿数: $thread->{post_count}</p>
HTML

    # 全件ログの生成
    for my $post (@$posts) {
        next unless $post && !$post->{is_deleted};
        my $author = LetterBBS::Sanitize::html_escape($post->{author});
        my $subject_esc = LetterBBS::Sanitize::html_escape($post->{subject} || '無題');
        my $trip = $post->{trip} ? "◆$post->{trip}" : '';
        my $date = $post->{created_at} || '';
        my $body = $post->{body} || '';
        $body =~ s/\r?\n/<br>/g;
        $body = LetterBBS::Sanitize::autolink($body);

        $html .= qq{    <div class="post">\n};
        $html .= qq{        <div class="post-title">$subject_esc</div>\n};
        $html .= qq{        <div class="post-header"><span class="post-author">$author$trip</span><span class="post-date">$date</span></div>\n};
        $html .= qq{        <div class="post-body">$body</div>\n};
        $html .= qq{    </div>\n};
    }
    
    $html .= "</div>\n\n";

    # パートナーごとのタイムラインペインの生成
    my $idx = 0;
    for my $partner (@partner_list) {
        $html .= qq{<div id="pane-tl-$idx" class="pane">\n};
        $html .= "    <h1>" . LetterBBS::Sanitize::html_escape($partner) . " とのタイムライン</h1>\n";
        
        my $timeline_posts = $self->{post_m}->timeline($thread->{author}, $partner);

        for my $post (@$timeline_posts) {
            next unless $post;
            
            my $dir_class = 'timeline-received';
            if ($post->{direction} && $post->{direction} eq 'sent') {
                $dir_class = 'timeline-sent';
            }
            
            my $author_esc = LetterBBS::Sanitize::html_escape($post->{author} || '');
            my $subject_esc = LetterBBS::Sanitize::html_escape($post->{subject} || '無題');
            my $trip = $post->{trip} ? "◆$post->{trip}" : '';
            my $date = $post->{created_at} || '';
            my $body = $post->{body} || '';
            $body =~ s/\r?\n/<br>/g;
            $body = LetterBBS::Sanitize::autolink($body);

            $html .= qq{    <div class="$dir_class">\n};
            $html .= qq{        <div class="post">\n};
            $html .= qq{            <div class="post-title">$subject_esc</div>\n};
            $html .= qq{            <div class="post-header"><span class="post-author">$author_esc$trip</span><span class="post-date">$date</span></div>\n};
            $html .= qq{            <div class="post-body">$body</div>\n};
            $html .= qq{        </div>\n};
            $html .= qq{    </div>\n};
        }
        $html .= "</div>\n\n";
        $idx++;
    }

    $html .= "<footer>LetterBBS Archive - Generated at " . _now() . "</footer>\n";
    $html .= "</div>\n</body></html>";

    return $html;
}

sub _common_vars {
    my ($self) = @_;
    return (
        bbs_title  => $self->{config}->get('bbs_title') || '',
        css_url    => $self->{config}->css_url() || '',
        cgi_url    => $self->{config}->get('cgi_url') || '',
        api_url    => $self->{config}->get('api_url') || '',
        admin_url  => $self->{config}->get('admin_url') || '',
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
    my ($self, $name) = @_;
    my $cookie = $ENV{HTTP_COOKIE} || '';
    if ($cookie =~ /(?:^|;\s*)\Q$name\E=([^;]*)/) {
        my $val = $1;
        $val =~ s/\+/ /g;
        $val =~ s/%([0-9A-Fa-f]{2})/chr(hex($1))/ge;
        eval {
            require Encode;
            $val = Encode::decode_utf8($val);
        };
        return $val;
    }
    return '';
}

# 名前・メールアドレスのみクッキーに保存（パスワードは保存しない）
sub _set_cookies {
    my ($name, $email) = @_;
    my $expires = _cookie_expires(30);
    require Encode;
    for my $pair (['letterbbs_name', $name], ['letterbbs_email', $email]) {
        my $val = $pair->[1] || '';
        my $enc_val = Encode::encode_utf8($val);
        $enc_val =~ s/([^\w\-\.~])/sprintf("%%%02X", ord($1))/ge;
        print "Set-Cookie: $pair->[0]=$enc_val; Path=/; Expires=$expires; SameSite=Lax\n";
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
