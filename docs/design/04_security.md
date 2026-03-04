# LetterBBS ver2 — 詳細設計書: セキュリティ・エラーハンドリング設計

> **文書バージョン**: 1.0
> **作成日**: 2026-03-04

---

## 1. セキュリティ設計方針

### 1.1 脅威モデル

LetterBBS はインターネット上のレンタルサーバーで動作する公開CGIアプリケーションである。
想定する脅威と対策を以下に整理する。

| 脅威 | 重要度 | 対策 |
|------|--------|------|
| XSS（クロスサイトスクリプティング） | 高 | 全出力のHTMLエスケープ、CSP |
| CSRF（クロスサイトリクエストフォージェリ） | 高 | トークン検証、SameSite Cookie |
| SQLインジェクション | 高 | プレースホルダ（バインド変数）の徹底 |
| パストラバーサル | 中 | ファイル名サニタイズ、ホワイトリスト |
| ブルートフォース（パスワード総当り） | 中 | アカウントロック、レート制限 |
| ファイルアップロード攻撃 | 中 | MIMEタイプ検証、マジックバイト確認 |
| セッションハイジャック | 中 | HttpOnly Cookie、IP検証 |
| DoS（サービス拒否） | 低 | 連続投稿制限、リクエストサイズ制限 |

### 1.2 防御の階層

```
1. 入力層:    Sanitize.pm — 全入力のバリデーション・サニタイズ
2. 認証層:    Auth.pm / Session.pm — セッション管理・CSRF検証
3. データ層:  Database.pm — プレースホルダによるSQL実行
4. 出力層:    Template.pm — 自動HTMLエスケープ
5. 通信層:    Cookie属性（HttpOnly, SameSite）、CSPヘッダー
```

---

## 2. XSS対策

### 2.1 テンプレートの自動エスケープ

Template.pm の `<!-- var:name -->` は**自動的にHTMLエスケープ**を適用する。
エスケープなしで出力する場合は `<!-- raw:name -->` を明示的に使用する。

```perl
# Template.pm 内部
sub _escape_html {
    my ($str) = @_;
    $str =~ s/&/&amp;/g;
    $str =~ s/</&lt;/g;
    $str =~ s/>/&gt;/g;
    $str =~ s/"/&quot;/g;
    $str =~ s/'/&#x27;/g;
    return $str;
}
```

**raw の使用を許可するケース**:
- サーバー側で安全に生成したHTML（ページネーションボタン等）
- `nl2br()` 処理済みの本文（改行を `<br>` に変換した後）
- `autolink()` 処理済みの本文（URLを `<a>` タグに変換した後）

### 2.2 autolink の安全な実装

URLの自動リンク化で `javascript:` スキームを排除する。

```perl
sub autolink {
    my ($str) = @_;
    # https:// と http:// のみリンク化（javascript: 等は排除）
    $str =~ s{(https?://[^\s<>"']+)}{<a href="$1" target="_blank" rel="noopener noreferrer">$1</a>}g;
    return $str;
}
```

### 2.3 CSP（Content Security Policy）ヘッダー

```
Content-Security-Policy: default-src 'self'; script-src 'self'; style-src 'self' https://fonts.googleapis.com; font-src 'self' https://fonts.gstatic.com; img-src 'self' data:; frame-ancestors 'none';
```

---

## 3. CSRF対策

### 3.1 CSRFトークン

全てのPOSTフォームにCSRFトークンを埋め込み、サーバー側で検証する。

**トークン生成**:
```perl
# Auth.pm
sub generate_token {
    my ($session_id) = @_;
    my $secret = $config->get('csrf_secret') || 'default_secret_change_me';
    my $time = int(time() / 3600);  # 1時間単位
    return substr(sha256_hex("$secret:$session_id:$time"), 0, 32);
}
```

**フォームへの埋め込み**:
```html
<form method="POST" action="patio.cgi?action=post">
    <input type="hidden" name="csrf_token" value="<!-- var:csrf_token -->">
    ...
</form>
```

**検証**:
```perl
sub verify_token {
    my ($token, $session_id) = @_;
    # 現在のトークンと1つ前のトークン（1時間前）を許可
    my $current = generate_token($session_id);
    my $previous = generate_token_for_time($session_id, time() - 3600);
    return ($token eq $current || $token eq $previous);
}
```

### 3.2 SameSite Cookie

セッションクッキーに `SameSite=Lax` を設定し、
外部サイトからのPOSTリクエストにクッキーが送信されないようにする。

### 3.3 API のCSRF対策

API（api.cgi）はセッションクッキーで認証するため、以下の追加対策を実施：
- `X-Requested-With: XMLHttpRequest` ヘッダーの検証
- Referer チェック（同一オリジンのみ許可）

