# LetterBBS ver2 — 詳細設計書: 全体概要

> **文書バージョン**: 1.0
> **作成日**: 2026-03-04
> **対象**: LetterBBS ver2（Perl CGI / SQLite）
> **前提知識**: Perl CGI の基本、リレーショナルDB の概念

---

## 1. プロジェクト概要

### 1.1 何をするプログラムか

**LetterBBS** は、キャラクター交流（PBC/PBW）に特化した **往復書簡型の掲示板 CGI** である。

ユーザーは「スレッド（手紙）」を立て、相手が返信することで1対1の手紙のやり取りを行う。
すべてのやり取りはオープン（他のユーザーも閲覧可能）だが、タイムライン表示により
特定の相手とのやり取りだけを抽出して表示できる。

### 1.2 ver2 の目的

- **文通デスク不具合**: タイムラインで自分のやり取りが反映されないバグ
- **セキュリティの不均一**: 暗号方式が crypt() と SHA256 で混在

ver2 では**機能を維持したまま**、設計からやり直し堅牢なプログラムに作り変える。

### 1.3 設計方針

| 項目 | 方針 |
|------|------|
| 言語 | Perl 5.x（CGI） |
| データストア | SQLite 3（DBD::SQLite） |
| 動作環境 | さくらのレンタルサーバ（スタンダード） |
| 文字コード | UTF-8 統一 |
| フロントエンド | Vanilla HTML5 + CSS3 + JavaScript（フレームワーク不使用） |
| テンプレートエンジン | 自前実装（`<!-- var:name -->` 形式） |
| セッション管理 | サーバー側ファイルセッション（自前実装） |
| 通知方式 | ポーリング（改善版） |
| 文通デスク | サーバー側保存 |

### 1.4 機能一覧（ver1 踏襲 + 改善）

| # | 機能名 | 説明 | ver1からの変更 |
|---|--------|------|---------------|
| F01 | スレッド一覧 | ページネーション付きスレッド一覧表示 | ページネーションロジック改善 |
| F02 | スレッド閲覧 | 親記事＋返信のスレッド表示 | — |
| F03 | タイムライン表示 | 特定相手とのやり取りを抽出表示 | **サーバー側で抽出**（バグ解消） |
| F04 | 新規投稿 | スレッド作成（件名・名前・本文・画像） | — |
| F05 | 返信投稿 | スレッドへの返信 | — |
| F06 | 記事編集 | パスワード認証後に本文編集 | — |
| F07 | 記事削除 | パスワード認証後に個別削除 | — |
| F08 | スレッドロック | スレッドへの返信を禁止 | — |
| F09 | 検索 | キーワードによるAND/OR検索 | SQLite FTS（全文検索）利用 |
| F10 | 過去ログ | 古いスレッドの閲覧 | SQLiteフラグ管理に変更 |
| F11 | 文通デスク | 複数返信の下書き→一括送信 | **サーバー側保存に変更** |
| F12 | 通知タスク | 自分宛て手紙の検知→ブラウザ通知 | ポーリング効率化 |
| F13 | メモリーボックス | スレッドのHTMLアーカイブDL | — |
| F14 | テーマ切替 | Pop/Gloomy/Simple/Fox | CSS変数ベース統一 |
| F15 | 画像アップロード | 最大3枚、サムネイル対応 | — |
| F16 | CAPTCHA | 画像認証（オプション） | — |
| F17 | 管理画面 | スレッド管理・会員管理・設定 | — |
| F18 | 会員認証 | ログイン制限（オプション） | — |
| F19 | トリップ | 名前#パスワード → ◆xxx | — |
| F20 | マニュアル表示 | 使い方ページ | — |

### 1.5 非目標（スコープ外）

- WebSocket / SSE によるリアルタイム通知（CGI環境では不可）
- SPA化（シングルページアプリケーション）
- 外部DB（MySQL/PostgreSQL）への対応
- 多言語対応

