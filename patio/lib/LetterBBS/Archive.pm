package LetterBBS::Archive;

# メモリーボックス: スレッドをHTMLアーカイブとして生成する
# Archive::Zip が利用可能ならZIP形式、なければ単一HTMLでダウンロード提供

use strict;
use warnings;
use utf8;
use Encode qw(encode_utf8);

# コンストラクタ
sub new {
    my ($class, $config, $db) = @_;

    # Archive::Zip が利用可能かチェック
    my $has_zip = eval { require Archive::Zip; 1 };

    return bless {
        config  => $config,
        db      => $db,
        has_zip => $has_zip,
    }, $class;
}

# スレッドのアーカイブを生成
# 引数:
#   $thread_id - スレッドID
#   %opts:
#     include_timeline => 1  タイムラインモードで相手とのやり取りを抽出
#     partner_name => "..."  タイムラインの相手名
#     my_name => "..."       タイムラインの自分名
# 返却: { content_type => "...", filename => "...", data => バイナリデータ }
sub generate {
    my ($self, $thread_id, %opts) = @_;

    my $dbh = $self->{db}->dbh;
    my $config = $self->{config};

    # スレッド情報取得
    my $thread = $dbh->selectrow_hashref(
        "SELECT * FROM threads WHERE id = ?", undef, $thread_id
    );
    return undef unless $thread;

    # 投稿取得
    my $posts;
    if ($opts{include_timeline} && $opts{partner_name} && $opts{my_name}) {
        # タイムラインモード
        $posts = $dbh->selectall_arrayref(
            "SELECT p.*, t.subject AS thread_subject, t.author AS thread_author,
                    CASE WHEN p.author = ? THEN 'sent' ELSE 'received' END AS direction
             FROM posts p
             JOIN threads t ON t.id = p.thread_id
             WHERE t.status != 'deleted' AND p.is_deleted = 0
               AND (
                 (t.author = ? AND (p.author = ? OR p.seq_no = 0))
                 OR
                 (t.author = ? AND (p.author = ? OR p.seq_no = 0))
               )
             ORDER BY p.created_at ASC",
            { Slice => {} },
            $opts{my_name},
            $opts{my_name}, $opts{partner_name},
            $opts{partner_name}, $opts{my_name}
        );
    } else {
        # 通常モード
        $posts = $dbh->selectall_arrayref(
            "SELECT * FROM posts WHERE thread_id = ? AND is_deleted = 0 ORDER BY seq_no ASC",
            { Slice => {} },
            $thread_id
        );
    }

    # HTML生成
    my $html = $self->_build_html($thread, $posts, %opts);

    if ($self->{has_zip}) {
        return $self->_build_zip($thread, $html);
    } else {
        return $self->_build_single_html($thread, $html);
    }
}

# HTML本体を生成
sub _build_html {
    my ($self, $thread, $posts, %opts) = @_;

    my $title = _escape($thread->{subject});
    my $is_timeline = $opts{include_timeline} ? 1 : 0;

    my $html = <<"HTML";
<!DOCTYPE html>
<html lang="ja">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>${title} - LetterBBS Archive</title>
<style>
  body { font-family: 'Zen Maru Gothic', sans-serif; background: #f5efe6; color: #3e3232; line-height: 1.8; max-width: 700px; margin: 0 auto; padding: 1rem; }
  h1 { font-size: 1.3rem; border-bottom: 2px solid #d4785c; padding-bottom: 0.5rem; margin-bottom: 1rem; }
  .post { background: #fff; border-radius: 12px; padding: 1rem; margin-bottom: 0.75rem; box-shadow: 0 1px 3px rgba(80,50,20,0.08); }
  .post.starter { border-left: 4px solid #d4785c; }
  .post.reply { border-left: 4px solid #6b9e78; }
  .meta { font-size: 0.8rem; color: #7a6b5d; margin-bottom: 0.5rem; }
  .body { word-break: break-word; }
  .timeline-sent { text-align: right; }
  .timeline-sent .post { margin-left: 20%; border-left: none; border-right: 4px solid #6b9e78; }
  .timeline-received .post { margin-right: 20%; }
  .footer { text-align: center; font-size: 0.75rem; color: #7a6b5d; margin-top: 2rem; padding-top: 1rem; border-top: 1px solid #e0d5c5; }
</style>
</head>
<body>
<h1>${title}</h1>
HTML

    for my $post (@$posts) {
        my $class = ($post->{seq_no} || 0) == 0 ? 'starter' : 'reply';
        my $author = _escape($post->{author} || '');
        my $date = _escape($post->{created_at} || '');
        my $body = _escape($post->{body} || '');
        $body =~ s/\n/<br>/g;

        if ($is_timeline && $post->{direction}) {
            my $dir_class = $post->{direction} eq 'sent' ? 'timeline-sent' : 'timeline-received';
            $html .= "<div class=\"${dir_class}\">\n";
        }

        $html .= <<"POST";
<div class="post ${class}">
  <div class="meta"><strong>${author}</strong> (${date})</div>
  <div class="body">${body}</div>
</div>
POST

        if ($is_timeline && $post->{direction}) {
            $html .= "</div>\n";
        }
    }

    $html .= <<"FOOTER";
<div class="footer">
  <p>Archived from LetterBBS ver2</p>
</div>
</body>
</html>
FOOTER

    return $html;
}

# ZIP形式でパッケージ
sub _build_zip {
    my ($self, $thread, $html) = @_;

    my $zip = Archive::Zip->new();
    $zip->addString(encode_utf8($html), 'index.html');

    my $buf = '';
    open(my $fh, '>', \$buf) or die "Cannot open buffer: $!";
    binmode($fh);
    $zip->writeToFileHandle($fh);
    close($fh);

    my $filename = 'archive_' . $thread->{id} . '.zip';
    return {
        content_type => 'application/zip',
        filename     => $filename,
        data         => $buf,
    };
}

# 単一HTML形式（ZIP不可時のフォールバック）
sub _build_single_html {
    my ($self, $thread, $html) = @_;

    my $filename = 'archive_' . $thread->{id} . '.html';
    return {
        content_type => 'text/html; charset=utf-8',
        filename     => $filename,
        data         => encode_utf8($html),
    };
}

# HTMLエスケープ
sub _escape {
    my ($str) = @_;
    return '' unless defined $str;
    $str =~ s/&/&amp;/g;
    $str =~ s/</&lt;/g;
    $str =~ s/>/&gt;/g;
    $str =~ s/"/&quot;/g;
    return $str;
}

1;
