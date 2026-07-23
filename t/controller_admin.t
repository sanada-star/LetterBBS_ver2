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
                         : (ref $value eq 'ARRAY' ? $value->[-1] : $value);
    }
}

{
    package Local::AdminConfig;

    sub new { bless { values => $_[1] }, $_[0] }
    sub get { $_[0]->{values}{$_[1]} }
}

{
    package Local::AdminThreadModel;

    sub new {
        my ($class, %args) = @_;
        return bless {
            records       => $args{records} || {
                7 => {
                    id         => 7,
                    subject    => '件名',
                    author     => '親',
                    status     => 'active',
                    post_count => 2,
                    is_locked  => 0,
                },
                8 => {
                    id         => 8,
                    subject    => '件名2',
                    author     => '親2',
                    status     => 'active',
                    post_count => 0,
                    is_locked  => 0,
                },
            },
            destroy_calls => [],
            find_calls    => [],
            update_calls  => [],
            counts        => $args{counts} || { active => 3, archived => 2 },
        }, $class;
    }
    sub list {
        return [{
            id         => 7,
            subject    => '件名',
            author     => '親',
            status     => 'active',
            post_count => 2,
            updated_at => '2026-07-20 12:13:14',
        }];
    }
    sub count_by_status { $_[0]->{counts}{$_[1]} || 0 }
    sub find {
        my ($self, $id) = @_;
        push @{$self->{find_calls}}, $id;
        return $self->{records}{$id};
    }
    sub destroy {
        my ($self, @args) = @_;
        push @{$self->{destroy_calls}}, \@args;
    }
    sub update {
        my ($self, @args) = @_;
        push @{$self->{update_calls}}, \@args;
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
    sub count_all { 12 }
    sub count_images { 3 }
}

{
    package Local::AdminUserModel;
    sub new {
        my ($class, %args) = @_;
        return bless { users => $args{users} || [] }, $class;
    }
    sub count { 4 }
    sub list { $_[0]->{users} }
}

{
    package Local::AdminSettingModel;
    sub new { bless { values => $_[1] || {} }, $_[0] }
    sub get_all { return { %{$_[0]->{values}} } }
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
            db_file    => '/missing/letterbbs.db',
            upl_dir    => '/uploads',
        }),
        thread_m => $args{thread_m} || Local::AdminThreadModel->new,
        post_m   => $args{post_m} || Local::AdminPostModel->new,
        user_m   => $args{user_m} || Local::AdminUserModel->new,
        setting_m => $args{setting_m} || Local::AdminSettingModel->new,
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

subtest 'thread list renders a localized status label' => sub {
    my $template = Local::AdminTemplate->new;
    my $controller = make_controller(template => $template);
    my $output = '';
    open my $stdout, '>:encoding(UTF-8)', \$output or die $!;
    {
        local *STDOUT = $stdout;
        $controller->thread_list();
    }
    close $stdout or die $!;

    is($template->{file}, 'admin/threads.html', 'renders thread list template');
    my $threads = $template->{vars}{threads};
    is($threads->[0]{status_label}, '公開中', 'passes localized thread status');
    is($threads->[0]{post_count}, 2, 'keeps reply count');
    is($threads->[0]{display_date}, '2026/07/20 12:13', 'formats activity date');
};

subtest 'thread list exposes active and archived navigation with status-aware pagination' => sub {
    my $template = Local::AdminTemplate->new;
    my $controller = make_controller(
        template => $template,
        cgi => Local::AdminCGI->new({ status => 'archived', page => 2 }),
        thread_m => Local::AdminThreadModel->new(
            counts => { active => 3, archived => 120 },
        ),
    );
    my $output = '';
    open my $stdout, '>:encoding(UTF-8)', \$output or die $!;
    {
        local *STDOUT = $stdout;
        $controller->thread_list();
    }
    close $stdout or die $!;

    my $vars = $template->{vars};
    is($vars->{status}, 'archived', 'keeps the selected archive status');
    is($vars->{is_active}, 0, 'marks active list as inactive');
    is($vars->{is_archived}, 1, 'marks archived list as selected');
    like(
        $vars->{pagination},
        qr{\?action=threads&amp;status=archived&amp;page=},
        'keeps archived status in pagination links',
    );

    open my $fh, '<:encoding(UTF-8)', 'patio/tmpl/admin/threads.html' or die $!;
    local $/;
    my $template_source = <$fh>;
    close $fh or die $!;
    like($template_source, qr{status=active}, 'template links to active threads');
    like($template_source, qr{status=archived}, 'template links to archived threads');
    like($template_source, qr{name="status" value="<!-- var:status -->"},
        'bulk form submits the current status');
    like($template_source, qr{name="exec" value="restore"},
        'archived list provides a restore action');
};