---

## 2. アーキテクチャ設計

### 2.1 全体構成図

```
┌─────────────────────────────────────────────────────┐
│  Browser (HTML5 + CSS3 + JavaScript)                │
│  ┌─────────┐  ┌──────────┐  ┌───────────────────┐  │
│  │ Theme   │  │ Desk UI  │  │ Notification      │  │
│  │ Manager │  │ (AJAX)   │  │ Poller (AJAX)     │  │
│  └─────────┘  └──────────┘  └───────────────────┘  │
└───────────┬─────────────────────────┬───────────────┘
            │  HTTP (CGI)             │
┌───────────▼─────────────────────────▼───────────────┐
│  CGI Layer (Perl)                                   │
│  ┌──────────────────────────────────────────────┐   │
│  │  Router (patio.cgi)                          │   │
│  │  URLパラメータ → アクション振り分け            │   │
│  └──────────┬───────────────────────────────────┘   │
│             │                                       │
│  ┌──────────▼───────────────────────────────────┐   │
│  │  Controller Layer                            │   │
│  │  ┌────────┐ ┌────────┐ ┌────────┐ ┌──────┐  │   │
│  │  │ Board  │ │ Thread │ │ Desk   │ │ Admin│  │   │
│  │  │ Ctrl   │ │ Ctrl   │ │ Ctrl   │ │ Ctrl │  │   │
│  │  └────┬───┘ └───┬────┘ └───┬────┘ └──┬───┘  │   │
│  └───────┼─────────┼──────────┼─────────┼──────┘   │
│          │         │          │         │           │
│  ┌───────▼─────────▼──────────▼─────────▼──────┐   │
│  │  Model Layer (lib/Model/*.pm)               │   │
│  │  ┌────────┐ ┌──────┐ ┌──────┐ ┌──────────┐  │   │
│  │  │ Thread │ │ Post │ │ User │ │ Draft    │  │   │
│  │  │ .pm    │ │ .pm  │ │ .pm  │ │ .pm      │  │   │
│  │  └────┬───┘ └──┬───┘ └──┬───┘ └────┬─────┘  │   │
│  └───────┼────────┼────────┼──────────┼────────┘   │
│          │        │        │          │             │
│  ┌───────▼────────▼────────▼──────────▼────────┐   │
│  │  Database Layer (lib/Database.pm)           │   │
│  │  SQLite via DBD::SQLite                     │   │
│  └─────────────────┬───────────────────────────┘   │
│                    │                                │
│  ┌─────────────────▼───────────────────────────┐   │
│  │  data/letterbbs.db (SQLite file)            │   │
│  └─────────────────────────────────────────────┘   │
│                                                     │
│  ┌─────────────────────────────────────────────┐   │
│  │  Utility Layer                              │   │
│  │  Config.pm | Template.pm | Session.pm       │   │
│  │  Auth.pm   | Upload.pm   | Captcha.pm       │   │
│  └─────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────┘
```

### 2.2 ディレクトリ構成

