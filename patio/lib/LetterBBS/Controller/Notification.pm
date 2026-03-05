package LetterBBS::Controller::Notification;

#============================================================================
# LetterBBS ver2 - 通知APIコントローラー
#============================================================================

use strict;
use warnings;
use utf8;
use JSON::PP;
use LetterBBS::Sanitize;
use LetterBBS::Model::Thread;
use LetterBBS::Model::Post;

sub new {
    my ($class, %ctx) = @_;
    return bless {
        config   => $ctx{config},
        db       => $ctx{db},
        session  => $ctx{session},
        cgi      => $ctx{cgi},
        thread_m => LetterBBS::Model::Thread->new($ctx{db}),
        post_m   => LetterBBS::Model::Post->new($ctx{db}),
    }, $class;
}

# スレッド一覧（通知ポーリング用）
sub thread_list {
    my ($self) = @_;
    my $since = LetterBBS::Sanitize::sanitize_input($self->{cgi}->param('since') || '');

    my $threads = $self->{thread_m}->list_since($since);

    # 軽量化: 必要なフィールドのみ返す
    my @result;
    for my $t (@$threads) {
        push @result, {
            id          => $t->{id},
            subject     => $t->{subject},
            author      => $t->{author},
            post_count  => $t->{post_count},
            last_author => $t->{last_author},
            updated_at  => $t->{updated_at},
            is_locked   => $t->{is_locked} ? JSON::PP::true : JSON::PP::false,
            has_image   => $t->{has_image} ? JSON::PP::true : JSON::PP::false,
        };
    }

    $self->_json_response({
        success     => JSON::PP::true,
        server_time => _now(),
        threads     => \@result,
    });
}

# タイムライン取得
sub timeline {
    my ($self) = @_;
    my $my_name      = LetterBBS::Sanitize::sanitize_input($self->{cgi}->param('my_name') || '');
    my $partner_name = LetterBBS::Sanitize::sanitize_input($self->{cgi}->param('partner_name') || '');

    unless ($my_name && $partner_name) {
        return $self->_json_error('名前が指定されていません。', 'INVALID_PARAMS');
    }

    my $posts = $self->{post_m}->timeline($my_name, $partner_name);

    # 本文のHTMLタグを保持しつつ安全に返す
    my @result;
    for my $p (@$posts) {
        push @result, {
            id             => $p->{id},
            thread_id      => $p->{thread_id},
            seq_no         => $p->{seq_no},
            author         => $p->{author},
            subject        => $p->{subject} || '',
            body           => $p->{body},
            created_at     => $p->{created_at},
            thread_subject => $p->{thread_subject},
            direction      => $p->{direction},
        };
    }

    $self->_json_response({
        success => JSON::PP::true,
        posts   => \@result,
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

sub _now {
    my @t = localtime;
    return sprintf("%04d-%02d-%02d %02d:%02d:%02d",
        $t[5]+1900, $t[4]+1, $t[3], $t[2], $t[1], $t[0]);
}

1;
