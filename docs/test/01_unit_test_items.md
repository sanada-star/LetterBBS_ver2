# LetterBBS ver2 単体試験項目表

## 1. 目的

本書は `D:\9996_der\www\letterBBS_ver2` 全体を対象に、モジュール責務単位で実施する単体試験項目を整理したものです。  
対象は CGI エントリ、共通基盤、Model、Controller、テンプレート、および主要な設定切替の回帰確認です。

## 2. 前提

- テストはテスト用 SQLite DB、テスト用セッション、テスト用テンプレート入力で実施する
- 外部依存は可能な範囲でスタブ化し、モジュール単体の責務を検証する
- 本書の「単体試験」は画面全体の結合確認ではなく、各モジュールの入出力・分岐・副作用を確認する粒度とする
- 画像アップロード、セッション、ファイル出力はテスト用ディレクトリを用いる

## 3. 試験項目

### 3.1 エントリ CGI

| 試験ID | 対象 | 前提 | 操作 | 期待結果 |
|---|---|---|---|---|
| CGI-001 | `patio/patio.cgi` | 初期化可能な設定・DBあり | `mode=list` で起動 | `Router` に正しい mode が渡される |
| CGI-002 | `patio/patio.cgi` | `authkey=1`、未ログイン | `mode=read` で起動 | `enter` 画面へリダイレクトする |
| CGI-003 | `patio/patio.cgi` | multipart/form-data 入力あり | 投稿リクエストを渡す | 通常項目と upload 項目を正しく抽出できる |
| CGI-004 | `patio/patio.cgi` | 不正 mode | 起動 | エラーページを返す |
| CGI-005 | `patio/api.cgi` | API ルートあり | `api=threads` で起動 | JSON 応答を返す |
| CGI-006 | `patio/api.cgi` | 不正 api | 起動 | JSON エラーを返す |
| CGI-007 | `patio/admin.cgi` | 未ログイン | 管理画面へアクセス | ログイン画面または保護動線へ遷移する |
| CGI-008 | `patio/captcha.cgi` | CAPTCHA 設定あり | token なしで起動 | code/token を生成し画像応答する |
| CGI-009 | `patio/captcha.cgi` | 有効 token あり | `?token=...` で起動 | 同一コードを再描画する |
| CGI-010 | `patio/captcha.cgi` | 不正 token | `?token=broken` で起動 | `400 Bad Request` を返す |

### 3.2 基盤ユーティリティ

