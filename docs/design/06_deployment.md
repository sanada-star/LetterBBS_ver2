# LetterBBS ver2 — 詳細設計書: デプロイ・運用・移行設計

> **文書バージョン**: 1.0
> **作成日**: 2026-03-04

---

## 1. 動作環境要件

### 1.1 サーバー要件

| 項目 | 要件 |
|------|------|
| サーバー | さくらのレンタルサーバ スタンダードプラン以上 |
| Perl | 5.14 以上（5.32 推奨） |
| SQLite | 3.x（DBD::SQLite経由） |
| OS | FreeBSD / Linux |
| Webサーバー | Apache（.htaccess対応） |

### 1.2 必須Perlモジュール（さくらで標準利用可能）

| モジュール | 確認コマンド |
|-----------|-------------|
| DBI | `perl -MDBI -e 'print $DBI::VERSION'` |
| DBD::SQLite | `perl -MDBD::SQLite -e 'print $DBD::SQLite::VERSION'` |
| JSON::PP | `perl -MJSON::PP -e 'print $JSON::PP::VERSION'` |
| Digest::SHA | `perl -MDigest::SHA -e 'print $Digest::SHA::VERSION'` |
| Encode | `perl -MEncode -e 'print $Encode::VERSION'` |
| POSIX | `perl -MPOSIX -e 'print "OK"'` |
| File::Copy | `perl -MFile::Copy -e 'print "OK"'` |

### 1.3 オプションモジュール

| モジュール | 用途 | 未インストール時の動作 |
|-----------|------|---------------------|
| Archive::Zip | メモリーボックスZIP | 単一HTMLダウンロードにフォールバック |
| Image::Magick | サムネイル生成 | サムネイルなしで元画像をリサイズ表示 |

---

## 2. 新規設置手順

### 2.1 ファイル配置

```
1. patio/ ディレクトリをサーバーにアップロード
2. ディレクトリ構成が以下になっていることを確認:

public_html/
└── patio/
    ├── patio.cgi      [705]
    ├── admin.cgi      [705]
    ├── api.cgi        [705]
    ├── captcha.cgi    [705]
    ├── init.cgi       [604]
    ├── lib/           (そのまま)
    ├── tmpl/          (そのまま)
    ├── cmn/           (そのまま)
    ├── data/          [707]
    │   ├── .htaccess
    │   └── sessions/  [707]
    └── upl/           [707]
```

### 2.2 パーミッション設定

```bash
# CGI実行ファイル
chmod 705 patio.cgi admin.cgi api.cgi captcha.cgi

# 設定ファイル（読み取りのみ）
chmod 604 init.cgi

# データディレクトリ（書き込み必要）
chmod 707 data
chmod 707 data/sessions
chmod 707 upl

# .htaccess（読み取りのみ）
chmod 604 data/.htaccess
chmod 604 lib/.htaccess
chmod 604 tmpl/.htaccess
```

### 2.3 init.cgi の設定

```perl
# --- 必ず変更する項目 ---

# Perlパス（さくらの場合は通常そのまま）
#!/usr/local/bin/perl

# サイト固有設定
$cf{cgi_url}    = './patio.cgi';    # CGI の URL
$cf{admin_url}  = './admin.cgi';
$cf{api_url}    = './api.cgi';

# ディレクトリパス
$cf{data_dir}   = './data';
$cf{upl_dir}    = './upl';
$cf{upl_url}    = './upl';
$cf{tmpl_dir}   = './tmpl';
$cf{lib_dir}    = './lib';
$cf{db_file}    = './data/letterbbs.db';

# アップロード制限
$cf{max_upload_size} = 5_120_000;  # 5MB
$cf{max_image_count} = 3;

# CSRF シークレット（必ず変更すること）
$cf{csrf_secret} = 'ここにランダムな文字列を設定';

# HTTPS環境かどうか（Secure Cookie に影響）
$cf{use_https} = 0;  # HTTPS なら 1
```

### 2.4 初回アクセス

1. ブラウザで `patio.cgi` にアクセス
2. 初回アクセス時に自動で以下が実行される:
   - `data/letterbbs.db` が作成される
   - テーブル・インデックスが作成される
   - 初期設定データが投入される
   - 初期管理者アカウントが作成される（admin / password）
3. `admin.cgi` にアクセスし、管理者パスワードを変更する

### 2.5 環境チェック（check.cgi）

設置後、`check.cgi` で動作確認を行う。確認後はファイルを削除する。

**チェック項目**:
- Perl バージョン
- 必須モジュールの存在確認
- ディレクトリのパーミッション確認
- SQLite 接続テスト
- テンプレートファイルの存在確認
- オプションモジュールの有無

---

## 3. ver1 からの移行手順