subtest 'member list provides rank, status, and registration date labels' => sub {
    my $template = Local::AdminTemplate->new;
    my $user_m = Local::AdminUserModel->new(users => [
        { id => 1, rank => 2, is_active => 1, created_at => '2026-07-23 10:11:12' },
        { id => 2, rank => 1, is_active => 0, created_at => '2026-07-22 09:08:07' },
        { id => 3, rank => 9, is_active => 7 },
        { id => 4 },
    ]);
    my $controller = make_controller(template => $template, user_m => $user_m);
    my $output = '';
    open my $stdout, '>:encoding(UTF-8)', \$output or die $!;
    {
        local *STDOUT = $stdout;
        $controller->member_list();
    }
    close $stdout or die $!;

    my $users = $template->{vars}{users};
    is_deeply(
        [map { [$_->{rank_label}, $_->{status_label}, $_->{display_date}] } @$users],
        [
            ['書込可', '有効', '2026/07/23 10:11'],
            ['閲覧のみ', '無効', '2026/07/22 09:08'],
            ['9', '7', ''],
            ['未設定', '未設定', ''],
        ],
        'formats known values and preserves explicit unknown values',
    );
};

subtest 'bulk thread actions normalize and process every selected id once' => sub {
    my $csrf_token = LetterBBS::Auth::generate_csrf_token('admin-session', 'test-secret');

    for my $case (
        ['delete',      'destroy_calls', [[7, '/uploads'], [8, '/uploads']]],
        ['toggle_lock', 'update_calls',  [[7, is_locked => 1], [8, is_locked => 1]]],
        ['archive',     'update_calls',  [[7, status => 'archived'], [8, status => 'archived']]],
        ['restore',     'update_calls',  [[7, status => 'active'], [8, status => 'active']]],
    ) {
        my ($action, $record_key, $expected) = @$case;
        my $thread_m = Local::AdminThreadModel->new;
        my $cgi = Local::AdminCGI->new({
            exec       => $action,
            ids        => [7, 8, 8, 'bad', 0],
            status     => 'archived',
            csrf_token => $csrf_token,
        });
        my $controller = make_controller(cgi => $cgi, thread_m => $thread_m);
        my $output = '';
        open my $stdout, '>:encoding(UTF-8)', \$output or die $!;
        {
            local *STDOUT = $stdout;
            $controller->thread_exec();
        }
        close $stdout or die $!;

        is_deeply($thread_m->{$record_key}, $expected,
            "$action processes normalized unique IDs");
        like(
            $output,
            qr{Location: /admin\.cgi\?action=threads&status=archived},
            "$action preserves the selected list status",
        );
    }

    my $thread_m = Local::AdminThreadModel->new;
    my $controller = make_controller(
        thread_m => $thread_m,
        cgi => Local::AdminCGI->new({
            exec       => 'delete',
            thread_id  => 7,
            csrf_token => $csrf_token,
        }),
    );
    my $output = '';
    open my $stdout, '>:encoding(UTF-8)', \$output or die $!;
    {
        local *STDOUT = $stdout;
        $controller->thread_exec();
    }
    close $stdout or die $!;
    is_deeply($thread_m->{destroy_calls}, [[7, '/uploads']],
        'single thread_id remains supported');
};

subtest 'size check renders capacity and all requested record counts' => sub {
    my $template = Local::AdminTemplate->new;
    my $controller = make_controller(template => $template);
    my $output = '';
    open my $stdout, '>:encoding(UTF-8)', \$output or die $!;
    {
        local *STDOUT = $stdout;
        $controller->size_check();
    }
    close $stdout or die $!;

    my $vars = $template->{vars};
    is($vars->{active_threads}, 3, 'counts active threads');
    is($vars->{archived_threads}, 2, 'counts archived threads');
    is($vars->{total_posts}, 12, 'counts all post records');
    is($vars->{total_users}, 4, 'counts users');
    is($vars->{total_images}, 3, 'counts image records');
};

subtest 'settings renders the current CAPTCHA selection' => sub {
    my $template = Local::AdminTemplate->new;
    my $controller = make_controller(
        template => $template,
        setting_m => Local::AdminSettingModel->new({ use_captcha => '1' }),
    );
    my $output = '';
    open my $stdout, '>:encoding(UTF-8)', \$output or die $!;
    {
        local *STDOUT = $stdout;
        $controller->settings();
    }
    close $stdout or die $!;

    is($template->{vars}{use_captcha_on}, 1, 'CAPTCHA enabled option is selected');
    is($template->{vars}{use_captcha_off}, 0, 'CAPTCHA disabled option is not selected');
};

subtest 'settings template exposes the CAPTCHA setting field' => sub {
    open my $fh, '<:encoding(UTF-8)', 'patio/tmpl/admin/settings.html' or die $!;
    local $/;
    my $template = <$fh>;
    close $fh or die $!;

    like($template, qr{<select name="use_captcha">}, 'CAPTCHA select is present');
    like($template, qr{if:use_captcha_on}, 'enabled selection flag is used');
    like($template, qr{if:use_captcha_off}, 'disabled selection flag is used');
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
