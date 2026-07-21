use strict;
use warnings;
use utf8;
use Test::More;
use lib 'patio/lib';
use LetterBBS::Auth;
use LetterBBS::Controller::Admin;

binmode STDERR, ':encoding(UTF-8)';
binmode STDOUT, ':encoding(UTF-8)';

{
    package Local::AdminSession;

    sub new { bless { id => 'admin-session' }, shift }
    sub get { return $_[1] eq 'admin_login' ? 'admin' : undef }
    sub id { $_[0]->{id} }
    sub cookie_header { return '' }
}

{
    package Local::AdminCGI;

    sub new { bless { params => $_[1] || {} }, $_[0] }
    sub param {
        my ($self, $name) = @_;
        my $value = $self->{params}{$name};
        return wantarray ? (ref $value eq 'ARRAY' ? @$value : defined $value ? ($value) : ())
                         : (ref $value eq 'ARRAY' ? $value->[0] : $value);
    }
}

{
    package Local::AdminConfig;

    sub new { bless { values => $_[1] }, $_[0] }
    sub get { $_[0]->{values}{$_[1]} }
}

{
    package Local::AdminThreadModel;

    sub new { bless {}, shift }
    sub find {
        return {
            id         => 7,
            subject    => '件名',
            author     => '親',
            status     => 'active',
            post_count => 2,
        };
    }
}

{
    package Local::AdminPostModel;

    sub new {
        my ($class, %args) = @_;
        return bless {
            records => $args{records} || {},
            deleted => [],
        }, $class;
    }
    sub list_by_thread {
        return (
            {
                id         => 10,
                thread_id  => 7,
                seq_no     => 0,
                author     => '親',
                subject    => '親記事',
                body       => '<b>親本文</b>',
                host       => 'parent.example',
                created_at => '2026-07-20 10:11:12',
                is_deleted => 0,
            },
            [
                {
                    id         => 11,
                    thread_id  => 7,
                    seq_no     => 1,
                    author     => '返信者',
                    subject    => '返信',
                    body       => '<p>' . ('あ' x 105) . '</p>',
                    host       => 'reply.example',
                    created_at => '2026-07-20 11:12:13',
                    is_deleted => 0,
                },
                {
                    id         => 12,
                    thread_id  => 7,
                    seq_no     => 2,
                    author     => '削除者',
                    subject    => '削除済み返信',
                    body       => '<i>削除済み本文</i>',
                    host       => 'deleted.example',
                    created_at => '2026-07-20 12:13:14',
                    is_deleted => 1,
                },
            ],
        );
    }
    sub find { $_[0]->{records}{$_[1]} }
    sub soft_delete {
        my ($self, @args) = @_;
        push @{$self->{deleted}}, \@args;
    }
}

{
    package Local::AdminTemplate;

    sub new { bless {}, shift }
    sub render {
        my ($self, $file, @vars) = @_;
        $self->{file} = $file;
        $self->{vars} = { @vars };
        return 'rendered';
    }
}

sub make_controller {
    my (%args) = @_;
    my $template = $args{template} || Local::AdminTemplate->new;
    return bless {
        session  => Local::AdminSession->new,
        cgi      => $args{cgi} || Local::AdminCGI->new({ id => 7 }),
        config   => Local::AdminConfig->new({
            admin_url  => '/admin.cgi',
            bbs_title  => '掲示板',
            cgi_url    => '/bbs.cgi',
            csrf_secret => 'test-secret',
            upl_dir    => '/uploads',
        }),
        thread_m => $args{thread_m} || Local::AdminThreadModel->new,
        post_m   => $args{post_m} || Local::AdminPostModel->new,
        template => $template,
    }, 'LetterBBS::Controller::Admin';
}