### 3.1 移行の前提条件

- ver1 が動作中で、データが `data/` ディレクトリに存在すること
- ver1 のデータファイルは `<>` 区切りのフラットファイル形式であること

### 3.2 移行ツール（migrate.cgi）

ver1 のデータを ver2 の SQLite に移行する専用ツールを提供する。

```
使い方:
1. ver2 のファイルを設置（ver1 とは別ディレクトリ）
2. migrate.cgi を ver2 ディレクトリに配置
3. migrate.cgi 内の設定で ver1 のデータディレクトリパスを指定
4. ブラウザで migrate.cgi にアクセスして実行
5. 移行完了後、migrate.cgi を削除
```

### 3.3 移行処理の詳細

```
Step 1: index1.log → threads テーブル (status='active')
        各行を <> で分割し、threads に INSERT

Step 2: index2.log → threads テーブル (status='archived')
        同上

Step 3: data/log/*.cgi → posts テーブル
        各スレッドファイルを1行ずつ読み込み
        <> で分割して posts に INSERT
        画像情報は post_images テーブルに分離して INSERT

Step 4: memdata.cgi → users テーブル
        パスワードはver1形式から再ハッシュ
        ※ 元パスワードが不明のため、初回ログイン時にパスワード再設定を促す

Step 5: 管理者パスワード
        pass.dat → admin_auth テーブル
        ※ SHA-256形式の場合はそのまま移行
        ※ それ以外の形式の場合はリセットが必要

Step 6: theme.dat → settings テーブル
        テーマ設定の移行

Step 7: FTS インデックス再構築
        全 posts レコードを FTS5 に登録

Step 8: 画像ファイルの移行
        upl/ ディレクトリの画像ファイルをコピー
        ファイル名の変換は不要（パス構造が同一のため）
```

### 3.4 移行時の注意事項

| 項目 | 対応 |
|------|------|
| 文字コード | ver1 が UTF-8 以外の場合は Encode モジュールで変換 |
| 投稿パスワード | ver1 の crypt() 形式 → 照合ロジックで互換対応 |
| スレッドID | ver1 の連番をそのまま使用（AUTO_INCREMENT の開始値を調整） |
| 画像ファイル | パスの移行が必要（upl/同一構造ならコピーのみ） |
| セッション | 移行不要（全ユーザーが再ログイン） |

### 3.5 互換パスワード照合

ver1 のデータを移行した場合、投稿パスワードが crypt() 形式のままになる。
Auth.pm で両方の形式を照合できるようにする：

```perl
sub verify_password {
    my ($plain, $stored_hash) = @_;

    if ($stored_hash =~ /^\$sha256\$/) {
        # ver2 形式 (SHA-256 + salt)
        my (undef, undef, $salt, $hash) = split(/\$/, $stored_hash);
        return sha256_hex($salt . $plain) eq $hash;
    } else {
        # ver1 互換 (crypt)
        return crypt($plain, $stored_hash) eq $stored_hash;
    }
}
```

---

## 4. 運用設計

### 4.1 バックアップ

**推奨バックアップ対象**:
```
data/letterbbs.db        ← 全データ（最重要）
data/letterbbs.db-wal    ← WALログ（存在する場合）
data/letterbbs.db-shm    ← 共有メモリ（存在する場合）
upl/                     ← アップロード画像
init.cgi                 ← 設定ファイル
cmn/style*.css           ← カスタマイズしたCSS
```

**バックアップ方法（さくらのレンタルサーバ）**:
- FTPダウンロード: data/letterbbs.db + upl/ をダウンロード
- cron 自動バックアップ（さくらスタンダードプランで利用可能）:
  ```bash
  # crontab 設定例（毎日午前3時）
  0 3 * * * cp /home/user/www/patio/data/letterbbs.db /home/user/backup/letterbbs_$(date +\%Y\%m\%d).db
  ```

### 4.2 ログローテーション

SQLite のデータベースサイズが肥大化した場合:
- 管理画面の「容量確認」で現在のサイズを確認
- 過去ログの自動削除（p_max 設定値で制御）
- `VACUUM` コマンドでDBファイルの最適化

```perl
# 管理画面から実行可能な最適化
$dbh->do("VACUUM");
```

### 4.3 セッションクリーンアップ

期限切れセッションは自動的に削除されるが（1/100の確率で実行）、
溜まった場合は管理画面から手動クリーンアップも可能。

### 4.4 ストレージ容量の目安

| データ量 | 推定DBサイズ |
|---------|-------------|
| 1,000スレッド / 10,000投稿 | 約 5-10 MB |
| 5,000スレッド / 50,000投稿 | 約 30-50 MB |
| 10,000スレッド / 100,000投稿 | 約 80-120 MB |

