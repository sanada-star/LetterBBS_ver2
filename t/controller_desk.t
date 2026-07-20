use strict;
use warnings;
use utf8;
use Test::More;
use JSON::PP;
use lib 'patio/lib';
use LetterBBS::Auth;
use LetterBBS::Controller::Desk;

binmode STDERR, ':encoding(UTF-8)';
binmode STDOUT, ':encoding(UTF-8)';

{
    package Local::DeskSession;

    sub new { bless { id => $_[1] || 'desk-session' }, $_[0] }
    sub id { $_[0]->{id} }
    sub cookie_header { return '' }
}

{
    package Local::DeskCGI;

    sub new { bless { params => $_[1] || {} }, $_[0] }
    sub param { $_[0]->{params}{$_[1]} }
}

{
    package Local::DeskConfig;

    sub new { bless { values => $_[1] }, $_[0] }
    sub get { $_[0]->{values}{$_[1]} }
    sub css_url { $_[0]->{values}{css_url} }
}

{
    package Local::DeskDraftModel;

    sub new {
        my ($class, $drafts) = @_;
        return bless { drafts => $drafts || [], listed_sessions => [] }, $class;
    }
    sub list_by_session {
        my ($self, $session_id) = @_;
        push @{$self->{listed_sessions}}, $session_id;
        return $self->{drafts};
    }
    sub find { $_[0]->{by_id}{$_[1]} }
    sub delete { push @{$_[0]->{deleted}}, $_[1] }
}

{
    package Local::DeskDB;

    sub new { bless { calls => [] }, shift }
    sub begin_transaction { push @{$_[0]->{calls}}, 'begin' }
    sub commit { push @{$_[0]->{calls}}, 'commit' }
    sub rollback { push @{$_[0]->{calls}}, 'rollback' }
}

{
    package Local::DeskThreadModel;

    sub new { bless {}, shift }
    sub find {
        return {
            id        => $_[1],
            is_locked => 0,
            status    => 'active',
        };
    }
}

{
    package Local::DeskPostModel;

    sub new { bless { created => [] }, shift }
    sub create {
        my ($self, %args) = @_;
        push @{$self->{created}}, \%args;
        return 100 + @{$self->{created}};
    }
}

{
    package Local::DeskTemplate;

    sub new { bless {}, shift }
    sub render_with_layout {
        my ($self, $file, @vars) = @_;
        $self->{file} = $file;
        $self->{vars} = { @vars };
        return 'rendered desk';
    }
}

sub make_controller {
    my (%args) = @_;
    my $template = $args{template} || Local::DeskTemplate->new;
    my $draft_m = $args{draft_m} || Local::DeskDraftModel->new;
    return bless {
        session  => $args{session} || Local::DeskSession->new,
        config   => $args{config} || Local::DeskConfig->new({
            bbs_title   => '掲示板',
            css_url     => '/style.css',
            cgi_url     => '/bbs.cgi',
            api_url     => '/api.cgi',
            admin_url   => '/admin.cgi',
            csrf_secret => 'test-secret',
        }),
        template => $template,
        draft_m  => $draft_m,
        cgi      => $args{cgi},
        db       => $args{db},
        thread_m => $args{thread_m},
        post_m   => $args{post_m},
    }, 'LetterBBS::Controller::Desk';
}

