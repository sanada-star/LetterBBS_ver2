package LetterBBS::Upload;

#============================================================================
# LetterBBS ver2 - 画像アップロードモジュール
#============================================================================

use strict;
use warnings;
use utf8;
use File::Copy;
use File::Basename;
use LetterBBS::Sanitize;

my %ALLOWED_TYPES = (
    'image/jpeg' => 'jpg',
    'image/gif'  => 'gif',
    'image/png'  => 'png',
);

# マジックバイト定義
my %MAGIC_BYTES = (
    jpg => "\xFF\xD8\xFF",
    gif => "GIF8",
    png => "\x89PNG",
);

sub new {
    my ($class, %opts) = @_;
    return bless {
        upl_dir    => $opts{upl_dir}    || './upl',
        upl_url    => $opts{upl_url}    || './upl',
        max_size   => $opts{max_size}   || 5_120_000,
        max_count  => $opts{max_count}  || 3,
    }, $class;
}

# CGIからのファイルアップロード処理
# 返却: { filename, original, mime_type, file_size, width, height } or undef
sub process {
    my ($self, $cgi, $field_name, $thread_id, $slot) = @_;

    # 独自CGIオブジェクトからデータと元ファイル名を取得
    my $data = $cgi->upload_data($field_name);
    return undef unless defined $data && length($data) > 0;

    my $original = $cgi->upload_filename($field_name) || '';
    # Windowsパス形式のファイル名を底名のみに整形
    $original =~ s/.*[/\\]//;

    my $size = length($data);
    if ($size > $self->{max_size}) {
        return { error => 'ファイルサイズが上限を超えています。' };
    }

    my $content_type = ''; # SimpleCGIはMIMEを解釈しないため空として、マジックバイトに頼る

    # 拡張子判定
    my $ext = $self->_detect_extension($data, $content_type, $original);
    unless ($ext) {
        return { error => '許可されていないファイル形式です。(JPG/GIF/PNGのみ)' };
    }

    # マジックバイト検証
    unless ($self->_verify_magic($data, $ext)) {
        return { error => 'ファイルの内容が不正です。' };
    }

    # ファイル名生成
    my $filename = sprintf("%d_%d_%d.%s", $thread_id || 0, $slot, time(), $ext);
    my $filepath = "$self->{upl_dir}/$filename";

    # ファイル書き込み
    open my $out, '>:raw', $filepath or return { error => 'ファイルの保存に失敗しました。' };
    print $out $data;
    close $out;
    chmod 0644, $filepath;

    # 画像サイズ取得
    my ($width, $height) = $self->_get_image_size($data, $ext);

    return {
        filename  => $filename,
        original  => LetterBBS::Sanitize::sanitize_filename($original || $filename),
        mime_type => "image/$ext",
        file_size => $size,
        width     => $width,
        height    => $height,
    };
}

# ファイル削除
sub delete_file {
    my ($self, $filename) = @_;
    return unless $filename;
    my $filepath = "$self->{upl_dir}/$filename";
    unlink $filepath if -f $filepath;

    # サムネイルも削除
    my $thumb = $filepath;
    $thumb =~ s/\.(\w+)$/_thumb.$1/;
    unlink $thumb if -f $thumb;
}

# サムネイル生成（Image::Magick使用）
sub make_thumbnail {
    my ($self, $filename, $max_w, $max_h) = @_;
    $max_w ||= 200;
    $max_h ||= 200;

    eval { require Image::Magick; };
    return 0 if $@;

    my $filepath = "$self->{upl_dir}/$filename";
    my $thumb_path = $filepath;
    $thumb_path =~ s/\.(\w+)$/_thumb.$1/;

    my $img = Image::Magick->new;
    my $err = $img->Read($filepath);
    return 0 if $err;

    my ($w, $h) = $img->Get('width', 'height');
    if ($w > $max_w || $h > $max_h) {
        my $ratio = ($w / $max_w > $h / $max_h) ? $max_w / $w : $max_h / $h;
        my $new_w = int($w * $ratio);
        my $new_h = int($h * $ratio);
        $img->Resize(width => $new_w, height => $new_h);
    }
    $img->Write($thumb_path);
    chmod 0644, $thumb_path;
    return 1;
}

#--- 内部メソッド ---

sub _detect_extension {
    my ($self, $data, $content_type, $filename) = @_;

    # Content-Type から判定
    if ($content_type && $ALLOWED_TYPES{$content_type}) {
        return $ALLOWED_TYPES{$content_type};
    }

    # ファイル名の拡張子から判定
    if ($filename && $filename =~ /\.(\w+)$/) {
        my $ext = lc($1);
        $ext = 'jpg' if $ext eq 'jpeg';
        return $ext if grep { $_ eq $ext } values %ALLOWED_TYPES;
    }

    # マジックバイトから判定
    for my $ext (keys %MAGIC_BYTES) {
        my $magic = $MAGIC_BYTES{$ext};
        if (substr($data, 0, length($magic)) eq $magic) {
            return $ext;
        }
    }

    return undef;
}

sub _verify_magic {
    my ($self, $data, $ext) = @_;
    my $magic = $MAGIC_BYTES{$ext};
    return 0 unless $magic;
    return substr($data, 0, length($magic)) eq $magic ? 1 : 0;
}

sub _get_image_size {
    my ($self, $data, $ext) = @_;
    if ($ext eq 'jpg') {
        return $self->_jpeg_size($data);
    } elsif ($ext eq 'gif') {
        return $self->_gif_size($data);
    } elsif ($ext eq 'png') {
        return $self->_png_size($data);
    }
    return (undef, undef);
}

sub _jpeg_size {
    my ($self, $data) = @_;
    my $pos = 2;
    while ($pos < length($data) - 4) {
        my $marker = unpack("n", substr($data, $pos, 2));
        $pos += 2;
        if ($marker >= 0xFFC0 && $marker <= 0xFFC3) {
            my $h = unpack("n", substr($data, $pos + 1, 2));
            my $w = unpack("n", substr($data, $pos + 3, 2));
            return ($w, $h);
        }
        my $len = unpack("n", substr($data, $pos, 2));
        $pos += $len;
    }
    return (undef, undef);
}

sub _gif_size {
    my ($self, $data) = @_;
    return (undef, undef) if length($data) < 10;
    my $w = unpack("v", substr($data, 6, 2));
    my $h = unpack("v", substr($data, 8, 2));
    return ($w, $h);
}

sub _png_size {
    my ($self, $data) = @_;
    return (undef, undef) if length($data) < 24;
    my $w = unpack("N", substr($data, 16, 4));
    my $h = unpack("N", substr($data, 20, 4));
    return ($w, $h);
}

1;
