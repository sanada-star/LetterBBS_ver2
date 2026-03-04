# LetterBBS ver2

LetterBBS は、キャラクター交流（PBC/PBW）に特化した **往復書簡型の掲示板 CGI** です。
ユーザーは「スレッド（手紙）」を立て、相手が返信することで1対1の手紙のやり取りを行います。すべてのやり取りはオープンですが、特定の相手とのやり取りだけを抽出表示するタイムライン機能を備えています。

ver2 は、ver1 の機能を維持しつつ、データ破損リスクの低減やセキュリティ強化を目的として、SQLite 3（DBD::SQLite）をベースに堅牢に再設計されたバージョンです。

## 特徴

- **堅牢なデータ管理**: フラットファイルから SQLite 3（WALモード）への移行によるパフォーマンス向上とデータ破損の防止。
- **タイムライン機能**: 文通デスクでのやり取りをチャット風（タイムライン）で表示。
- **多彩なテーマ機能**: CSS変数をベースに、Pop, Gloomy, Fox, Simple の4種類のテーマを一瞬で切り替え可能。
- **モバイルファーストUI**: スマートフォンからでも快適に閲覧・投稿が可能。
- **強固なセキュリティ**: XSS、CSRF、SQLインジェクション対策、パスワードの安全なハッシュ化（SHA-256）。

## 動作環境要件

- さくらのレンタルサーバ スタンダードプラン以上
- Perl 5.14 以上（5.32 推奨）
- SQLite 3.x（DBD::SQLite）
- Apache（.htaccess対応）

### 必須 Perl モジュール（さくら標準）

- `DBI`, `DBD::SQLite`, `JSON::PP`, `Digest::SHA`, `Encode`, `POSIX`, `File::Copy`

## ディレクトリ構造

```text
.
├── docs/       # 詳細設計書 (GitHub Wiki / Pages 用途)
│   └── design/ # 各種仕様書 (Overview, Security, Frontend 等)
├── patio/      # アプリケーションルート
│   ├── lib/    # Perl モジュール群 (MVC構成)
│   ├── tmpl/   # HTML テンプレート群
│   ├── cmn/    # CSS, JavaScript, 画像リソース
│   ├── data/   # SQLite データベース等 (Git管理除外)
│   └── upl/    # ユーザーアップロード画像 (Git管理除外)
```

## 設置手順

1. リポジトリをクローンまたはダウンロードします。
2. `patio/init.cgi.sample` をコピーして `patio/init.cgi` を作成し、環境に合わせて設定（ディレクトリパス、URL、CSRFシークレットなど）を行います。
3. `patio/` ディレクトリ配下をサーバーにアップロードします。
4. 以下のパーミッションを設定します。
   - `*.cgi`: `705`
   - `patio/data/`, `patio/data/sessions/`, `patio/upl/`: `707`
   - `patio/init.cgi`: `604`
5. ブラウザから `patio.cgi` にアクセスすると、自動的にデータベース（`letterbbs.db`）が生成され、初期設定が行われます。
6. `admin.cgi` にアクセスし、デフォルトの管理者パスワードを変更してください。

> 詳細な設計書や仕様については、`docs/design/` ディレクトリ内のドキュメントを参照してください。

## ライセンス

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.