subtest 'show passes saved session drafts to the desk template' => sub {
    my $drafts = [
        {
            id         => 41,
            thread_id  => 7,
            session_id => 'desk-session',
            author     => '一人目',
            subject    => '最初の件名',
            body       => '最初の本文',
            updated_at => '2026-07-20 12:34:56',
        },
        {
            id         => 42,
            thread_id  => 8,
            session_id => 'desk-session',
            author     => '二人目',
            subject    => '次の件名',
            body       => '次の本文',
            updated_at => '2026-07-20 13:45:01',
        },
    ];
    my $draft_m = Local::DeskDraftModel->new($drafts);
    my $template = Local::DeskTemplate->new;
    my $controller = make_controller(draft_m => $draft_m, template => $template);

    my $output = '';
    open my $stdout, '>:encoding(UTF-8)', \$output or die $!;
    {
        local *STDOUT = $stdout;
        $controller->show();
    }
    close $stdout or die $!;

    is_deeply($draft_m->{listed_sessions}, ['desk-session'], 'loads drafts for the current session');
    is($template->{file}, 'desk.html', 'renders the desk template');
    is($template->{vars}{draft_count}, 2, 'passes the draft count');
    is_deeply(
        $template->{vars}{drafts},
        [
            {
                id            => 41,
                thread_id     => 7,
                session_id    => 'desk-session',
                author        => '一人目',
                subject       => '最初の件名',
                body          => '最初の本文',
                updated_at    => '2026-07-20 12:34:56',
                draft_id      => 41,
                draft_subject => '最初の件名',
                draft_body    => '最初の本文',
                display_date  => '2026/07/20 12:34',
            },
            {
                id            => 42,
                thread_id     => 8,
                session_id    => 'desk-session',
                author        => '二人目',
                subject       => '次の件名',
                body          => '次の本文',
                updated_at    => '2026-07-20 13:45:01',
                draft_id      => 42,
                draft_subject => '次の件名',
                draft_body    => '次の本文',
                display_date  => '2026/07/20 13:45',
            },
        ],
        'preserves draft fields and adds desk display fields',
    );
    like($output, qr/Content-Type: text\/html/, 'outputs the rendered response');
};

subtest 'api_send shares one secure password hash across a valid batch' => sub {
    my $config = Local::DeskConfig->new({ csrf_secret => 'test-secret' });
    my $csrf_token = LetterBBS::Auth::generate_csrf_token('desk-session', 'test-secret');
    my $cgi = Local::DeskCGI->new({
        csrf_token => $csrf_token,
        draft_ids  => '51,52',
        password   => 'edit-pass',
    });
    my $draft_m = Local::DeskDraftModel->new;
    $draft_m->{by_id} = {
        51 => {
            id         => 51,
            thread_id  => 7,
            session_id => 'desk-session',
            author     => '一人目',
            subject    => '最初の件名',
            body       => '最初の本文',
        },
        52 => {
            id         => 52,
            thread_id  => 8,
            session_id => 'desk-session',
            author     => '二人目',
            subject    => '次の件名',
            body       => '次の本文',
        },
    };
    $draft_m->{deleted} = [];
    my $db = Local::DeskDB->new;
    my $post_m = Local::DeskPostModel->new;
    my $controller = make_controller(
        config   => $config,
        cgi      => $cgi,
        db       => $db,
        draft_m  => $draft_m,
        thread_m => Local::DeskThreadModel->new,
        post_m   => $post_m,
    );

    my $output = '';
    open my $stdout, '>:encoding(UTF-8)', \$output or die $!;
    {
        local *STDOUT = $stdout;
        $controller->api_send();
    }
    close $stdout or die $!;

    is(scalar @{$post_m->{created}}, 2, 'creates both posts');
    my ($first_hash, $second_hash) = map { $_->{password} } @{$post_m->{created}};
    is($first_hash, $second_hash, 'uses the same password hash for the batch');
    isnt($first_hash, 'edit-pass', 'does not store the plaintext password');
    ok(LetterBBS::Auth::verify_password('edit-pass', $first_hash), 'first post hash verifies');
    ok(LetterBBS::Auth::verify_password('edit-pass', $second_hash), 'second post hash verifies');
    is_deeply($draft_m->{deleted}, [51, 52], 'deletes both posted drafts');
    is_deeply($db->{calls}, ['begin', 'commit'], 'commits the batch transaction');

    my $response = JSON::PP::decode_json($output);
    is($response->{posted}, 2, 'reports two posted drafts');
    ok($response->{success}, 'reports a successful response');
};

done_testing;