```
patio/                          ← ドキュメントルート配下
├── patio.cgi                   [705] メインエントリーポイント（ルーター）
├── admin.cgi                   [705] 管理画面エントリーポイント
├── captcha.cgi                 [705] CAPTCHA画像生成
├── api.cgi                     [705] API エンドポイント（通知/文通デスク用）
├── init.cgi                    [604] 設定ファイル
│
├── lib/                        ← Perlモジュール群（.htaccess でアクセス拒否）
│   ├── Database.pm             DB接続・マイグレーション
│   ├── Config.pm               設定値管理
│   ├── Router.pm               URLルーティング
│   ├── Template.pm             テンプレートエンジン
│   ├── Session.pm              セッション管理
│   ├── Auth.pm                 認証・パスワード処理
│   ├── Upload.pm               画像アップロード
│   ├── Captcha.pm              CAPTCHA生成・検証
│   ├── Sanitize.pm             入力サニタイズ
│   ├── Archive.pm              メモリーボックス（ZIP生成）
│   │
│   ├── Controller/
│   │   ├── Board.pm            スレッド一覧・検索
│   │   ├── Thread.pm           スレッド閲覧・投稿・編集・削除
│   │   ├── Desk.pm             文通デスク
│   │   ├── Notification.pm     通知API
│   │   ├── Admin.pm            管理画面
│   │   └── Page.pm             静的ページ（マニュアル・留意事項）
│   │
│   ├── Model/
│   │   ├── Thread.pm           スレッドモデル（CRUD）
│   │   ├── Post.pm             投稿モデル（CRUD）
│   │   ├── User.pm             ユーザーモデル（会員管理）
│   │   ├── Draft.pm            下書きモデル（文通デスク）
│   │   ├── Session.pm          セッションモデル
│   │   └── Setting.pm          管理設定モデル
│   │
│   ├── CGI/                    ← 外部ライブラリ（Minimal等、現行踏襲）
│   ├── Crypt/
│   └── Digest/
│
├── tmpl/                       ← HTMLテンプレート
│   ├── layout.html             共通レイアウト（ヘッダー/フッター）
│   ├── bbs.html                スレッド一覧
│   ├── read.html               スレッド閲覧
│   ├── form.html               投稿フォーム
│   ├── edit.html               編集フォーム
│   ├── find.html               検索
│   ├── past.html               過去ログ
│   ├── desk.html               文通デスク
│   ├── timeline.html           タイムライン表示
│   ├── manual.html             マニュアル
│   ├── note.html               留意事項
│   ├── enter.html              ログイン画面
│   ├── admin/                  管理画面テンプレート群
│   │   ├── menu.html
│   │   ├── threads.html
│   │   ├── members.html
│   │   ├── settings.html
│   │   └── design.html
│   ├── error.html              エラー表示
│   └── message.html            完了メッセージ
│
├── cmn/                        ← 静的リソース
│   ├── style.css               デフォルトテーマ (Pop)
│   ├── style_gloomy.css        Gloomy テーマ
│   ├── style_simple.css        Simple テーマ
│   ├── style_fox.css           Fox テーマ
│   ├── admin.css               管理画面CSS
│   ├── app.js                  統合JavaScript（v4ベース統一）
│   ├── *.gif / *.png           アイコン・画像素材
│   └── index.html              ディレクトリリスト防止
│
├── data/                       [707] データディレクトリ
│   ├── letterbbs.db            SQLite データベースファイル
│   ├── sessions/               [707] セッションファイル
│   ├── .htaccess               アクセス拒否
│   └── index.html              ディレクトリリスト防止
│
└── upl/                        [707] アップロード画像
    └── index.html              ディレクトリリスト防止
```

### 2.3 リクエスト処理フロー

```
HTTP Request
    │
    ▼
patio.cgi (エントリーポイント)
    │
    ├─ 1. Config.pm で設定読み込み
    ├─ 2. CGI::Minimal でリクエストパース
    ├─ 3. Session.pm でセッション検証
    ├─ 4. Router.pm でアクション判定
    │       │
    │       ├─ action=list     → Controller::Board::list()
    │       ├─ action=read     → Controller::Thread::read()
    │       ├─ action=post     → Controller::Thread::post()
    │       ├─ action=edit     → Controller::Thread::edit()
    │       ├─ action=delete   → Controller::Thread::delete()
    │       ├─ action=search   → Controller::Board::search()
    │       ├─ action=past     → Controller::Board::past()
    │       ├─ action=desk     → Controller::Desk::show()
    │       ├─ action=desk_*   → Controller::Desk::*()
    │       ├─ action=archive  → Controller::Thread::archive()
    │       ├─ action=manual   → Controller::Page::manual()
    │       └─ (default)       → Controller::Board::list()
    │
    ├─ 5. Controller が Model を呼び出しデータ取得/更新
    ├─ 6. Template.pm でテンプレート描画
    └─ 7. HTTP Response 出力

api.cgi (APIエントリーポイント)
    │
    ├─ 1. Config.pm / Session.pm
    ├─ 2. アクション判定
    │       ├─ api=threads     → JSON: スレッド一覧（通知用）
    │       ├─ api=timeline    → JSON: タイムライン取得
    │       ├─ api=desk_list   → JSON: 下書き一覧
    │       ├─ api=desk_save   → JSON: 下書き保存
    │       └─ api=desk_send   → JSON: 一括送信
    └─ 3. JSON Response 出力
```