---

## 4. SQLインジェクション対策

### 4.1 プレースホルダの徹底

全SQLクエリでプレースホルダ（`?`）を使用し、ユーザー入力を直接SQL文に埋め込まない。

```perl
# 正しい例
my $sth = $dbh->prepare("SELECT * FROM threads WHERE id = ?");
$sth->execute($thread_id);

# 絶対にやってはいけない例
# my $sth = $dbh->prepare("SELECT * FROM threads WHERE id = $thread_id");
```

### 4.2 入力値の型チェック

数値パラメータは事前に整数変換する：
```perl
my $id = int($cgi->param('id') || 0);
my $page = int($cgi->param('page') || 1);
```

---

## 5. パスワード管理

### 5.1 管理者パスワード

| 項目 | 仕様 |
|------|------|
| ハッシュアルゴリズム | SHA-256 |
| ソルト | ランダム16バイト（hex 32文字） |
| 保存形式 | `$sha256${salt}${hash}` |
| ロック条件 | N回連続失敗（設定値: max_failpass） |
| ロック期間 | 設定値: lock_days 日 |
| 初期アカウント | login_id: admin / password: password |

### 5.2 投稿パスワード（記事編集/削除用）

| 項目 | 仕様 |
|------|------|
| ハッシュアルゴリズム | SHA-256（管理者と同一方式に統一） |
| ソルト | ランダム16バイト |
| 保存場所 | posts テーブルの password カラム |

**ver1 との違い**:
- ver1: regist.cgi では crypt()、login.pl では SHA-256 と方式が混在
- ver2: 全てSHA-256に統一し、一貫したセキュリティレベルを確保

### 5.3 トリップ

ver1 互換のトリップ生成を維持する（ユーザーが同じトリップを使い続けられるように）。

```perl
# 名前#キー → 名前◆xxx
sub generate_trip {
    my ($name_with_key) = @_;
    if ($name_with_key =~ /^(.+)#(.+)$/) {
        my ($name, $key) = ($1, $2);
        my $salt = substr($key . 'H.', 1, 2);
        $salt =~ s/[^\.-z]/\./g;
        $salt =~ tr/:;<=>?@[\\]^_`/ABCDEFGabcdef/;
        my $trip = substr(crypt($key, $salt), -10);
        return ($name, $trip);
    }
    return ($name_with_key, '');
}
```

---

## 6. セッション管理

### 6.1 セッションID生成

```perl
sub _generate_session_id {
    my $random = '';
    for (1..32) {
        $random .= chr(int(rand(256)));
    }
    return sha256_hex($random . time() . $$ . rand());
}
```

### 6.2 セッション固定攻撃対策

- ログイン成功時にセッションIDを再生成（Session Fixation Prevention）
- 既存セッションを破棄し、新しいIDを発行

### 6.3 セッションの有効期限

- ユーザーセッション: ブラウザセッション（ブラウザ終了で消滅）
- 管理者セッション: authtime 分（デフォルト60分、アクセスで延長）
- DB上の有効期限: expires_at を超えたセッションは無効
- クリーンアップ: 1/100 の確率で期限切れセッションを一括削除

### 6.4 IP検証（オプション）

セッション作成時のIPアドレスと現在のIPが異なる場合、セッションを無効化する。
（プロキシ環境を考慮し、デフォルトは無効。init.cgi で有効化可能）

---

## 7. ファイルアップロードセキュリティ

### 7.1 バリデーションチェーンの順序

```
1. ファイルサイズチェック（max_upload_size 以下か）
2. 拡張子チェック（.jpg, .jpeg, .gif, .png のみ許可）
3. MIMEタイプチェック（Content-Type ヘッダー）
4. マジックバイト検証（ファイル先頭バイトを確認）
   - JPEG: FF D8 FF
   - GIF:  47 49 46 38 (GIF8)
   - PNG:  89 50 4E 47 (.PNG)
5. ファイル名サニタイズ（元のファイル名は使用しない）
6. 保存先ディレクトリの検証（パストラバーサル防止）
```

### 7.2 ファイル名の安全な生成

元のファイル名は使用せず、サーバー側で安全な名前を生成する：
```perl
my $filename = sprintf("%d_%d_%d.%s", $thread_id, $slot, time(), $ext);
```

### 7.3 アップロードディレクトリの保護

`upl/.htaccess`:
```apache
# CGI/PHP の実行を禁止（画像配信のみ許可）
<FilesMatch "\.(cgi|pl|php|py|rb)$">
    Deny from all
</FilesMatch>

# Content-Type を強制（MIME Sniffing 防止）
<IfModule mod_headers.c>
    Header set X-Content-Type-Options "nosniff"
