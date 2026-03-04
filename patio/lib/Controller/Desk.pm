package LetterBBS::Controller::Desk;

#============================================================================
# LetterBBS ver2 - 文通デスクコントローラー
#============================================================================

use strict;
use warnings;
use utf8;
use JSON::PP;
use LetterBBS::Sanitize;
use LetterBBS::Auth;
use LetterBBS::Model::Draft;
use LetterBBS::Model::Post;
use LetterBBS::Model::Thread;

sub new {
    my ($class, %ctx) = @_;
    return bless {
        config   => $ctx{config},
        db       => $ctx{db},
        session  => $ctx{session},
        template => $ctx{template},
        cgi      => $ctx{cgi},
        draft_m  => LetterBBS::Model::Draft->new($ctx{db}),
        post_m   => LetterBBS::Model::Post->new($ctx{db}),
        thread_m => LetterBBS::Model::Thread->new($ctx{db}),
    }, $class;
}

# 文通デスク画面表示（HTML）
sub show {
    my ($self) = @_;
    my $csrf_token = LetterBBS::Auth::generate_csrf_token(
        $self->{session}->id(), $self->{config}->get('csrf_secret')
    );

    my $html = $self->{template}->render_with_layout('desk.html',
        bbs_title  => $self->{config}->get('bbs_title'),
        css_url    => $self->{config}->css_url(),
        cgi_url    => $self->{config}->get('cgi_url'),
        api_url    => $self->{config}->get('api_url'),
        admin_url  => $self->{config}->get('admin_url'),
        page_title => '文通デスク',
        csrf_token => $csrf_token,
    );

    print "Content-Type: text/html; charset=utf-8\n";
    print "X-Content-Type-Options: nosniff\n";
    print $self->{session}->cookie_header() . "\n" if $self->{session}->cookie_header();
    print "\n";
    print $html;
}

# --- API メソッド (JSON応答) ---

# 下書き一覧取得
sub api_list {
    my ($self) = @_;
    my $session_id = $self->{session}->id();
    my $drafts = $self->{draft_m}->list_by_session($session_id);
    $self->_json_response({ success => JSON::PP::true, drafts => $drafts });
}

# 下書き保存
sub api_save {
    my ($self) = @_;
    my $cgi = $self->{cgi};
    my $csrf_token = $cgi->param('csrf_token') || '';
    unless (LetterBBS::Auth::verify_csrf_token($csrf_token, $self->{session}->id(), $self->{config}->get('csrf_secret'))) {
        return $self->_json_error('セッションが無効です。', 'INVALID_TOKEN');
    }
    my $session_id = $self->{session}->id();

    my $draft_id  = LetterBBS::Sanitize::to_uint($cgi->param('draft_id'));
    my $thread_id = LetterBBS::Sanitize::to_uint($cgi->param('thread_id'));
    my $author    = LetterBBS::Sanitize::sanitize_input($cgi->param('author') || '');
    my $subject   = LetterBBS::Sanitize::sanitize_input($cgi->param('subject') || '');
    my $body      = LetterBBS::Sanitize::sanitize_input($cgi->param('body') || '');

    unless ($thread_id) {
        return $self->_json_error('スレッドIDが指定されていません。', 'INVALID_PARAMS');
    }

    # スレッド存在チェック
    my $thread = $self->{thread_m}->find($thread_id);
    unless ($thread) {
        return $self->_json_error('スレッドが見つかりません。', 'NOT_FOUND');
    }

    if ($draft_id) {
        # 更新
        my $draft = $self->{draft_m}->find($draft_id);
        unless ($draft && $draft->{session_id} eq $session_id) {
            return $self->_json_error('下書きが見つかりません。', 'NOT_FOUND');
        }
        $self->{draft_m}->update($draft_id, author => $author, subject => $subject, body => $body);
    } else {
        # 新規作成
        $draft_id = $self->{draft_m}->create(
            thread_id  => $thread_id,
            session_id => $session_id,
            author     => $author,
            subject    => $subject,
            body       => $body,
        );
    }

    $self->_json_response({ success => JSON::PP::true, draft_id => $draft_id });
}