| 試験ID | 対象 | 前提 | 操作 | 期待結果 |
|---|---|---|---|---|
| BAS-001 | `Database.pm` | 空のテストDB | `new` → `initialize` | テーブル、初期設定、インデックスが作成される |
| BAS-002 | `Database.pm` | 初期化済DB | `begin_transaction` → 更新 → `commit` | 更新が確定する |
| BAS-003 | `Database.pm` | 初期化済DB | `begin_transaction` → 更新 → `rollback` | 更新が破棄される |
| BAS-004 | `Config.pm` | `init.cgi` 値と DB 設定値あり | `load_db_settings` | DB 設定が優先される |
| BAS-005 | `Config.pm` | `csrf_secret` 未設定 | `load_db_settings` | `csrf_secret` が自動補完される |
| BAS-006 | `Config.pm` | 設定変更対象あり | `set` / `get` | 更新値を取得できる |
| BAS-007 | `Router.pm` | controller をスタブ化 | `dispatch('read')` | `Thread::read` が呼ばれる |
| BAS-008 | `Router.pm` | 同上 | `dispatch_api('timeline')` | `Notification::timeline` が呼ばれる |
| BAS-009 | `Router.pm` | 同上 | `dispatch_admin('settings')` | `Admin::settings` が呼ばれる |
| BAS-010 | `Router.pm` | 不正ルート | dispatch 実行 | エラー応答になる |
| BAS-011 | `Template.pm` | テンプレート文字列あり | `var` / `raw` 展開 | 値展開とエスケープが正しい |
| BAS-012 | `Template.pm` | 条件値あり | `if` / `unless` / `else` 展開 | 分岐が正しい |
| BAS-013 | `Template.pm` | 配列データあり | `loop` 展開 | 繰返しと `_index` などが正しい |
| BAS-014 | `Template.pm` | include テンプレートあり | `include` 展開 | 部分テンプレートが読み込まれる |
| BAS-015 | `Session.pm` | セッションなし | `start` | 新規セッションIDと cookie を生成する |
| BAS-016 | `Session.pm` | 既存セッションあり | `start` | セッションデータを復元する |
| BAS-017 | `Session.pm` | セッションあり | `set` / `get` | 値を保持できる |
| BAS-018 | `Session.pm` | セッションあり | `destroy` | セッション破棄と失効 cookie を返す |
| BAS-019 | `Session.pm` | 期限切れデータあり | `cleanup` | 期限切れセッションを削除する |
| BAS-020 | `Auth.pm` | 平文パスワードあり | `hash_password` → `verify_password` | 正常一致する |
| BAS-021 | `Auth.pm` | 異なるパスワード | `verify_password` | 不一致になる |
| BAS-022 | `Auth.pm` | 名前とトリップキーあり | `generate_trip` | 名前と trip が期待どおり分離される |
| BAS-023 | `Auth.pm` | セッションIDと secret あり | CSRF generate/verify | 正常時に通る |
| BAS-024 | `Auth.pm` | 改ざん token | CSRF verify | 検証失敗になる |
| BAS-025 | `Sanitize.pm` | HTML 文字列あり | `html_escape` / `html_unescape` | 双方向変換が正しい |
| BAS-026 | `Sanitize.pm` | 改行文字列あり | `nl2br` | `<br>` に変換される |
| BAS-027 | `Sanitize.pm` | URL 含み文字列 | `autolink` | URL にリンクが付与される |
| BAS-028 | `Sanitize.pm` | 制御文字や空白あり | `sanitize_input` | 制御文字除去・trim が正しい |
| BAS-029 | `Sanitize.pm` | 不正ファイル名あり | `sanitize_filename` | 安全なファイル名に変換される |
| BAS-030 | `Captcha.pm` | `cap_len` 等設定あり | `generate` | 桁数・token・code が設定どおり生成される |
| BAS-031 | `Captcha.pm` | 正しい code/token | `verify` | `1` を返す |
| BAS-032 | `Captcha.pm` | 誤った code | `verify` | `-1` を返す |
| BAS-033 | `Captcha.pm` | 期限切れ token | `verify` | `0` を返す |
| BAS-034 | `Upload.pm` | 正常画像ファイルあり | `process` | 保存名、MIME、サイズ、寸法を返す |
| BAS-035 | `Upload.pm` | サイズ超過ファイルあり | `process` | エラーを返す |
| BAS-036 | `Upload.pm` | 不正 MIME ファイルあり | `process` | エラーを返す |
| BAS-037 | `Upload.pm` | 保存済画像あり | `delete_file` | ファイルが削除される |
| BAS-038 | `Upload.pm` | サムネイル有効 | `make_thumbnail` | サムネイルを生成する |
| BAS-039 | `Archive.pm` | スレッド・投稿・画像あり | `generate` | HTML/ZIP を正しく生成する |

### 3.3 Model

