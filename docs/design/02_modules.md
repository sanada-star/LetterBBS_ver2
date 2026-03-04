# LetterBBS ver2 — 詳細設計書: モジュール設計

> **文書バージョン**: 1.0
> **作成日**: 2026-03-04

---

## 1. モジュール一覧

```
lib/
├── Database.pm             DB接続・マイグレーション・トランザクション
├── Config.pm               設定値管理（init.cgi + DB settings）
├── Router.pm               URLパラメータ → アクション振り分け
├── Template.pm             テンプレートエンジン
├── Session.pm              セッション管理（DB保存）
├── Auth.pm                 認証共通処理（パスワードハッシュ、トリップ生成）
├── Upload.pm               画像アップロード・バリデーション
├── Captcha.pm              CAPTCHA 生成・検証
├── Sanitize.pm             入力サニタイズ・バリデーション
├── Archive.pm              メモリーボックス（HTML/ZIPアーカイブ生成）
│
├── Controller/
│   ├── Board.pm            スレッド一覧・検索・過去ログ
│   ├── Thread.pm           スレッド閲覧・投稿・編集・削除・アーカイブ
│   ├── Desk.pm             文通デスク（下書き管理・一括送信）
│   ├── Notification.pm     通知API
│   ├── Admin.pm            管理画面（ログ管理・会員管理・設定変更）
│   └── Page.pm             静的ページ（マニュアル・留意事項）
│
└── Model/
    ├── Thread.pm           スレッドCRUD
    ├── Post.pm             投稿CRUD
    ├── Draft.pm            下書きCRUD
    ├── User.pm             ユーザーCRUD（会員認証モード）
    ├── AdminAuth.pm        管理者認証
    └── Setting.pm          設定値CRUD
```

---

## 2. ユーティリティモジュール

### 2.1 Database.pm

DB接続管理とマイグレーション。アプリケーション全体で1つのインスタンスを共有する。

```perl
package LetterBBS::Database;

# 公開メソッド:
# new($db_path)            - DBファイルのパスを指定して接続
# dbh()                    - DBI ハンドルを返す
# initialize()             - スキーマ作成・マイグレーション実行
# begin_transaction()      - トランザクション開始
# commit()                 - コミット
# rollback()               - ロールバック
# disconnect()             - 切断

# 内部メソッド:
# _connect()               - SQLite接続（WAL, foreign_keys等のPRAGMA設定）
# _get_schema_version()    - 現在のスキーマバージョン取得
# _set_schema_version($v)  - バージョン設定
# _create_tables()         - 全テーブル作成
# _insert_defaults()       - 初期データ投入
```

**接続設定**:
```perl
my $dbh = DBI->connect(
    "dbi:SQLite:dbname=$db_path",
    "", "",
    {
        RaiseError     => 1,
        PrintError     => 0,
        AutoCommit     => 1,
        sqlite_unicode => 1,
    }
);
$dbh->do("PRAGMA journal_mode = WAL");
$dbh->do("PRAGMA busy_timeout = 5000");
$dbh->do("PRAGMA foreign_keys = ON");
```

### 2.2 Config.pm

設定値の二層管理：固定設定（init.cgi）＋ 動的設定（DB settings テーブル）。

```perl
package LetterBBS::Config;

# 公開メソッド:
# new($init_path, $db)     - init.cgi読み込み + DB設定マージ
# get($key)                - 設定値取得
# set($key, $value)        - 動的設定の更新（DBに保存）
# all()                    - 全設定値をハッシュで返す

# 設定の優先順位:
# 1. DB settings テーブル（管理画面から変更可能な値）
# 2. init.cgi（サーバー固有の固定設定: パス、パーミッション等）
```

