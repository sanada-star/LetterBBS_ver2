#!/usr/local/bin/perl

#============================================================================
# LetterBBS ver2 - 環境チェックCGI
# サーバー環境の確認・初回セットアップ診断用
# 本番運用時は削除またはアクセス制限を推奨
#============================================================================

use strict;
use warnings;
use utf8;

print "Content-Type: text/html; charset=utf-8\n\n";

print <<'HTML_HEAD';
<!DOCTYPE html>
<html lang="ja">
<head>
<meta charset="UTF-8">
<title>LetterBBS ver2 - 環境チェック</title>
<style>
body { font-family: sans-serif; max-width: 800px; margin: 20px auto; padding: 0 20px; background: #f5f5f5; }
h1 { color: #333; border-bottom: 2px solid #666; padding-bottom: 10px; }
h2 { color: #555; margin-top: 30px; }
table { width: 100%; border-collapse: collapse; margin: 10px 0; }
th, td { border: 1px solid #ccc; padding: 8px 12px; text-align: left; }
th { background: #eee; width: 40%; }
.ok { color: #2a7; font-weight: bold; }
.warn { color: #c80; font-weight: bold; }
.ng { color: #c33; font-weight: bold; }
.section { background: #fff; border: 1px solid #ddd; border-radius: 6px; padding: 15px; margin: 15px 0; }
</style>
</head>
<body>
<h1>LetterBBS ver2 - 環境チェック</h1>
HTML_HEAD

# Perl バージョン
print "<div class='section'>\n";
print "<h2>Perl環境</h2>\n";
print "<table>\n";
_row('Perlバージョン', $], $] >= 5.014 ? 'ok' : 'ng',
    $] >= 5.014 ? '' : '5.14以上が必要です');
_row('Perlパス', $^X, 'ok', '');

# エンコーディング
my $enc_ok = eval { require Encode; 1 };
_row('Encode', $enc_ok ? 'OK' : 'NG', $enc_ok ? 'ok' : 'ng', '');

print "</table>\n</div>\n";

# 必須モジュール
print "<div class='section'>\n";
print "<h2>必須モジュール</h2>\n";
print "<table>\n";

my @required = (
    ['DBI',           'データベースインタフェース'],
    ['DBD::SQLite',   'SQLiteドライバ'],
    ['JSON::PP',      'JSON処理（Perl標準）'],
    ['File::Copy',    'ファイルコピー（Perl標準）'],
    ['File::Path',    'ディレクトリ操作（Perl標準）'],
    ['POSIX',         'POSIX関数（Perl標準）'],
);

for my $mod (@required) {
    my ($name, $desc) = @$mod;
    my $ok = eval "require $name; 1";
    my $ver = $ok ? (eval "\$${name}::VERSION" || '?') : '-';
    _row("$name ($desc)", $ok ? "OK ($ver)" : 'NG',
        $ok ? 'ok' : 'ng',
        $ok ? '' : "インストールが必要です");
}
print "</table>\n</div>\n";

# 暗号化モジュール
print "<div class='section'>\n";
print "<h2>暗号化モジュール</h2>\n";
print "<table>\n";

my $sha_ok = eval { require Digest::SHA; 1 };
my $sha_pp = eval { require Digest::SHA::PurePerl; 1 };
_row('Digest::SHA', $sha_ok ? 'OK' : 'なし',
    $sha_ok ? 'ok' : 'warn',
    $sha_ok ? '' : 'PurePerl版で代替します');
_row('Digest::SHA::PurePerl',
    $sha_pp ? 'OK' : ($sha_ok ? '不要' : 'NG'),
    ($sha_pp || $sha_ok) ? 'ok' : 'ng',
    ($sha_pp || $sha_ok) ? '' : 'SHA系モジュールが1つも見つかりません');

print "</table>\n</div>\n";

# オプションモジュール
print "<div class='section'>\n";
print "<h2>オプションモジュール</h2>\n";
print "<table>\n";

my @optional = (
    ['Image::Magick', 'サムネイル生成'],
);
for my $mod (@optional) {
    my ($name, $desc) = @$mod;
    my $ok = eval "require $name; 1";
    _row("$name ($desc)", $ok ? 'OK' : 'なし',
        $ok ? 'ok' : 'warn',
        $ok ? '' : 'サムネイル機能は使用できません');
}
print "</table>\n</div>\n";

# SQLite FTS5チェック
print "<div class='section'>\n";
print "<h2>SQLite機能</h2>\n";
print "<table>\n";

my $sqlite_ver = '-';
my $fts5_ok = 0;
eval {
    require DBI;
    my $dbh = DBI->connect("dbi:SQLite:dbname=:memory:", "", "", { RaiseError => 1 });
    $sqlite_ver = $dbh->selectrow_array("SELECT sqlite_version()");
    eval {
        $dbh->do("CREATE VIRTUAL TABLE _fts_test USING fts5(content)");
        $dbh->do("DROP TABLE _fts_test");
        $fts5_ok = 1;
    };
    $dbh->disconnect();
};
_row('SQLiteバージョン', $sqlite_ver, 'ok', '');
_row('FTS5サポート', $fts5_ok ? 'OK' : 'なし',
    $fts5_ok ? 'ok' : 'warn',
    $fts5_ok ? '全文検索が利用可能です' : 'LIKE検索にフォールバックします');

print "</table>\n</div>\n";

# ディレクトリ・パーミッション
print "<div class='section'>\n";
print "<h2>ディレクトリ・パーミッション</h2>\n";
print "<table>\n";

my @dirs = (
    ['./data',          'データ格納', 1],
    ['./data/sessions', 'セッション（未使用／将来用）', 0],
    ['./upl',           '画像アップロード', 1],
    ['./tmpl',          'テンプレート', 0],
    ['./lib',           'ライブラリ', 0],
);

for my $d (@dirs) {
    my ($path, $desc, $need_write) = @$d;
    my $exists = -d $path;
    my $writable = $exists ? -w $path : 0;
    my $status = !$exists ? 'NG（存在しません）'
               : $need_write && !$writable ? 'NG（書き込み不可）'
               : 'OK';
    my $class = $status =~ /OK/ ? 'ok' : 'ng';
    _row("$path ($desc)", $status, $class,
        !$exists ? 'ディレクトリを作成してください'
        : $need_write && !$writable ? 'chmod 707 等で書き込み権限を付与してください'
        : '');
}

print "</table>\n</div>\n";

# CGIファイル実行権限
print "<div class='section'>\n";
print "<h2>CGIファイル</h2>\n";
print "<table>\n";

my @cgis = qw(patio.cgi api.cgi admin.cgi init.cgi);
for my $f (@cgis) {
    my $exists = -f "./$f";
    _row($f, $exists ? 'OK' : 'NG',
        $exists ? 'ok' : 'ng',
        $exists ? '' : 'ファイルが見つかりません');
}

print "</table>\n</div>\n";

# DB初期化テスト
print "<div class='section'>\n";
print "<h2>データベース接続テスト</h2>\n";
print "<table>\n";

eval {
    require DBI;
    my $db_file = './data/letterbbs.db';
    if (-f $db_file) {
        my $dbh = DBI->connect("dbi:SQLite:dbname=$db_file", "", "", { RaiseError => 1 });
        my $tables = $dbh->selectcol_arrayref(
            "SELECT name FROM sqlite_master WHERE type='table' ORDER BY name"
        );
        _row('DB接続', 'OK', 'ok', '');
        _row('テーブル数', scalar(@$tables), 'ok', join(', ', @$tables));
        $dbh->disconnect();
    } else {
        _row('DBファイル', '未作成', 'warn', '初回アクセス時に自動作成されます');
    }
};
if ($@) {
    _row('DB接続', 'NG', 'ng', $@);
}

print "</table>\n</div>\n";

# セキュリティ警告
print "<div class='section'>\n";
print "<h2>セキュリティ確認</h2>\n";
print "<table>\n";

eval {
    require './init.cgi';
    my %cf = set_init();
    my $csrf_default = $cf{csrf_secret} eq 'CHANGE_ME_TO_RANDOM_STRING';
    _row('CSRF Secret', $csrf_default ? '未変更（デフォルト）' : '設定済み',
        $csrf_default ? 'ng' : 'ok',
        $csrf_default ? 'init.cgi の csrf_secret を必ず変更してください' : '');
};
if ($@) {
    _row('init.cgi', '読み込みエラー', 'ng', $@);
}

print "</table>\n</div>\n";

print "<p style='color:#999; margin-top:30px;'>このファイル (check.cgi) は環境確認後に削除することを推奨します。</p>\n";
print "</body></html>\n";

exit;

sub _row {
    my ($label, $value, $class, $note) = @_;
    $class ||= '';
    $note  ||= '';
    print "<tr><th>$label</th><td class='$class'>$value";
    print " <span style='font-weight:normal;color:#666;'>$note</span>" if $note;
    print "</td></tr>\n";
}
