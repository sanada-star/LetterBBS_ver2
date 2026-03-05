package LetterBBS::Controller::Board;

#============================================================================
# LetterBBS ver2 - 掲示板一覧コントローラー
#============================================================================

use strict;
use warnings;
use utf8;
use LetterBBS::Sanitize;
use LetterBBS::Model::Thread;
use LetterBBS::Model::Post;

sub new {
    my ($class, %ctx) = @_;
    return bless {
        config   => $ctx{config},
        db       => $ctx{db},
        session  => $ctx{session},
        template => $ctx{template},
        cgi      => $ctx{cgi},
        thread_m => LetterBBS::Model::Thread->new($ctx{db}),
        post_m   => LetterBBS::Model::Post->new($ctx{db}),
    }, $class;
}

# スレッド一覧表示
sub list {
    my ($self) = @_;
    my $page     = LetterBBS::Sanitize::to_uint($self->{cgi}->param('page'), 1);
    my $per_page = $self->{config}->get('pgmax_now') || 50;

    my $threads = $self->{thread_m}->list(
        status   => 'active',
        page     => $page,
        per_page => $per_page,
    );
    my $total = $self->{thread_m}->count_by_status('active');
    my $total_pages = int(($total + $per_page - 1) / $per_page);

    # 各スレッドにアイコン情報を付加
    for my $t (@$threads) {
        $t->{icon} = $self->_thread_icon($t);
        $t->{display_date} = _format_date($t->{updated_at});
        $t->{is_new} = _is_new($t->{updated_at}) ? 1 : 0;
    }

    my $html = $self->{template}->render_with_layout('bbs.html',
        $self->_common_vars(),
        page_title  => 'スレッド一覧',
        threads     => $threads,
        page        => $page,
        total_pages => $total_pages,
        total       => $total,
        pagination  => _pagination($page, $total_pages, ($self->{config}->get('cgi_url') || '') . '?mode=list'),
    );
    $self->_output_html($html);
}

# キーワード検索
sub search {
    my ($self) = @_;
    my $keyword = LetterBBS::Sanitize::sanitize_input($self->{cgi}->param('keyword') || '');
    my $mode    = ($self->{cgi}->param('cond') || '') eq 'OR' ? 'OR' : 'AND';
    my $page    = LetterBBS::Sanitize::to_uint($self->{cgi}->param('page'), 1);

    my $results = [];
    my $searched = 0;

    if ($keyword ne '') {
        $searched = 1;
        if ($self->{db}->fts_available) {
            $results = $self->{post_m}->search_fts(
                keyword  => $keyword,
                mode     => $mode,
                page     => $page,
                per_page => 20,
            );
        } else {
            $results = $self->{post_m}->search_like(
                keyword  => $keyword,
                mode     => $mode,
                page     => $page,
                per_page => 20,
            );
        }
        # 結果にフォーマット情報を付加
        for my $r (@$results) {
            $r->{display_date} = _format_date($r->{created_at});
            $r->{body_excerpt} = LetterBBS::Sanitize::truncate(
                LetterBBS::Sanitize::strip_tags($r->{body}), 100
            );
        }
    }

    my $html = $self->{template}->render_with_layout('find.html',
        $self->_common_vars(),
        page_title   => '検索',
        keyword      => $keyword,
        mode         => $mode,
        mode_and     => ($mode eq 'AND' ? 1 : 0),
        mode_or      => ($mode eq 'OR' ? 1 : 0),
        results      => $results,
        result_count => scalar @$results,
        searched     => $searched,
    );
    $self->_output_html($html);
}

# 過去ログ一覧
sub past {
    my ($self) = @_;
    my $page     = LetterBBS::Sanitize::to_uint($self->{cgi}->param('page'), 1);
    my $per_page = $self->{config}->get('pgmax_past') || 100;

    my $threads = $self->{thread_m}->list(
        status   => 'archived',
        page     => $page,
        per_page => $per_page,
    );
    my $total = $self->{thread_m}->count_by_status('archived');
    my $total_pages = int(($total + $per_page - 1) / $per_page);

    for my $t (@$threads) {
        $t->{icon} = $self->_thread_icon($t);
        $t->{display_date} = _format_date($t->{updated_at});
    }

    my $html = $self->{template}->render_with_layout('past.html',
        $self->_common_vars(),
        page_title  => '過去ログ',
        threads     => $threads,
        page        => $page,
        total_pages => $total_pages,
        total       => $total,
        pagination  => _pagination($page, $total_pages, ($self->{config}->get('cgi_url') || '') . '?mode=past'),
    );
    $self->_output_html($html);
}

#--- 内部メソッド ---

sub _common_vars {
    my ($self) = @_;
    return (
        bbs_title  => $self->{config}->get('bbs_title') || '',
        css_url    => $self->{config}->css_url() || '',
        cgi_url    => $self->{config}->get('cgi_url') || '',
        api_url    => $self->{config}->get('api_url') || '',
        admin_url  => $self->{config}->get('admin_url') || '',
        image_upl  => $self->{config}->get('image_upl') || 0,
    );
}

sub _output_html {
    my ($self, $html) = @_;
    print "Content-Type: text/html; charset=utf-8\n";
    print "X-Content-Type-Options: nosniff\n";
    print "X-Frame-Options: DENY\n";
    print "Referrer-Policy: same-origin\n";
    if (my $cookie = $self->{session}->cookie_header()) {
        # malformed header を防ぐため、Cookie が Set-Cookie: 形式で始まることを保証
        $cookie = "Set-Cookie: " . $cookie unless $cookie =~ /^Set-Cookie:/i;
        print "$cookie\n";
    }
    print "\n";
    binmode STDOUT, ":utf8";
    print $html;
}

sub _thread_icon {
    my ($self, $t) = @_;
    return 'fld_lock' if $t->{is_locked};
    return 'fld_img'  if $t->{has_image};
    return 'fld_new'  if _is_new($t->{updated_at});
    return 'fld_nor';
}

sub _is_new {
    my ($dt) = @_;
    return 0 unless $dt;
    # 24時間以内なら新着
    if ($dt =~ /^(\d{4})-(\d{2})-(\d{2}) (\d{2}):(\d{2}):(\d{2})/) {
        require POSIX;
        my $t = POSIX::mktime($6, $5, $4, $3, $2-1, $1-1900);
        return (time() - $t < 86400) ? 1 : 0;
    }
    return 0;
}

sub _format_date {
    my ($dt) = @_;
    return '' unless $dt;
    if ($dt =~ /^(\d{4})-(\d{2})-(\d{2}) (\d{2}):(\d{2})/) {
        return "$1/$2/$3 $4:$5";
    }
    return $dt;
}

# ページネーションHTML生成
sub _pagination {
    my ($current, $total, $base_url) = @_;
    return '' if $total <= 1;

    my $html = '<div class="pagination">';

    if ($current > 1) {
        $html .= sprintf('<a href="%s&page=%d" class="page-link">&laquo; 前</a>', $base_url, $current - 1);
    }

    my $start = ($current - 3 > 1) ? $current - 3 : 1;
    my $end   = ($current + 3 < $total) ? $current + 3 : $total;

    for my $p ($start .. $end) {
        if ($p == $current) {
            $html .= sprintf('<span class="page-current">%d</span>', $p);
        } else {
            $html .= sprintf('<a href="%s&page=%d" class="page-link">%d</a>', $base_url, $p, $p);
        }
    }

    if ($current < $total) {
        $html .= sprintf('<a href="%s&page=%d" class="page-link">次 &raquo;</a>', $base_url, $current + 1);
    }

    $html .= '</div>';
    return $html;
}

1;