**init.cgi で定義する固定設定**:
```perl
# サーバーパス系（環境依存、DB に入れない）
$cf{cgi_url}    = './patio.cgi';
$cf{admin_url}  = './admin.cgi';
$cf{api_url}    = './api.cgi';
$cf{data_dir}   = './data';
$cf{upl_dir}    = './upl';
$cf{upl_url}    = './upl';
$cf{tmpl_dir}   = './tmpl';
$cf{lib_dir}    = './lib';
$cf{db_file}    = './data/letterbbs.db';

# サーバー制限
$cf{max_upload_size} = 5_120_000;   # 5MB
$cf{max_image_count} = 3;
```

**DB settings テーブルで管理する動的設定**:
```
bbs_title, authkey, authtime, image_upl, thumbnail, use_captcha,
i_max, p_max, m_max, pg_max, pgmax_now, pgmax_past, theme,
wait (連続投稿待機秒), max_failpass, lock_days
```

### 2.3 Router.pm

URLパラメータからアクション名を決定し、対応するControllerメソッドを呼び出す。

```perl
package LetterBBS::Router;

# 公開メソッド:
# new(%args)               - コントローラー群を受け取る
# dispatch($params)        - パラメータに基づきアクション実行

# ルーティングテーブル:
my %ROUTES = (
    # patio.cgi のアクション
    ''          => ['Board',        'list'],         # デフォルト
    'list'      => ['Board',        'list'],
    'read'      => ['Thread',       'read'],
    'form'      => ['Thread',       'form'],
    'post'      => ['Thread',       'post'],
    'edit'      => ['Thread',       'edit_form'],
    'edit_exec' => ['Thread',       'edit_exec'],
    'delete'    => ['Thread',       'delete'],
    'lock'      => ['Thread',       'lock'],
    'search'    => ['Board',        'search'],
    'past'      => ['Board',        'past'],
    'archive'   => ['Thread',       'archive'],
    'pwd'       => ['Thread',       'pwd_form'],
    'desk'      => ['Desk',         'show'],
    'manual'    => ['Page',         'manual'],
    'note'      => ['Page',         'note'],
    'enter'     => ['Page',         'enter'],
);

# api.cgi のルーティングテーブル:
my %API_ROUTES = (
    'threads'       => ['Notification', 'thread_list'],
    'timeline'      => ['Notification', 'timeline'],
    'desk_list'     => ['Desk',         'api_list'],
    'desk_save'     => ['Desk',         'api_save'],
    'desk_delete'   => ['Desk',         'api_delete'],
    'desk_send'     => ['Desk',         'api_send'],
);
```

### 2.4 Template.pm

テンプレートファイルを読み込み、変数・ループ・条件を展開してHTMLを生成する。

```perl
package LetterBBS::Template;

# 公開メソッド:
# new($tmpl_dir)           - テンプレートディレクトリ指定
# render($file, %vars)     - テンプレートを描画して文字列を返す
# render_with_layout($file, %vars)  - layout.html でラップして描画

# テンプレート構文:
# <!-- var:name -->                 変数置換（自動HTMLエスケープ）
# <!-- raw:name -->                 変数置換（エスケープなし）
# <!-- loop:items -->...<!-- /loop:items -->  ループ
# <!-- if:flag -->...<!-- /if:flag -->        条件（真なら表示）
# <!-- unless:flag -->...<!-- /unless:flag --> 条件（偽なら表示）
# <!-- else -->                     else（if/unlessの中で使用）
# <!-- include:partial.html -->     部分テンプレート読込

# ループ内の特殊変数:
# <!-- var:_index -->       0始まりインデックス
# <!-- var:_count -->       1始まりカウント
# <!-- var:_first -->       最初の要素なら "1"
# <!-- var:_last -->        最後の要素なら "1"
# <!-- var:_odd -->         奇数行なら "1"
```

**テンプレート例**（bbs.html の一部）:
```html
<h1><!-- var:bbs_title --></h1>
<!-- loop:threads -->
<div class="thread-item <!-- if:_odd -->odd<!-- /if:_odd -->">
    <a href="<!-- var:cgi_url -->?action=read&id=<!-- var:id -->">
        <!-- var:subject -->
    </a>
    <span class="author"><!-- var:author --></span>
    <span class="date"><!-- var:updated_at --></span>
    <!-- if:is_locked -->
    <span class="lock-badge">LOCKED</span>
    <!-- /if:is_locked -->
</div>
<!-- /loop:threads -->
```