### 2.4 レイヤー間の責務

| レイヤー | 責務 | やらないこと |
|---------|------|-------------|
| **CGI (patio.cgi, api.cgi)** | リクエスト受付、ルーティング | ビジネスロジック、DB操作 |
| **Controller** | リクエスト検証、Controller間の調整、レスポンス生成 | SQL発行、HTML生成 |
| **Model** | ビジネスロジック、データCRUD | HTTPヘッダー操作、テンプレート処理 |
| **Database** | SQLite接続管理、トランザクション | ビジネスルール判定 |
| **Template** | テンプレート読み込み、変数置換、ループ展開 | データ取得 |
| **Utility** | 横断的関心事（認証・サニタイズ・セッション等） | 特定機能のロジック |

---

## 3. 技術的判断事項

### 3.1 なぜ SQLite か

| 観点 | フラットファイル（現行） | SQLite（ver2） |
|------|----------------------|----------------|
| 同時書き込み | flock に依存、破損リスクあり | WAL モードで並行読み取り可能 |
| 検索性能 | 全ファイル走査 O(n) | インデックス利用 O(log n) |
| データ整合性 | アプリ側で保証（不完全） | トランザクション＋外部キーで保証 |
| バックアップ | 複数ファイルのコピー | 単一ファイルコピー |
| さくらでの利用 | ○ | ○（DBD::SQLite 利用可能） |

### 3.2 なぜ文通デスクをサーバー側保存にするか

- **現行バグの根本原因**: LocalStorage でタイムラインを構築する際、自分の投稿IDと相手のスレッドIDの紐付けがクライアント側では不完全
- **サーバー側保存の利点**: DBにドラフトテーブルを持つことで、タイムラインの構築もDB JOINで正確に行える
- **LocalStorage は補助として残す**: オフライン時のフォーム内容の一時保存用途

### 3.3 テンプレートエンジンの仕様

現行の `!placeholder!` 形式から、より明確な構文に変更する：

```html
<!-- var:title -->              → 変数置換（HTMLエスケープ済み）
<!-- raw:html_content -->       → 変数置換（エスケープなし、信頼できるデータのみ）
<!-- loop:items -->             → ループ開始
<!-- /loop:items -->            → ループ終了
<!-- if:condition -->           → 条件分岐
<!-- else -->                   → else
<!-- /if:condition -->          → 条件分岐終了
<!-- include:partial.html -->   → 部分テンプレート読み込み
```

---

## 4. 関連設計書

| 文書 | ファイル | 内容 |
|------|---------|------|
| データベース設計 | [01_database.md](01_database.md) | テーブル定義、インデックス、マイグレーション |
| モジュール設計 | [02_modules.md](02_modules.md) | 各Perlモジュールの詳細仕様 |
| API・画面設計 | [03_api_screens.md](03_api_screens.md) | URL設計、画面遷移、APIインターフェース |
| セキュリティ設計 | [04_security.md](04_security.md) | 認証・認可・入力検証・CSRF対策 |
| フロントエンド設計 | [05_frontend.md](05_frontend.md) | JavaScript・CSS・テンプレート詳細 |
| デプロイ・運用設計 | [06_deployment.md](06_deployment.md) | 設置手順・マイグレーション・バックアップ |