| 試験ID | 対象 | 前提 | 操作 | 期待結果 |
|---|---|---|---|---|
| MOD-001 | `Model/Thread.pm` | 空DB | `create` | スレッドが作成され ID を返す |
| MOD-002 | `Model/Thread.pm` | スレッドあり | `find` | 対象スレッドを取得できる |
| MOD-003 | `Model/Thread.pm` | スレッドあり | `update` | 指定項目が更新される |
| MOD-004 | `Model/Thread.pm` | active/archived 混在 | `list` | status・ページング・並び順が正しい |
| MOD-005 | `Model/Thread.pm` | 古い active スレッドあり | `archive_old` | 指定条件で archived 化される |
| MOD-006 | `Model/Thread.pm` | 古い archived スレッドあり | `purge_old` | 指定条件で物理削除される |
| MOD-007 | `Model/Thread.pm` | スレッドあり | `increment_access_count` | 閲覧数が 1 増える |
| MOD-008 | `Model/Post.pm` | スレッドあり | 親投稿 `create` | 親投稿が作成される |
| MOD-009 | `Model/Post.pm` | スレッドあり | 返信 `create` | 返信投稿が作成される |
| MOD-010 | `Model/Post.pm` | 親・返信あり | `list_by_thread` | 親と返信が正しく返る |
| MOD-011 | `Model/Post.pm` | seq 採番済投稿あり | `find_by_thread_seq` | 指定投稿を取得できる |
| MOD-012 | `Model/Post.pm` | 投稿あり | `update` | 件名・本文が更新される |
| MOD-013 | `Model/Post.pm` | 投稿あり | `soft_delete` | 論理削除状態になる |
| MOD-014 | `Model/Post.pm` | 投稿履歴あり | `check_flood` | wait 秒以内は拒否、経過後は許可 |
| MOD-015 | `Model/Post.pm` | 投稿画像あり | `add_image` / `get_images` | 画像情報を保存・取得できる |
| MOD-016 | `Model/Post.pm` | 投稿画像あり | `delete_image` | 指定画像を削除できる |
| MOD-017 | `Model/Draft.pm` | 下書きなし | `create` | 下書きが作成される |
| MOD-018 | `Model/Draft.pm` | 下書きあり | `update` / `list` / `delete` | CRUD が正しく動作する |
| MOD-019 | `Model/User.pm` | 会員なし | `create` | 会員を追加できる |
| MOD-020 | `Model/User.pm` | 会員あり | `list` / `delete` | 一覧取得と削除が正しい |
| MOD-021 | `Model/AdminAuth.pm` | 管理者あり | `authenticate` | 正常ログインできる |
| MOD-022 | `Model/AdminAuth.pm` | 誤パスワード | `authenticate` | 失敗回数や拒否が正しい |
| MOD-023 | `Model/AdminAuth.pm` | 管理者あり | `change_password` | 旧PW確認後に更新される |
| MOD-024 | `Model/Setting.pm` | 設定あり | `get` / `set` | 単体更新できる |
| MOD-025 | `Model/Setting.pm` | 複数設定あり | `set_bulk` / `get_all` | 一括更新と全件取得が正しい |

### 3.4 Controller