### 2.5 Session.pm

セッション管理。SQLite にセッションデータを保存する。

```perl
package LetterBBS::Session;

# 公開メソッド:
# new($db, $cookie_name)   - DB接続とクッキー名を指定
# start($request)          - セッション開始（既存 or 新規）
# get($key)                - セッションデータ取得
# set($key, $value)        - セッションデータ設定
# id()                     - セッションIDを返す
# destroy()                - セッション破棄
# cookie_header()          - Set-Cookie ヘッダー文字列を返す
# cleanup()                - 期限切れセッション削除

# セッションIDの生成:
# 32バイトのランダムバイト列 → hex エンコード (64文字)
# Digest::SHA を使用: sha256_hex(rand() . time() . $$)
```

**セッションの有効期限**:
- デフォルト: 60分（管理画面の authtime 設定で変更可能）
- 各リクエストでアクセスがあれば自動延長
- cleanup() は定期的に呼び出し（1/100 の確率で実行）

### 2.6 Auth.pm

認証・パスワード関連の共通処理。

```perl
package LetterBBS::Auth;

# 公開メソッド:
# hash_password($plain, $salt)   - SHA-256 + salt でハッシュ化
# verify_password($plain, $hash) - パスワード照合
# generate_salt()                - ランダムsalt生成（16バイト hex）
# generate_trip($name_with_key)  - トリップ生成（名前#キー → 名前◆xxx）
# generate_token()               - CSRFトークン生成

# パスワードハッシュ形式:
# "$sha256${salt}${hash}"
# 例: "$sha256$a1b2c3d4e5f6...$abcdef0123456789..."

# トリップ生成アルゴリズム（ver1互換）:
# 1. 名前#パスワード を分離
# 2. パスワードから salt を生成
# 3. crypt() で暗号化
# 4. 先頭2文字を除去 → ◆ の後に付与
```

### 2.7 Upload.pm

画像アップロードのバリデーションとファイル保存。

```perl
package LetterBBS::Upload;

# 公開メソッド:
# new($upl_dir, $upl_url, %opts)  - アップロードディレクトリ指定
# process($cgi, $field_name)      - CGIオブジェクトからファイル処理
#   → 返却: { filename, original, mime_type, file_size, width, height }
# delete($filename)                - ファイル削除
# make_thumbnail($filename, $max_size) - サムネイル生成

# バリデーション:
# - 許可MIMEタイプ: image/jpeg, image/gif, image/png
# - ファイルサイズ上限チェック（Config の max_upload_size）
# - マジックバイト検証（拡張子だけでなくファイルヘッダも確認）
# - ファイル名サニタイズ: タイムスタンプ + 連番 + 拡張子

# ファイル名の生成:
# {スレッドID}_{連番}_{タイムスタンプ}.{拡張子}
# 例: 42_1_1709510400.jpg
```

### 2.8 Sanitize.pm

入力値のサニタイズとバリデーション。

```perl
package LetterBBS::Sanitize;

# 公開メソッド:
# html_escape($str)           - HTML特殊文字エスケープ (&, <, >, ", ')
# html_unescape($str)         - エスケープ解除
# nl2br($str)                 - 改行を <br> に変換
# autolink($str)              - URL文字列を <a> タグに変換
# strip_tags($str)            - HTMLタグ除去
# truncate($str, $len)        - 文字列を指定長で切り詰め
# validate_utf8($str)         - UTF-8 バリデーション
# sanitize_filename($str)     - ファイル名の安全化
# is_valid_email($str)        - メールアドレス形式チェック

# 全入力値に対して自動適用するフロー:
# 1. validate_utf8() で不正バイト列を除去
# 2. 制御文字（\x00-\x08, \x0B, \x0C, \x0E-\x1F）を除去
# 3. 先頭・末尾の空白をtrim
# 4. HTMLテンプレート挿入時は html_escape() を適用
```