</IfModule>
```

---

## 8. アクセス制御

### 8.1 ディレクトリ保護

| ディレクトリ | .htaccess 設定 |
|-------------|---------------|
| `data/` | `Deny from all`（外部アクセス完全拒否） |
| `lib/` | `Deny from all` |
| `tmpl/` | `Deny from all` |
| `upl/` | CGI実行禁止（画像配信のみ） |

### 8.2 管理画面の認証フロー

```
1. admin.cgi にアクセス
2. セッションクッキー確認
   ├─ 有効 → メニュー画面
   └─ 無効 → ログイン画面表示
3. ログインID + パスワード送信
4. AdminAuth::authenticate() でチェック
   ├─ ロック中 → "アカウントがロックされています"
   ├─ パスワード不一致 → fail_count+1, "パスワードが違います"
   │   └─ fail_count >= max_failpass → ロック設定
   └─ 成功 → セッション生成, メニューへリダイレクト
```

---

## 9. エラーハンドリング設計

### 9.1 エラー分類

| 分類 | 例 | 対応 |
|------|---|------|
| **入力エラー** | 必須項目未入力、不正な値 | ユーザーにメッセージ表示、フォームに戻す |
| **権限エラー** | パスワード不一致、ロック中スレッドへの投稿 | エラー画面表示 |
| **リソースエラー** | スレッドが見つからない、削除済み | エラー画面（404相当） |
| **システムエラー** | DB接続失敗、ファイル書き込み失敗 | ログ記録 + ユーザーに簡潔なエラー表示 |
| **セキュリティエラー** | CSRF検証失敗、不正リクエスト | ログ記録 + エラー画面 |

### 9.2 エラー表示の原則

- **ユーザー向け**: 具体的で親しみやすいメッセージ（技術用語を避ける）
- **ログ向け**: 完全なスタックトレースとパラメータ情報
- **システムエラー時**: 内部情報を漏洩させない（"内部エラーが発生しました" のみ表示）

### 9.3 エラーログ

CGI::Carp を使用してサーバーのエラーログに出力する。

```perl
use CGI::Carp qw(fatalsToBrowser);
# ※ 本番環境では fatalsToBrowser は無効化し、カスタムエラーページを表示

# カスタムエラーハンドラ
sub handle_error {
    my ($error_msg) = @_;
    warn "[LetterBBS ERROR] $error_msg";  # サーバーログ
    # ユーザーには一般的なエラーメッセージを表示
    show_error_page("内部エラーが発生しました。管理者にお問い合わせください。");
}
```

### 9.4 DB エラーのリカバリ

```perl
eval {
    $db->begin_transaction();
    # ... 処理 ...
    $db->commit();
};
if ($@) {
    $db->rollback();
    warn "[LetterBBS DB ERROR] $@";
    show_error_page("データの保存に失敗しました。もう一度お試しください。");
}
```

### 9.5 連続投稿制限（Flood Control）

```perl
# Model::Post::check_flood()
sub check_flood {
    my ($self, $host, $wait_seconds) = @_;
    my $row = $self->{db}->dbh->selectrow_hashref(
        "SELECT created_at FROM posts WHERE host = ? ORDER BY created_at DESC LIMIT 1",
        undef, $host
    );
    return 1 unless $row;  # 過去投稿なし → OK

    my $last_time = str2time($row->{created_at});
    my $elapsed = time() - $last_time;
    return ($elapsed >= $wait_seconds) ? 1 : 0;
}
```

---

## 10. HTTPヘッダーセキュリティ

CGI出力時に以下のセキュリティヘッダーを付与する：

```perl
sub print_security_headers {
    print "X-Content-Type-Options: nosniff\n";
    print "X-Frame-Options: DENY\n";
    print "X-XSS-Protection: 1; mode=block\n";
    print "Referrer-Policy: same-origin\n";
    print "Content-Security-Policy: default-src 'self'; "
        . "script-src 'self'; "
        . "style-src 'self' https://fonts.googleapis.com; "
        . "font-src 'self' https://fonts.gstatic.com; "
        . "img-src 'self' data:; "
        . "frame-ancestors 'none'\n";
}
```

| ヘッダー | 目的 |
|---------|------|
| `X-Content-Type-Options: nosniff` | MIME Sniffing 防止 |
| `X-Frame-Options: DENY` | Clickjacking 防止 |
| `X-XSS-Protection: 1; mode=block` | ブラウザのXSSフィルタ有効化 |
| `Referrer-Policy: same-origin` | 外部へのReferer漏洩防止 |
| `Content-Security-Policy` | XSS/データインジェクション防止 |
