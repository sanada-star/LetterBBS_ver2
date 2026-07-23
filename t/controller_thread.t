use strict;
use warnings;
use utf8;
use Test::More;
use Encode qw(decode_utf8);
use lib 'patio/lib';
use LetterBBS::Auth;
use LetterBBS::Controller::Thread;

{
    package Local::ThreadSession;
    sub new { bless {}, shift }
    sub id { 'thread-session' }
    sub get { undef }
    sub cookie_header { '' }
}

{
    package Local::ThreadCGI;
    sub new { bless { params => $_[1] }, $_[0] }
    sub param {
        my ($self, $name) = @_;
        my $value = $self->{params}{$name};
        return wantarray ? (defined $value ? ($value) : ()) : $value;
    }
}

{
    package Local::ThreadConfig;
    sub new { bless { values => $_[1] }, $_[0] }
    sub get { $_[0]->{values}{$_[1]} }
    sub css_url { '/style.css' }
}

{
    package Local::ThreadDB;
    sub new { bless { began => 0, committed => 0, rolled_back => 0 }, shift }
    sub begin_transaction { $_[0]->{began}++ }
    sub commit { $_[0]->{committed}++ }
    sub rollback { $_[0]->{rolled_back}++ }
}

{
    package Local::ThreadModel;
    sub new { bless {}, shift }
    sub create { 7 }
    sub update { 1 }
    sub archive_old { 1 }
    sub purge_old { 1 }
}

{
    package Local::ThreadPostModel;
    sub new { bless { images => [] }, shift }
    sub check_flood { 1 }
    sub create { 10 }
    sub add_image {
        my ($self, %image) = @_;
        push @{$self->{images}}, \%image;
        return 1;
    }
}

{
    package Local::ThreadTemplate;
    sub new { bless {}, shift }
    sub render_with_layout {
        my ($self, $file, @vars) = @_;
        my %vars = @vars;
        return '<html><body>ERROR:' . ($vars{error_message} || '') . '</body></html>';
    }
}

sub make_controller {
    my $csrf = LetterBBS::Auth::generate_csrf_token('thread-session', 'test-secret');
    my $db = Local::ThreadDB->new;
    my $controller = bless {
        config => Local::ThreadConfig->new({
            csrf_secret    => 'test-secret',
            use_captcha    => 0,
            wait           => 15,
            image_upl      => 1,
            max_image_count => 2,
            max_upload_size => 5_120_000,
            thumbnail      => 1,
            thumb_w        => 200,
            thumb_h        => 200,
            upl_dir        => '/uploads',
            upl_url        => '/uploads',
            i_max          => 1000,
            p_max          => 1000,
            cgi_url        => '/patio.cgi',
            bbs_title      => '掲示板',
            api_url        => '/api.cgi',
            admin_url      => '/admin.cgi',
        }),
        db       => $db,
        session  => Local::ThreadSession->new,
        cgi      => Local::ThreadCGI->new({
            csrf_token => $csrf,
            thread_id  => 0,
            name       => '投稿者',
            email      => '',
            subject    => '件名',
            body       => '本文',
            pwd        => 'pass1234',
            url        => '',
        }),
        template => Local::ThreadTemplate->new,
        thread_m => Local::ThreadModel->new,
        post_m   => Local::ThreadPostModel->new,
    }, 'LetterBBS::Controller::Thread';
    return ($controller, $db);
}

sub capture_post {
    my ($controller) = @_;
    my $output = '';
    open my $stdout, '>', \$output or die $!;
    {
        local *STDOUT = $stdout;
        $controller->post();
    }
    close $stdout or die $!;
    return decode_utf8($output);
}

subtest 'invalid upload emits one HTML response and no redirect headers in the body' => sub {
    my ($controller, $db) = make_controller();
    my @results = ({ error => '許可されていないファイル形式です。' });
    no warnings 'redefine';
    local *LetterBBS::Upload::process = sub { shift @results };

    my $output = capture_post($controller);
    is(() = $output =~ /Content-Type:/g, 1, 'only one response header block is emitted');
    unlike($output, qr/Status:\s*302|Location:|Set-Cookie:/, 'redirect and cookie headers are not exposed in HTML');
    like($output, qr/許可されていないファイル形式/, 'safe validation message is shown');
    is($db->{rolled_back}, 1, 'database transaction is rolled back');
    is($db->{committed}, 0, 'failed transaction is not committed');
};

subtest 'a later upload failure removes files saved earlier in the same request' => sub {
    my ($controller, $db) = make_controller();
    my @results = (
        {
            filename => '7_1_saved.png', original => 'saved.png', mime_type => 'image/png',
            file_size => 24, width => 1, height => 1,
        },
        { error => '許可されていないファイル形式です。' },
    );
    my @deleted;
    no warnings 'redefine';
    local *LetterBBS::Upload::process = sub { shift @results };
    local *LetterBBS::Upload::make_thumbnail = sub { 1 };
    local *LetterBBS::Upload::delete_file = sub { push @deleted, $_[1] };

    my $output = capture_post($controller);
    is_deeply(\@deleted, ['7_1_saved.png'], 'saved image and its thumbnail are cleaned through delete_file');
    unlike($output, qr/Status:\s*302|Location:/, 'failed upload does not continue to redirect');
    is($db->{rolled_back}, 1, 'database transaction is rolled back once');
};

subtest 'successful upload keeps files and returns the normal redirect' => sub {
    my ($controller, $db) = make_controller();
    my @results = (
        {
            filename => '7_1_kept.png', original => 'kept.png', mime_type => 'image/png',
            file_size => 24, width => 1, height => 1,
        },
        undef,
    );
    my @deleted;
    no warnings 'redefine';
    local *LetterBBS::Upload::process = sub { shift @results };
    local *LetterBBS::Upload::make_thumbnail = sub { 1 };
    local *LetterBBS::Upload::delete_file = sub { push @deleted, $_[1] };

    my $output = capture_post($controller);
    is_deeply(\@deleted, [], 'successful upload is not cleaned up');
    like($output, qr/Status:\s*302 Found/, 'normal redirect is returned');
    like($output, qr{Location:\s*/patio\.cgi\?mode=read&id=7}, 'redirect points to the new thread');
    is($db->{committed}, 1, 'successful transaction is committed');
    is($db->{rolled_back}, 0, 'successful transaction is not rolled back');
};

done_testing;