### 2.9 Captcha.pm

CAPTCHA 画像認証の生成と検証。ver1 の lib/captcha.pl, lib/captsec.pl を統合。

```perl
package LetterBBS::Captcha;

# 公開メソッド:
# new($config)                     - 設定読み込み
# generate()                       - 認証コード生成、暗号化トークン返却
#   → 返却: { token => "...", image_url => "captcha.cgi?t=..." }
# verify($input, $token)           - 入力と暗号化トークンを照合
#   → 返却: 1(一致) / 0(期限切れ) / -1(不一致)

# 暗号化方式: Crypt::RC4（ver1互換）
# トークン形式: hex(RC4(passphrase, "{数字}{タイムスタンプ}"))
# 有効期限: 30分
```

### 2.10 Archive.pm

メモリーボックス機能。スレッドをHTMLアーカイブとしてZIPダウンロードする。

```perl
package LetterBBS::Archive;

# 公開メソッド:
# new($config, $db)                - 設定とDB接続
# generate($thread_id, %opts)      - スレッドのアーカイブ生成
#   opts: { include_timeline => 1, partner_name => "..." }
#   → 返却: ZIPバイナリデータ（Content-Disposition: attachment 用）

# アーカイブ内容:
# archive.zip
# ├── index.html          メインビューア（チャット風レイアウト）
# ├── style.css           スタイルシート（テーマ対応）
# └── images/             画像ファイル（存在する場合）
```

---

## 3. Controller モジュール

### 3.1 Controller::Board

スレッド一覧関連の表示と操作。

```perl
package LetterBBS::Controller::Board;

# list($params)
#   スレッド一覧表示（メインページ）
#   - params: page（ページ番号）
#   - threads テーブルから status='active' を updated_at DESC で取得
#   - ページネーション計算
#   - テンプレート: bbs.html

# search($params)
#   キーワード検索
#   - params: keyword, mode（AND/OR）, page
#   - FTS5 で posts_fts を検索
#   - テンプレート: find.html

# past($params)
#   過去ログ一覧表示
#   - params: page
#   - threads テーブルから status='archived' を取得
#   - テンプレート: past.html
```

### 3.2 Controller::Thread

個別スレッドの閲覧と操作。

```perl
package LetterBBS::Controller::Thread;

# read($params)
#   スレッド閲覧
#   - params: id（スレッドID）, page
#   - posts テーブルからスレッド内記事取得
#   - ページネーション（pg_max 件/ページ）
#   - アクセスカウント更新
#   - テンプレート: read.html

# form($params)
#   投稿フォーム表示
#   - params: id（返信時）, quote（引用時）
#   - CAPTCHAトークン生成（有効時）
#   - CSRFトークン生成
#   - テンプレート: form.html

# post($params)
#   投稿実行（新規スレッド or 返信）
#   - 処理フロー:
#     1. CSRFトークン検証
#     2. CAPTCHAトークン検証（有効時）
#     3. 入力バリデーション
#     4. 連続投稿チェック（同一ホスト + wait秒以内）
#     5. トリップ生成（名前#キー の場合）
#     6. 画像アップロード処理
#     7. DB INSERT（トランザクション）
#       - 新規: threads + posts を INSERT
#       - 返信: posts を INSERT, threads を UPDATE
#     8. スレッド数上限チェック → 超過分を archived に
#     9. リダイレクト

# edit_form($params)
#   編集フォーム表示
#   - params: thread_id, post_seq
#   - パスワード照合後に表示
#   - テンプレート: edit.html

# edit_exec($params)
#   編集実行
#   - params: thread_id, post_seq, subject, body, password
#   - パスワード照合 → 本文更新

# delete($params)
#   記事削除
#   - params: thread_id, post_seq, password
#   - パスワード照合 → 論理削除（is_deleted=1）
#   - 画像ファイルの物理削除

# lock($params)
#   スレッドロック切り替え
#   - params: thread_id, password
#   - 管理者パスワード照合 → is_locked トグル

# pwd_form($params)
#   パスワード確認フォーム
#   - テンプレート: pwd.html

# archive($params)
#   メモリーボックス ダウンロード
#   - params: thread_id, partner（タイムライン相手）
#   - Archive.pm でZIP生成 → ダウンロード
```