さくらスタンダードプランのディスク容量: 300GB → 十分に余裕あり

---

## 5. トラブルシューティング

### 5.1 よくある問題と対処法

| 症状 | 原因 | 対処 |
|------|------|------|
| 500 Internal Server Error | パーミッション不正 | CGIファイルを705に設定 |
| 500 Internal Server Error | Perlパス不正 | 1行目の `#!/usr/local/bin/perl` を確認 |
| 500 Internal Server Error | 改行コード | LFに統一（CRLFは不可） |
| DB作成されない | data/ ディレクトリの権限 | 707に設定 |
| 文字化け | UTF-8でない | ファイルをUTF-8で保存 |
| 画像UP失敗 | upl/ の権限 | 707に設定 |
| ログインできない | アカウントロック | 管理画面でロック解除、またはDB直接操作 |
| セッション切れが早い | authtime設定 | 管理画面で有効時間を延長 |

### 5.2 デバッグモード

init.cgi に以下を追加すると詳細エラーが表示される（本番環境では無効化すること）:

```perl
$cf{debug} = 0;   # 0:本番 1:デバッグ（エラー詳細表示）
```

### 5.3 DB直接操作（緊急時）

さくらのSSHでSQLiteを直接操作できる：

```bash
# SSH でサーバーに接続後
cd ~/www/patio/data
sqlite3 letterbbs.db

# 管理者パスワードリセット例
UPDATE admin_auth SET password_hash = '(新しいハッシュ)', fail_count = 0, locked_until = NULL WHERE login_id = 'admin';

# ロック解除
UPDATE admin_auth SET fail_count = 0, locked_until = NULL WHERE login_id = 'admin';
```

---

## 6. ディレクトリ構成図（最終版）

```
patio/
├── patio.cgi             [705]  メインCGI
├── admin.cgi             [705]  管理画面CGI
├── api.cgi               [705]  API CGI
├── captcha.cgi           [705]  CAPTCHA CGI
├── check.cgi             [705]  環境チェック（設置後削除）
├── migrate.cgi           [705]  ver1→ver2 移行ツール（移行後削除）
├── init.cgi              [604]  設定ファイル
│
├── lib/                          Perlモジュール
│   ├── .htaccess                 Deny from all
│   ├── Database.pm
│   ├── Config.pm
│   ├── Router.pm
│   ├── Template.pm
│   ├── Session.pm
│   ├── Auth.pm
│   ├── Upload.pm
│   ├── Captcha.pm
│   ├── Sanitize.pm
│   ├── Archive.pm
│   ├── Controller/
│   │   ├── Board.pm
│   │   ├── Thread.pm
│   │   ├── Desk.pm
│   │   ├── Notification.pm
│   │   ├── Admin.pm
│   │   └── Page.pm
│   ├── Model/
│   │   ├── Thread.pm
│   │   ├── Post.pm
│   │   ├── Draft.pm
│   │   ├── User.pm
│   │   ├── AdminAuth.pm
│   │   └── Setting.pm
│   ├── CGI/                      同梱ライブラリ
│   │   └── Minimal.pm (+ 関連)
│   ├── Crypt/
│   │   └── RC4.pm
│   └── Digest/
│       └── SHA/
│           └── PurePerl.pm
│
├── tmpl/                         HTMLテンプレート
│   ├── .htaccess                 Deny from all
│   ├── layout.html
│   ├── bbs.html
│   ├── read.html
│   ├── form.html
│   ├── edit.html
│   ├── find.html
│   ├── past.html
│   ├── desk.html
│   ├── manual.html
│   ├── note.html
│   ├── enter.html
│   ├── pwd.html
│   ├── error.html
│   ├── message.html
│   └── admin/
│       ├── login.html
│       ├── menu.html
│       ├── threads.html
│       ├── thread_detail.html
│       ├── members.html
│       ├── settings.html
│       ├── design.html
│       ├── password.html
│       └── size_check.html
│
├── cmn/                          静的リソース
│   ├── style.css                 Pop テーマ
│   ├── style_gloomy.css          Gloomy テーマ
│   ├── style_simple.css          Simple テーマ
│   ├── style_fox.css             Fox テーマ
│   ├── admin.css                 管理画面CSS
│   ├── app.js                    統合JavaScript
│   ├── *.gif / *.png             アイコン類
│   └── index.html
│
├── data/                 [707]   データディレクトリ
│   ├── .htaccess                 Deny from all
│   ├── letterbbs.db              SQLiteデータベース
│   ├── sessions/         [707]   セッションファイル（将来の拡張用）
│   └── index.html
│
└── upl/                  [707]   アップロード画像
    ├── .htaccess                 CGI実行禁止
    └── index.html
```