# 下書き削除
sub api_delete {
    my ($self) = @_;
    my $cgi = $self->{cgi};
    my $csrf_token = $cgi->param('csrf_token') || '';
    unless (LetterBBS::Auth::verify_csrf_token($csrf_token, $self->{session}->id(), $self->{config}->get('csrf_secret'))) {
        return $self->_json_error('セッションが無効です。', 'INVALID_TOKEN');
    }
    my $draft_id   = LetterBBS::Sanitize::to_uint($cgi->param('draft_id'));
    my $session_id = $self->{session}->id();

    my $draft = $self->{draft_m}->find($draft_id);
    unless ($draft && $draft->{session_id} eq $session_id) {
        return $self->_json_error('下書きが見つかりません。', 'NOT_FOUND');
    }

    $self->{draft_m}->delete($draft_id);
    $self->_json_response({ success => JSON::PP::true });
}

# 一括送信
sub api_send {
    my ($self) = @_;
    my $cgi = $self->{cgi};
    my $csrf_token = $cgi->param('csrf_token') || '';
    unless (LetterBBS::Auth::verify_csrf_token($csrf_token, $self->{session}->id(), $self->{config}->get('csrf_secret'))) {
        return $self->_json_error('セッションが無効です。', 'INVALID_TOKEN');
    }
    my $session_id = $self->{session}->id();
    my $draft_ids_str = $cgi->param('draft_ids') || '';
    my $password  = $cgi->param('password') || '';

    my @draft_ids = grep { $_ > 0 } map { int($_) } split(/,/, $draft_ids_str);
    unless (@draft_ids) {
        return $self->_json_error('送信する下書きが指定されていません。', 'INVALID_PARAMS');
    }

    my $pwd_hash = '';
    if ($password ne '') {
        $pwd_hash = LetterBBS::Auth::hash_password($password);
    }

    my $host = $ENV{REMOTE_ADDR} || '';
    my @results;

    eval {
        $self->{db}->begin_transaction();

        for my $draft_id (@draft_ids) {
            my $draft = $self->{draft_m}->find($draft_id);
            next unless $draft && $draft->{session_id} eq $session_id;
            next unless $draft->{body} && $draft->{body} =~ /\S/;

            # スレッドの存在・ロックチェック
            my $thread = $self->{thread_m}->find($draft->{thread_id});
            next unless $thread && !$thread->{is_locked} && $thread->{status} eq 'active';

            my $escaped_body = LetterBBS::Sanitize::html_escape($draft->{body});

            my $post_id = $self->{post_m}->create(
                thread_id => $draft->{thread_id},
                author    => $draft->{author},
                subject   => $draft->{subject},
                body      => $escaped_body,
                password  => $pwd_hash,
                host      => $host,
            );

            $self->{draft_m}->delete($draft_id);

            push @results, {
                draft_id  => $draft_id,
                thread_id => $draft->{thread_id},
                post_id   => $post_id,
            };
        }

        $self->{db}->commit();
    };
    if ($@) {
        eval { $self->{db}->rollback() };
        warn "[LetterBBS] desk send error: $@";
        return $self->_json_error('送信に失敗しました。', 'SERVER_ERROR');
    }

    $self->_json_response({
        success => JSON::PP::true,
        posted  => scalar @results,
        results => \@results,
    });
}

#--- 内部メソッド ---

sub _json_response {
    my ($self, $data) = @_;
    print JSON::PP::encode_json($data);
}

sub _json_error {
    my ($self, $msg, $code) = @_;
    print JSON::PP::encode_json({
        success    => JSON::PP::false,
        error      => $msg,
        error_code => $code || 'UNKNOWN',
    });
}

1;