### 3.3 Controller::Desk

文通デスク機能。サーバー側で下書きを管理する。

```perl
package LetterBBS::Controller::Desk;

# show($params)
#   文通デスク画面表示
#   - セッションID で自分の下書き一覧を取得
#   - 各下書きに紐づくスレッド情報も取得
#   - テンプレート: desk.html

# --- 以下は API (api.cgi 経由、JSON応答) ---

# api_list($params)
#   下書き一覧取得
#   - セッションIDで drafts テーブルを検索
#   - 返却: JSON { drafts: [...] }

# api_save($params)
#   下書き保存（新規 or 更新）
#   - params: thread_id, author, subject, body, draft_id(更新時)
#   - drafts テーブルに INSERT or UPDATE
#   - 返却: JSON { success: true, draft_id: N }

# api_delete($params)
#   下書き削除
#   - params: draft_id
#   - 返却: JSON { success: true }

# api_send($params)
#   一括送信
#   - params: draft_ids (カンマ区切り)
#   - トランザクション内で:
#     1. 各下書きを drafts から取得
#     2. posts テーブルに INSERT
#     3. threads テーブルを UPDATE
#     4. drafts テーブルから DELETE
#   - 返却: JSON { success: true, posted: N }
```

**文通デスクの処理フロー**:
```
[ユーザー操作]                   [サーバー処理]

1. 記事閲覧中に
   「デスクに置く」クリック  →   api_save() で draft作成
                                 (thread_id, author を保存)

2. デスク画面を開く          →   show() / api_list()
   各下書きが表示される          (drafts + thread情報を返却)

3. 下書きの本文を編集        →   api_save() で draft更新
   (自動保存 or 保存ボタン)      (body を UPDATE)

4. タイムライン参照          →   api timeline (Notification)
   相手との過去やり取り表示      (SQL JOINで正確に取得)

5. 「一括送信」クリック      →   api_send()
   全下書きを投稿               (トランザクション)
```

### 3.4 Controller::Notification

通知ポーリング用API。

```perl
package LetterBBS::Controller::Notification;

# thread_list($params)
#   スレッド一覧（通知用）
#   - params: since（ISO 8601日時、前回取得以降の更新分のみ）
#   - threads テーブルから updated_at > since のものを返却
#   - 返却: JSON { threads: [...], server_time: "..." }

# timeline($params)
#   タイムライン取得
#   - params: my_name, partner_name
#   - 01_database.md §5 のタイムラインクエリを実行
#   - 返却: JSON { posts: [...] }
```

**ポーリング改善点**（ver1 との比較）:

| 項目 | ver1 | ver2 |
|------|------|------|
| 取得範囲 | 全スレッド一覧を毎回取得 | `since` パラメータで差分のみ |
| データ量 | HTML全体 | JSON（軽量） |
| 間隔 | 固定 | 未読なし:60秒 / 未読あり:30秒 / アクティブ:15秒 |
| 最終時刻 | クライアント時刻 | サーバー時刻（server_time）で統一 |

### 3.5 Controller::Admin

管理画面。admin.cgi から呼び出される。

```perl
package LetterBBS::Controller::Admin;

# login($params)          - ログイン処理
# logout($params)         - ログアウト処理
# menu($params)           - メニュー表示
# thread_list($params)    - スレッド管理（一覧・削除・ロック）
# thread_detail($params)  - スレッド内記事管理（個別削除）
# member_list($params)    - 会員管理（一覧・追加・編集・削除）
# settings($params)       - 設定変更（bbs_title, i_max等）
# design($params)         - テーマ設定
# password($params)       - 管理パスワード変更
# size_check($params)     - ストレージ容量確認

# 全メソッドで管理者セッション検証を必須とする
# セッションが無効な場合はログイン画面にリダイレクト
```