| 試験ID | 対象 | 前提 | 操作 | 期待結果 |
|---|---|---|---|---|
| CTR-001 | `Controller::Board::list` | active スレッド複数あり | 一覧表示 | active のみ、ページング付きで描画する |
| CTR-002 | `Controller::Board::search` | 検索対象あり | keyword + AND/OR | 検索結果件数・並びが正しい |
| CTR-003 | `Controller::Board::past` | archived あり | 過去ログ表示 | archived のみ表示する |
| CTR-004 | `Controller::Thread::read` | 親・返信・画像あり | 詳細表示 | 本文、画像、閲覧数、返信フォームを描画する |
| CTR-005 | `Controller::Thread::form` | 新規投稿 | `mode=form` | 新規投稿フォームを表示する |
| CTR-006 | `Controller::Thread::form` | 返信対象あり | `id` 指定 | 返信フォームを表示する |
| CTR-007 | `Controller::Thread::form` | 引用対象あり | `quote` 指定 | 引用本文を初期表示する |
| CTR-008 | `Controller::Thread::form` | `image_upl=1` | フォーム表示 | 添付欄を表示する |
| CTR-009 | `Controller::Thread::form` | `use_captcha=1` | フォーム表示 | CAPTCHA UI と token を表示する |
| CTR-010 | `Controller::Thread::form` | `use_captcha=0` | フォーム表示 | CAPTCHA を表示しない |
| CTR-011 | `Controller::Thread::post` | 新規投稿正常系 | 必須項目を POST | thread/post 作成後に詳細へ遷移する |
| CTR-012 | `Controller::Thread::post` | 返信正常系 | `thread_id` 付き POST | reply 作成後に詳細へ遷移する |
| CTR-013 | `Controller::Thread::post` | CSRF 不正 | POST | エラー画面になる |
| CTR-014 | `Controller::Thread::post` | 名前欠落 | POST | エラー画面になる |
| CTR-015 | `Controller::Thread::post` | 本文欠落 | POST | エラー画面になる |
| CTR-016 | `Controller::Thread::post` | 新規投稿で件名欠落 | POST | エラー画面になる |
| CTR-017 | `Controller::Thread::post` | flood 条件成立 | 短時間連投 | 投稿拒否される |
| CTR-018 | `Controller::Thread::post` | lock 済スレッド | 返信 POST | 投稿拒否される |
| CTR-019 | `Controller::Thread::post` | `m_max` 到達 | 返信 POST | 投稿拒否される |
| CTR-020 | `Controller::Thread::post` | `use_captcha=1` 正答 | POST | 投稿成功する |
| CTR-021 | `Controller::Thread::post` | `use_captcha=1` 誤答 | POST | 同一フォームにエラー表示で再入力になる |
| CTR-022 | `Controller::Thread::post` | `use_captcha=1` 期限切れ | POST | 同一フォームに期限切れ表示で再入力になる |
| CTR-023 | `Controller::Thread::post` | `use_captcha=0` | POST | CAPTCHA なしで成功する |
| CTR-024 | `Controller::Thread::post` | `image_upl=1` | 画像付き投稿 | 画像保存と `has_image` 更新を行う |
| CTR-025 | `Controller::Thread::edit_form` | 正しい投稿PW | 編集画面表示 | 件名・名前・本文・画像初期値を表示する |
| CTR-026 | `Controller::Thread::edit_exec` | 正しい投稿PW | 件名・本文更新 | 更新結果が反映される |
| CTR-027 | `Controller::Thread::edit_exec` | 画像削除チェックあり | 更新 | 指定画像のみ削除される |
| CTR-028 | `Controller::Thread::delete` | 返信投稿あり | 削除実行 | 対象返信のみ削除される |
| CTR-029 | `Controller::Thread::delete` | 親投稿あり | 削除実行 | スレッド全体が削除扱いになる |
| CTR-030 | `Controller::Thread::archive` | スレッドあり | ダウンロード実行 | HTML ダウンロードを返す |
| CTR-031 | `Controller::Desk::show` | 下書きあり | 表示 | 下書き一覧と関連スレッド情報を描画する |
| CTR-032 | `Controller::Desk::api_list` | 下書きあり | API 呼出 | 下書き JSON 一覧を返す |
| CTR-033 | `Controller::Desk::api_save` | 新規下書き | API 呼出 | `draft_id` を返して保存する |
| CTR-034 | `Controller::Desk::api_save` | 既存下書き | 更新 API 呼出 | 下書き内容が更新される |
| CTR-035 | `Controller::Desk::api_delete` | 下書きあり | API 呼出 | 対象下書きを削除する |
| CTR-036 | `Controller::Desk::api_send` | 複数下書きあり | API 呼出 | posts 作成、threads 更新、drafts 削除を行う |
| CTR-037 | `Controller::Notification::thread_list` | 更新スレッドあり | `since` 指定 | 差分スレッド JSON を返す |
| CTR-038 | `Controller::Notification::timeline` | 対話履歴あり | API 呼出 | `sent/received` 付き JSON を返す |
| CTR-039 | `Controller::Page::enter` | `authkey=1` | 表示 | ログイン画面を描画する |
| CTR-040 | `Controller::Page::login` | 会員あり | 正しい資格情報で POST | ログイン成功しセッションを設定する |
| CTR-041 | `Controller::Page::login` | 会員あり | 誤資格情報で POST | ログイン失敗を表示する |
| CTR-042 | `Controller::Page::logout` | ログイン済 | 実行 | セッション破棄して遷移する |
| CTR-043 | `Controller::Admin::login` | 管理者あり | 正しい資格情報で POST | 管理ログイン成功する |
| CTR-044 | `Controller::Admin::logout` | 管理ログイン済 | 実行 | 管理セッションが破棄される |
| CTR-045 | `Controller::Admin::thread_list` | 管理ログイン済 | 一覧表示 | スレッド管理一覧を表示する |
| CTR-046 | `Controller::Admin::thread_exec` | 管理ログイン済 | delete/lock/archive 等実行 | 対象操作が反映される |
| CTR-047 | `Controller::Admin::member_list` | 管理ログイン済 | 一覧表示 | 会員一覧を表示する |
| CTR-048 | `Controller::Admin::member_exec` | 管理ログイン済 | 会員追加/削除 | 操作結果が反映される |
| CTR-049 | `Controller::Admin::settings` | 管理ログイン済 | 表示 | 実設定値に一致する状態で描画する |
| CTR-050 | `Controller::Admin::settings_exec` | 管理ログイン済 | 設定保存 | DB 保存後に画面表示状態も一致する |
| CTR-051 | `Controller::Admin::password_exec` | 管理ログイン済 | PW変更 | 旧PW確認後に新PWへ変更される |
| CTR-052 | `Controller::Admin::design_exec` | 管理ログイン済 | テーマ変更 | テーマ設定が反映される |
| CTR-053 | `Controller::Admin::size_check` | 管理ログイン済 | 表示 | DB/Upl サイズを正しく算出する |

