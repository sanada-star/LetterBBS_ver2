#!/usr/bin/perl
# ============================================================
# LetterBBS ver2 — ver1 データ移行ツール
# ver1 フラットファイル形式 → ver2 SQLite へデータを移行する
# 使用後は必ず削除すること
# ============================================================
use strict;
use warnings;
use utf8;
use Encode qw(decode encode_utf8);
use File::Basename;
use lib './lib';

require './init.cgi';

use DBI;
use LetterBBS::Config;
use LetterBBS::Database;

# ============================================================
# 設定
# ============================================================
my $VER1_DIR = '../patio';  # ver1のpatioディレクトリ（相対パス）

# ver1のデータファイル仕様
# $VER1_DIR/idx.cgi   — スレッドインデックス
# $VER1_DIR/dat/NNN.cgi — 各スレッドのデータ（タブ区切り）

print "Content-Type: text/html; charset=utf-8\r\n\r\n";
print <<'HTML';
<!DOCTYPE html>
<html lang="ja"><head><meta charset="UTF-8"><title>LetterBBS v1→v2 移行</title>
<style>
  body { font-family: sans-serif; max-width: 800px; margin: 2rem auto; padding: 0 1rem; line-height: 1.8; }
  h1 { color: #d4785c; border-bottom: 2px solid #d4785c; padding-bottom: 0.5rem; }
  .ok { color: #27ae60; } .ng { color: #c0392b; } .warn { color: #d4a017; }
  pre { background: #f5f5f5; padding: 1rem; border-radius: 8px; overflow-x: auto; }
  .summary { background: #f5efe6; padding: 1rem; border-radius: 8px; margin-top: 1rem; }
</style></head><body>
<h1>LetterBBS ver1 → ver2 データ移行</h1>
HTML

# ============================================================
# 1. 環境チェック
# ============================================================
print "<h2>1. 環境チェック</h2>\n";

# ver1ディレクトリの存在確認
unless (-d $VER1_DIR) {
    err("ver1ディレクトリが見つかりません: $VER1_DIR");
    print "<p>$VER1_DIR にver1のpatioフォルダを配置してください。</p>\n";
    finish();
}
ok("ver1ディレクトリ確認: $VER1_DIR");

# インデックスファイルの確認
my $idx_file = "$VER1_DIR/idx.cgi";
unless (-f $idx_file) {
    err("インデックスファイルが見つかりません: $idx_file");
    finish();
}
ok("インデックスファイル確認: $idx_file");

# ver2のDB接続テスト
my $config = LetterBBS::Config->new();
my $db = eval { LetterBBS::Database->new($config) };
if ($@) {
    err("ver2データベース接続失敗: $@");
    finish();
}
ok("ver2データベース接続OK");

# ============================================================
# 2. ver1インデックス読み込み
# ============================================================
print "<h2>2. データ読み込み</h2>\n";

open(my $fh, '<', $idx_file) or do {
    err("インデックスファイルを開けません: $!");
    finish();
};

my @threads;
while (my $line = <$fh>) {
    $line =~ s/\r?\n$//;
    $line = decode('cp932', $line) if $line =~ /[\x80-\xff]/;
    my @fields = split(/\<\>/, $line);
    # フォーマット: no<>subject<>author<>date<>count<>status<>icon
    next unless scalar @fields >= 4;
    push @threads, {
        no      => $fields[0],
        subject => $fields[1] || '(無題)',
        author  => $fields[2] || '名無し',
        date    => $fields[3] || '',
        count   => $fields[4] || 0,
        status  => $fields[5] || '',
        icon    => $fields[6] || '',
    };
}
close($fh);

print "<p>スレッド数: <strong>" . scalar @threads . "</strong></p>\n";

# ============================================================
# 3. 移行実行
# ============================================================
print "<h2>3. 移行実行</h2>\n<pre>\n";

my $dbh = $db->dbh;
$dbh->{AutoCommit} = 0;

my $thread_count = 0;
my $post_count = 0;
my $error_count = 0;

eval {
    for my $t (@threads) {
        my $dat_file = "$VER1_DIR/dat/$t->{no}.cgi";
        unless (-f $dat_file) {
            warn_msg("データファイルなし: $dat_file（スキップ）");
            next;
        }

        # スレッドを作成
        $dbh->do(
            "INSERT INTO threads (subject, author, icon, status, created_at, updated_at) VALUES (?, ?, ?, 'active', ?, ?)",
            undef,
            $t->{subject}, $t->{author}, $t->{icon} || 'fld_nor', $t->{date}, $t->{date}
        );
        my $thread_id = $dbh->last_insert_id(undef, undef, "threads", "id");
        $thread_count++;

        # データファイルを読み込み
        open(my $dfh, '<', $dat_file) or do {
            warn_msg("データファイルを開けません: $dat_file");
            next;
        };

        my $seq = 0;
        while (my $dline = <$dfh>) {
            $dline =~ s/\r?\n$//;
            $dline = decode('cp932', $dline) if $dline =~ /[\x80-\xff]/;
            my @df = split(/\<\>/, $dline);
            # フォーマット: author<>email<>subject<>body<>date<>host<>pwd<>color
            next unless scalar @df >= 4;

            my $author  = $df[0] || '名無し';
            my $email   = $df[1] || '';
            my $subject = $df[2] || '';
            my $body    = $df[3] || '';
            my $date    = $df[4] || '';
            my $host    = $df[5] || '';
            my $pwd     = $df[6] || '';

            # HTMLタグの簡易変換（<br> → 改行）
            $body =~ s/<br\s*\/?>/\n/gi;
            $body =~ s/<[^>]+>//g;  # 残りのHTMLタグを除去

            # トリップ分離
            my $trip = '';
            if ($author =~ s/\x{25c6}(.+)$//) {
                $trip = $1;
            }

            $dbh->do(
                "INSERT INTO posts (thread_id, seq_no, author, trip, email, subject, body, password, host, created_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
                undef,
                $thread_id, $seq, $author, $trip, $email, $subject, $body, $pwd, $host, $date
            );
            $seq++;
            $post_count++;
        }
        close($dfh);

        # スレッドのpost_count更新
        $dbh->do(
            "UPDATE threads SET post_count = ? WHERE id = ?",
            undef, $seq, $thread_id
        );

        print encode_utf8("  [OK] スレッド#$t->{no} '$t->{subject}' ($seq 件)\n");
    }

    $dbh->commit;
};

if ($@) {
    $dbh->rollback;
    err("移行中にエラーが発生しました: $@");
    $error_count++;
}

print "</pre>\n";

# ============================================================
# 4. サマリー
# ============================================================
print <<SUMMARY;
<div class="summary">
<h2>4. 移行結果</h2>
<p>移行スレッド数: <strong>$thread_count</strong></p>
<p>移行記事数: <strong>$post_count</strong></p>
<p>エラー数: <strong>$error_count</strong></p>
</div>
SUMMARY

if ($error_count == 0 && $thread_count > 0) {
    print "<p class=\"ok\"><strong>移行が正常に完了しました。</strong></p>\n";
    print "<p class=\"warn\"><strong>重要: セキュリティのため、このファイル (migrate.cgi) を必ず削除してください。</strong></p>\n";
} elsif ($thread_count == 0) {
    print "<p class=\"warn\">移行対象のデータが見つかりませんでした。</p>\n";
}

finish();

# ============================================================
# ヘルパー関数
# ============================================================
sub ok   { print "<p class=\"ok\">[OK] " . encode_utf8($_[0]) . "</p>\n"; }
sub err  { print "<p class=\"ng\">[NG] " . encode_utf8($_[0]) . "</p>\n"; }
sub warn_msg { print encode_utf8("  [WARN] $_[0]\n"); }

sub finish {
    print "</body></html>\n";
    exit;
}