### 3.6 Controller::Page

静的コンテンツページ。

```perl
package LetterBBS::Controller::Page;

# manual($params)   - マニュアル表示 (tmpl/manual.html)
# note($params)     - 留意事項表示 (tmpl/note.html)
# enter($params)    - ログイン画面表示（会員認証モード時）(tmpl/enter.html)
```

---

## 4. Model モジュール

### 4.1 Model::Thread

```perl
package LetterBBS::Model::Thread;

# new($db)

# find($id)
#   → { id, subject, author, status, is_locked, ... }

# list(%opts)
#   opts: status, page, per_page, order_by
#   → [{ thread }, ...]

# create(%data)
#   data: subject, author, email
#   → thread_id

# update($id, %data)
#   更新可能: subject, is_locked, admin_note, status

# delete($id)
#   status を 'deleted' に変更 + 配下の posts を論理削除

# archive_old($max_active)
#   active スレッド数が max_active を超えた分を archived に変更

# purge_old($max_archived)
#   archived スレッド数が max_archived を超えた分を物理削除

# count_by_status($status)
#   → INTEGER
```

### 4.2 Model::Post

```perl
package LetterBBS::Model::Post;

# new($db)

# find($id)
# find_by_thread_seq($thread_id, $seq_no)

# list_by_thread($thread_id, %opts)
#   opts: page, per_page, include_deleted
#   → [{ post }, ...]

# create(%data)
#   data: thread_id, author, email, trip, subject, body, password, host, url, show_email
#   - seq_no は自動計算: MAX(seq_no) + 1 WHERE thread_id = ?
#   → post_id

# update($id, %data)
#   更新可能: subject, body, updated_at

# soft_delete($id)
#   is_deleted = 1 に設定

# search(%opts)
#   FTS5 による全文検索
#   opts: keyword, mode(AND/OR), page, per_page
#   → [{ post + thread_subject }, ...]

# timeline($my_name, $partner_name)
#   01_database.md §5 のタイムラインクエリ実行
#   → [{ post + direction }, ...]

# check_flood($host, $wait_seconds)
#   連続投稿チェック
#   → 1(投稿可) / 0(待機中)
```

### 4.3 Model::Draft

```perl
package LetterBBS::Model::Draft;

# new($db)

# find($id)
# list_by_session($session_id)
#   → [{ draft + thread_subject }, ...]

# create(%data)
#   data: thread_id, session_id, author, subject, body
#   → draft_id

# update($id, %data)
#   更新可能: author, subject, body

# delete($id)
# delete_by_session($session_id)   # 全下書き削除

# send_all($session_id, $host)
#   トランザクション内で:
#   1. list_by_session() で下書き取得
#   2. 各下書きを Post::create() で投稿
#   3. 投稿済み下書きを DELETE
#   → 投稿数
```

### 4.4 Model::User（会員認証モード用）

```perl
package LetterBBS::Model::User;

# new($db)
# find($id)
# find_by_login_id($login_id)
# list(%opts)
# create(%data)    # login_id, password(平文→ハッシュ化), name, rank
# update($id, %data)
# delete($id)
# authenticate($login_id, $password)  → user or undef
```

### 4.5 Model::AdminAuth

```perl
package LetterBBS::Model::AdminAuth;

# new($db)
# authenticate($login_id, $password)
#   1. login_id で検索
#   2. ロック状態チェック
#   3. パスワード照合
#   4. 成功: fail_count=0, last_login_at更新
#      失敗: fail_count+1, 上限超過時はlocked_until設定
#   → { success => 1, user => {...} } or { success => 0, reason => "..." }

# change_password($login_id, $old_pass, $new_pass)
# reset_lock($login_id)   # 管理者によるロック解除
```

