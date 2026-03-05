package LetterBBS::Template;

#============================================================================
# LetterBBS ver2 - テンプレートエンジン
# 構文:
#   <!-- var:name -->              変数置換（HTMLエスケープ済み）
#   <!-- raw:name -->              変数置換（エスケープなし）
#   <!-- loop:items -->...<!-- /loop:items -->  ループ
#   <!-- if:flag -->...<!-- /if:flag -->        条件（真なら表示）
#   <!-- unless:flag -->...<!-- /unless:flag --> 条件（偽なら表示）
#   <!-- else -->                  else分岐
#   <!-- include:file.html -->     部分テンプレート読込
#============================================================================

use strict;
use warnings;
use utf8;
use File::Spec;
use LetterBBS::Sanitize;

sub new {
    my ($class, $tmpl_dir) = @_;
    my $self = bless {
        tmpl_dir => $tmpl_dir || './tmpl',
        cache    => {},
    }, $class;
    return $self;
}

# テンプレートを描画して文字列を返す
sub render {
    my ($self, $file, %vars) = @_;
    my $tmpl = $self->_load($file);
    return $self->_process($tmpl, \%vars);
}

# layout.html でラップして描画
sub render_with_layout {
    my ($self, $file, %vars) = @_;
    my $content = $self->render($file, %vars);
    $vars{content} = $content;
    return $self->render('layout.html', %vars);
}

# テンプレートファイル読み込み（キャッシュ付き）
sub _load {
    my ($self, $file) = @_;
    return $self->{cache}{$file} if exists $self->{cache}{$file};

    my $path = File::Spec->catfile($self->{tmpl_dir}, $file);
    open my $fh, '<:utf8', $path or die "テンプレート読み込みエラー: $path: $!";
    my $content = do { local $/; <$fh> };
    close $fh;

    $self->{cache}{$file} = $content;
    return $content;
}

# テンプレート処理メイン
sub _process {
    my ($self, $tmpl, $vars) = @_;

    # include 処理（再帰的）
    $tmpl =~ s/<!-- include:(\S+?) -->/
        my $inc = $self->_load($1);
        $self->_process($inc, $vars);
    /ge;

    # loop 処理
    $tmpl =~ s/<!-- loop:(\w+) -->(.*?)<!-- \/loop:\1 -->/
        $self->_process_loop($1, $2, $vars);
    /ges;

    # if/unless/else 処理
    $tmpl = $self->_process_conditions($tmpl, $vars);

    # 変数置換（エスケープなし）
    $tmpl =~ s/<!-- raw:(\w+) -->/$self->_get_var($vars, $1, 0)/ge;

    # 変数置換（HTMLエスケープ）
    $tmpl =~ s/<!-- var:(\w+) -->/$self->_get_var($vars, $1, 1)/ge;

    return $tmpl;
}

# ループ処理
sub _process_loop {
    my ($self, $name, $body, $vars) = @_;
    my $items = $vars->{$name};
    return '' unless ref $items eq 'ARRAY';

    my $output = '';
    my $total = scalar @$items;

    for my $i (0 .. $#$items) {
        my $item = $items->[$i];
        # ループ変数をマージ
        my %loop_vars = (
            %$vars,
            (ref $item eq 'HASH' ? %$item : ()),
            _index => $i,
            _count => $i + 1,
            _first => ($i == 0 ? 1 : 0),
            _last  => ($i == $total - 1 ? 1 : 0),
            _odd   => ($i % 2 == 0 ? 1 : 0),
        );
        $output .= $self->_process($body, \%loop_vars);
    }

    return $output;
}

# 条件処理 (if / unless / else)
sub _process_conditions {
    my ($self, $tmpl, $vars) = @_;

    # if ... else ... /if
    $tmpl =~ s/<!-- if:(\w+) -->(.*?)(?:<!-- else -->(.*?))?<!-- \/if:\1 -->/
        my $flag = $self->_get_var($vars, $1, 0);
        ($flag && $flag ne '0' && $flag ne '') ? $self->_process($2 || '', $vars) : $self->_process($3 || '', $vars);
    /ges;

    # unless ... else ... /unless
    $tmpl =~ s/<!-- unless:(\w+) -->(.*?)(?:<!-- else -->(.*?))?<!-- \/unless:\1 -->/
        my $flag = $self->_get_var($vars, $1, 0);
        (!$flag || $flag eq '0' || $flag eq '') ? $self->_process($2 || '', $vars) : $self->_process($3 || '', $vars);
    /ges;

    return $tmpl;
}

# 変数取得
sub _get_var {
    my ($self, $vars, $name, $escape) = @_;
    my $val = exists $vars->{$name} ? $vars->{$name} : '';
    $val = '' unless defined $val;
    return $escape ? LetterBBS::Sanitize::html_escape($val) : $val;
}

1;