subtest 'thread_detail passes flattened thread and post values to template' => sub {
    my $template = Local::AdminTemplate->new;
    my $controller = make_controller(template => $template);
    my $output = '';
    open my $stdout, '>:encoding(UTF-8)', \$output or die $!;
    {
        local *STDOUT = $stdout;
        $controller->thread_detail();
    }
    close $stdout or die $!;

    is($template->{file}, 'admin/thread_detail.html', 'renders thread detail template');
    my $vars = $template->{vars};
    is($vars->{thread_id}, 7, 'passes thread id');
    is($vars->{thread_subject}, '件名', 'passes thread subject');
    is($vars->{thread_author}, '親', 'passes thread author');
    is($vars->{status_label}, '公開中', 'passes localized status label');
    is($vars->{post_count}, 2, 'passes post count');
    is(scalar @{$vars->{posts} || []}, 3, 'combines parent and replies');

    my ($parent, $active, $deleted) = @{$vars->{posts} || []};
    is($parent->{display_date}, '2026/07/20 10:11', 'formats parent date');
    is($parent->{body_excerpt}, '親本文', 'strips parent body tags');
    is($parent->{can_delete}, 0, 'parent cannot be deleted');
    is($active->{display_date}, '2026/07/20 11:12', 'formats reply date');
    unlike($active->{body_excerpt}, qr/[<>]/, 'strips reply body tags');
    is($active->{body_excerpt}, ('あ' x 100) . '...', 'truncates reply excerpt at 100 characters');
    is($active->{can_delete}, 1, 'active reply can be deleted');
    is($deleted->{body_excerpt}, '削除済み本文', 'keeps deleted reply visible');
    is($deleted->{can_delete}, 0, 'deleted reply cannot be deleted');
    like($output, qr/Content-Type: text\/html/, 'outputs rendered response');
};

subtest 'delete_posts only soft-deletes active replies belonging to the thread' => sub {
    my $post_m = Local::AdminPostModel->new(records => {
        10 => { id => 10, thread_id => 7, seq_no => 0, is_deleted => 0 },
        11 => { id => 11, thread_id => 7, seq_no => 1, is_deleted => 0 },
        12 => { id => 12, thread_id => 7, seq_no => 2, is_deleted => 1 },
        21 => { id => 21, thread_id => 8, seq_no => 1, is_deleted => 0 },
    });
    my $csrf_token = LetterBBS::Auth::generate_csrf_token('admin-session', 'test-secret');
    my $cgi = Local::AdminCGI->new({
        exec       => 'delete_posts',
        thread_id  => 7,
        post_ids   => [11, 10, 12, 21],
        csrf_token => $csrf_token,
    });
    my $controller = make_controller(cgi => $cgi, post_m => $post_m);
    my $output = '';
    open my $stdout, '>:encoding(UTF-8)', \$output or die $!;
    {
        local *STDOUT = $stdout;
        $controller->thread_exec();
    }
    close $stdout or die $!;

    is_deeply(
        $post_m->{deleted},
        [[11, '/uploads']],
        'passes upload directory and deletes only the same-thread active reply',
    );
    like(
        $output,
        qr{^Status: 302 Found\nLocation: /admin\.cgi\?action=thread_detail&id=7\n}m,
        'redirects back to the thread detail page',
    );
};

subtest 'thread detail template only shows delete checkbox for deletable posts' => sub {
    open my $fh, '<:encoding(UTF-8)', 'patio/tmpl/admin/thread_detail.html' or die $!;
    local $/;
    my $template = <$fh>;
    close $fh or die $!;

    like(
        $template,
        qr{<!-- if:can_delete -->\s*<input type="checkbox" name="post_ids" value="<!-- var:id -->">\s*<!-- /if:can_delete -->},
        'guards the post delete checkbox with can_delete',
    );
};

subtest 'admin thread status labels cover known and unknown values' => sub {
    is(LetterBBS::Controller::Admin::_admin_thread_status_label('active'), '公開中', 'labels active');
    is(LetterBBS::Controller::Admin::_admin_thread_status_label('archived'), '過去ログ', 'labels archived');
    is(LetterBBS::Controller::Admin::_admin_thread_status_label('deleted'), '削除済み', 'labels deleted');
    is(LetterBBS::Controller::Admin::_admin_thread_status_label('custom'), 'custom', 'preserves unknown status');
};

done_testing;