### 4.6 Model::Setting

```perl
package LetterBBS::Model::Setting;

# new($db)
# get($key)        → 値
# set($key, $value)
# get_all()        → { key => value, ... }
# set_bulk(%data)  → トランザクション内で複数更新
```

---

## 5. エントリーポイント

### 5.1 patio.cgi（メイン）

```perl
#!/usr/local/bin/perl
use strict;
use warnings;
use utf8;
use lib './lib';

use CGI::Minimal;
use LetterBBS::Config;
use LetterBBS::Database;
use LetterBBS::Session;
use LetterBBS::Router;
use LetterBBS::Template;

# 1. 設定読み込み
my $config = LetterBBS::Config->new('./init.cgi');

# 2. DB接続 + 初期化
my $db = LetterBBS::Database->new($config->get('db_file'));
$db->initialize();
$config->load_db_settings($db);

# 3. CGIパラメータ解析
my $cgi = CGI::Minimal->new;

# 4. セッション処理
my $session = LetterBBS::Session->new($db, 'letterbbs_sid');
$session->start($cgi);

# 5. テンプレート準備
my $tmpl = LetterBBS::Template->new($config->get('tmpl_dir'));

# 6. ルーティング実行
my $router = LetterBBS::Router->new(
    config   => $config,
    db       => $db,
    session  => $session,
    template => $tmpl,
    cgi      => $cgi,
);
$router->dispatch($cgi->param('action') || '');

# 7. クリーンアップ
$db->disconnect();
```

### 5.2 api.cgi（API）

```perl
#!/usr/local/bin/perl
use strict;
use warnings;
use utf8;
use lib './lib';

# ... (patio.cgi と同様の初期化)

# Content-Type: application/json
print "Content-Type: application/json; charset=utf-8\n";
print $session->cookie_header() . "\n" if $session->cookie_header();
print "\n";

# APIルーティング実行
my $router = LetterBBS::Router->new(...);
$router->dispatch_api($cgi->param('api') || '');

$db->disconnect();
```

### 5.3 admin.cgi（管理画面）

```perl
#!/usr/local/bin/perl
use strict;
use warnings;
use utf8;
use lib './lib';

# ... (patio.cgi と同様の初期化)

# 管理者セッション検証
my $admin_session = LetterBBS::Session->new($db, 'letterbbs_admin');
$admin_session->start($cgi);

# 管理画面ルーティング
my $router = LetterBBS::Router->new(...);
$router->dispatch_admin($cgi->param('action') || '', $admin_session);

$db->disconnect();
```

---

## 6. 依存モジュール一覧

### 6.1 必須（さくらのレンタルサーバで標準利用可能）

| モジュール | 用途 |
|-----------|------|
| DBI | データベースインターフェース |
| DBD::SQLite | SQLiteドライバ |
| CGI::Minimal | CGIパラメータ解析（同梱） |
| Digest::SHA | パスワードハッシュ（PurePerl同梱） |
| POSIX | 日時処理 |
| File::Copy | ファイル操作 |
| File::Basename | パス処理 |
| Encode | UTF-8処理 |
| JSON::PP | JSON処理（Perl 5.14+標準） |

### 6.2 オプション

| モジュール | 用途 | フォールバック |
|-----------|------|--------------|
| Archive::Zip | メモリーボックス | 非ZIP形式（単一HTML）で代替 |
| Image::Magick | サムネイル生成 | サムネイルなしで表示 |
| Crypt::RC4 | CAPTCHA暗号化（同梱） | — |

### 6.3 同梱ライブラリ（lib/ に配置）

| ライブラリ | 用途 |
|-----------|------|
| CGI::Minimal | CGIパラメータ解析 |
| Crypt::RC4 | CAPTCHA用RC4暗号化 |
| Digest::SHA::PurePerl | SHA-256（環境にDigest::SHAがない場合のフォールバック） |