### 3.5 テンプレート・画面単位

| 試験ID | 対象 | 前提 | 操作 | 期待結果 |
|---|---|---|---|---|
| TMP-001 | `tmpl/bbs.html` | スレッド一覧データあり | 描画 | NEW/IMG/LOCK、リンク、ページャが正しい |
| TMP-002 | `tmpl/read.html` | 親・返信・画像あり | 描画 | 投稿一覧、返信導線、編集/削除導線が正しい |
| TMP-003 | `tmpl/form.html` | `image_upl=1` | 描画 | 添付欄を表示する |
| TMP-004 | `tmpl/form.html` | `use_captcha=1` | 描画 | CAPTCHA UI、hidden token、エラー表示が正しい |
| TMP-005 | `tmpl/form.html` | `use_captcha=0` | 描画 | CAPTCHA 要素を出さない |
| TMP-006 | `tmpl/edit.html` | 投稿・画像あり | 描画 | 初期値と画像削除チェックを表示する |
| TMP-007 | `tmpl/admin/settings.html` | 各設定値あり | 描画 | `image_upl/authkey/use_captcha` の選択状態が一致する |
| TMP-008 | `tmpl/error.html` | エラー文言あり | 描画 | タイトル、本文、戻り先が正しい |
| TMP-009 | `tmpl/layout.html` | 共通変数あり | 描画 | ヘッダ、ナビ、フッタ、共通JSが埋め込まれる |

### 3.6 回帰確認

| 試験ID | 対象 | 前提 | 操作 | 期待結果 |
|---|---|---|---|---|
| REG-001 | `image_upl` 切替 | `0/1` の両設定 | フォーム表示・投稿・編集 | 添付機能の有無が設定どおり |
| REG-002 | `authkey` 切替 | `0/1` の両設定 | 未ログインアクセス | 公開/制限が設定どおり |
| REG-003 | `use_captcha` 切替 | `0/1` の両設定 | フォーム表示・投稿 | CAPTCHA 有無が設定どおり |
| REG-004 | 親記事削除修正 | 親+返信あり | 親投稿削除 | スレッド全体削除が維持される |
| REG-005 | 編集初期値修正 | 既存投稿あり | 編集画面表示 | 件名・名前・本文が表示される |
| REG-006 | 管理画面パスワード変更修正 | 管理者あり | PW変更後ログイン | 新パスワードでログインできる |
| REG-007 | 編集画像削除修正 | 添付画像あり | 編集更新 | 指定画像だけ削除される |
| REG-008 | `image_upl/authkey` 表示修正 | 設定保存済 | 管理画面再表示 | 実設定と表示状態が一致する |
| REG-009 | 会員ログイン修正 | 会員あり | `login_pwd` でログイン | 正常認証される |

## 4. 備考

- 本項目表は現行設計書とソース構成に基づく初版です
- 実テスト実装時は、各項目に `入力値`, `期待レスポンス`, `DB期待値`, `副作用ファイル` を追加してください
- Controller 系は CGI 出力の文字列比較だけでなく、Model 呼出と DB 反映まで確認する形が望ましいです
