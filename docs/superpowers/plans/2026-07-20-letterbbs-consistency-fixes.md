# LetterBBS Consistency Fixes Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 新着返信、管理記事一覧、一括送信パスワード、編集・削除後のスレッド活動情報を、既存設計を維持しながら整合させる。

**Architecture:** 既存のモデル・コントローラ・テンプレート・JavaScriptの境界を維持し、表示用データは各コントローラで平坦化する。投稿削除後の集計はSQLiteトリガーをスキーマバージョン2へ更新して一元化し、既存DBもバックフィルする。自動テストがないため、Perlのコア `Test::More` と偽DB/偽コントローラ依存、Nodeの組み込みテスト、Python標準のSQLiteを使う最小回帰テストを追加する。

**Tech Stack:** Perl 5、CGI、SQLite、JavaScript、`Test::More`、Node.js `node:test`、Python 3 `sqlite3`

---

## File Map

- Create: `t/model_post.t` — 返信順序と編集時のSQL境界を検証する。
- Create: `t/controller_admin.t` — 管理詳細用変数と安全な返信削除を検証する。
- Create: `t/controller_desk.t` — デスク表示用下書きと共通パスワード保存を検証する。
- Create: `test/desk-ui.test.js` — デスク2画面から入力パスワードがAPIへ渡ることを検証する。
- Create: `test/database-consistency.test.py` — 本番SQLトリガーとv2バックフィルのSQLite実挙動を検証する。
- Create: `t/database_initialize.t` — DBIスタブで新規DB/v1 DBのマイグレーション順序と最終バージョンを検証する。
- Modify: `patio/lib/LetterBBS/Model/Post.pm` — 返信を降順取得する。
- Modify: `patio/lib/LetterBBS/Controller/Admin.pm` — 詳細表示データ整形と安全な返信削除を行う。
- Modify: `patio/tmpl/admin/thread_detail.html` — 親記事・削除済み記事を削除対象外にする。
- Modify: `patio/lib/LetterBBS/Controller/Desk.pm` — デスク専用ページへ下書き一覧を渡す。
- Modify: `patio/cmn/app.js` — 2つのデスク入口で共通パスワードを送る。
- Modify: `patio/tmpl/read.html` — インラインデスクパネルへパスワード欄を追加する。
- Modify: `patio/lib/LetterBBS/Database.pm` — v2マイグレーション、削除トリガー、既存データ補正を追加する。
- Preserve: `patio/lib/LetterBBS/Controller/Thread.pm` — ユーザーの未コミット親記事削除変更を保持し、回帰確認だけ行う。

## Task 1: 返信を新しい順にページングする

**Files:**
- Create: `t/model_post.t`
- Modify: `patio/lib/LetterBBS/Model/Post.pm:35-59`

- [ ] **Step 1: 失敗する返信順序テストを書く**

`t/model_post.t` に偽DBと偽DBHを定義し、`list_by_thread(7, page => 1, per_page => 10)` が発行する返信SQLを捕捉する。

```perl
use strict;
use warnings;
use Test::More;
use lib 'patio/lib';
use LetterBBS::Model::Post;

{
    package Local::PostDBH;
    sub new { bless { reply_sql => '' }, shift }
    sub selectrow_hashref { return { id => 1, thread_id => 7, seq_no => 0 } }
    sub selectall_arrayref {
        my ($self, $sql) = @_;
        $self->{reply_sql} = $sql;
        return [];
    }
}
{
    package Local::PostDB;
    sub new { bless { dbh => Local::PostDBH->new }, shift }
    sub dbh { $_[0]->{dbh} }
}

my $db = Local::PostDB->new;
LetterBBS::Model::Post->new($db)->list_by_thread(7, page => 1, per_page => 10);
like($db->dbh->{reply_sql}, qr/ORDER BY seq_no DESC/, 'page 1 selects newest replies first');
done_testing;
```

- [ ] **Step 2: テストが期待どおり失敗することを確認する**

Run: `wsl bash -lc "cd /mnt/d/0040_Aniti/letterBBS_ver2 && perl -Ipatio/lib t/model_post.t"`

Expected: `ASC` のため `page 1 selects newest replies first` がFAILする。

- [ ] **Step 3: 最小の実装を行う**

`Post.pm` の返信SQLだけを変更する。

```perl
ORDER BY seq_no DESC LIMIT ? OFFSET ?
```

- [ ] **Step 4: テストを再実行する**

Run: `wsl bash -lc "cd /mnt/d/0040_Aniti/letterBBS_ver2 && perl -Ipatio/lib t/model_post.t"`

Expected: PASS。

- [ ] **Step 5: 変更をコミットする**

```bash
git add t/model_post.t patio/lib/LetterBBS/Model/Post.pm
git commit -m "fix: show newest thread replies first"
```

## Task 2: 管理画面のスレッド詳細を表示する

**Files:**
- Create: `t/controller_admin.t`
- Modify: `patio/lib/LetterBBS/Controller/Admin.pm:114-212`
- Modify: `patio/tmpl/admin/thread_detail.html:18-63`

- [ ] **Step 1: 詳細表示用変数の失敗テストを書く**

偽セッション、CGI、モデル、テンプレートを使って `thread_detail` を呼び、テンプレートへ渡された値を検証する。最低限、次を期待する。

```perl
is($rendered->{thread_id}, 7, 'thread id is flattened');
is($rendered->{thread_subject}, '件名', 'subject is flattened');
is($rendered->{thread_author}, '親', 'author is flattened');
is($rendered->{status_label}, '公開中', 'status has a display label');
is(scalar @{$rendered->{posts}}, 3, 'parent and replies are combined');
is($rendered->{posts}[0]{can_delete}, 0, 'parent cannot be individually deleted');
is($rendered->{posts}[1]{can_delete}, 1, 'active reply can be deleted');
is($rendered->{posts}[2]{can_delete}, 0, 'deleted reply cannot be deleted again');
like($rendered->{posts}[1]{body_excerpt}, qr/^返信本文/, 'excerpt is prepared');
```

偽テンプレートの `render` は引数を保存して空文字を返す。標準出力はローカルスカラーへ捕捉し、CGIヘッダーがテスト出力へ混ざらないようにする。

- [ ] **Step 2: 詳細表示テストが期待どおり失敗することを確認する**

Run: `wsl bash -lc "cd /mnt/d/0040_Aniti/letterBBS_ver2 && perl -Ipatio/lib t/controller_admin.t"`

Expected: 現行実装には平坦な変数と `posts` がなくFAILする。

- [ ] **Step 3: コントローラで表示用データを整形する**

`thread_detail` で親記事と返信を結合し、各投稿を次の規則で整形する。

```perl
my @posts = grep { defined $_ } ($parent, @$replies);
for my $post (@posts) {
    $post->{display_date} = _format_date($post->{created_at});
    $post->{body_excerpt} = LetterBBS::Sanitize::truncate(
        LetterBBS::Sanitize::strip_tags($post->{body}), 100
    );
    $post->{can_delete} = ($post->{seq_no} > 0 && !$post->{is_deleted}) ? 1 : 0;
}
```

テンプレートへ `thread_id`、`thread_subject`、`thread_author`、`status_label`、`post_count`、`posts` を渡す。状態表示は内部ヘルパーで `active => 公開中`、`archived => 過去ログ`、`deleted => 削除済み` とし、未知値は元の値を返す。

- [ ] **Step 4: テンプレートの削除チェックボックスを条件化する**

`thread_detail.html` のチェックボックスを `can_delete` 条件内だけに表示する。

```html
<td>
  <!-- if:can_delete -->
  <input type="checkbox" name="post_ids" value="<!-- var:id -->">
  <!-- /if:can_delete -->
</td>
```

- [ ] **Step 5: 表示テストを再実行する**

Run: `wsl bash -lc "cd /mnt/d/0040_Aniti/letterBBS_ver2 && perl -Ipatio/lib t/controller_admin.t"`

Expected: 詳細表示に関するテストがPASSする。

- [ ] **Step 6: 安全な個別削除の失敗テストを追加する**

同じテストへ `thread_exec` のケースを追加する。CSRFトークンは `LetterBBS::Auth::generate_csrf_token` で生成する。

```perl
# 同一スレッドの未削除返信だけが soft_delete される
is_deeply($post_model->{deleted}, [12], 'only active reply in requested thread is deleted');
is($post_model->{delete_args}[0]{upl_dir}, 'upl', 'upload directory is passed');
like($output, qr/action=thread_detail&id=7/, 'redirects back to detail');

# 親記事、削除済み記事、別スレッド記事は削除されない
```

- [ ] **Step 7: 削除テストが期待どおり失敗することを確認する**

Run: `wsl bash -lc "cd /mnt/d/0040_Aniti/letterBBS_ver2 && perl -Ipatio/lib t/controller_admin.t"`

Expected: 現行実装が所属・親記事・削除済み状態を確認せず、画像保存先を渡さず、一覧へ戻るためFAILする。

- [ ] **Step 8: 削除処理を最小修正する**

`delete_posts` 分岐で `post_m->find($clean_id)` を呼び、次をすべて満たす投稿だけを削除する。

```perl
next unless $post;
next unless $post->{thread_id} == $id;
next unless $post->{seq_no} > 0;
next if $post->{is_deleted};
$self->{post_m}->soft_delete($clean_id, $self->{config}->get('upl_dir'));
```

`delete_posts` のときだけリダイレクト先を `?action=thread_detail&id=$id` とし、それ以外の操作は従来どおり `?action=threads` とする。

- [ ] **Step 9: 管理画面テストを再実行する**

Run: `wsl bash -lc "cd /mnt/d/0040_Aniti/letterBBS_ver2 && perl -Ipatio/lib t/controller_admin.t"`

Expected: 全テストPASS。

- [ ] **Step 10: 変更をコミットする**

```bash
git add t/controller_admin.t patio/lib/LetterBBS/Controller/Admin.pm patio/tmpl/admin/thread_detail.html
git commit -m "fix: restore admin thread article management"
```

## Task 3: 文通デスク専用ページへ下書きを表示する

**Files:**
- Create: `t/controller_desk.t`
- Modify: `patio/lib/LetterBBS/Controller/Desk.pm:31-57`

- [ ] **Step 1: デスク表示の失敗テストを書く**

偽セッションが所有する2件の下書きを `draft_m->list_by_session` から返し、偽テンプレートへ渡された値を検証する。

```perl
is($vars->{draft_count}, 2, 'draft count is rendered');
is($vars->{drafts}[0]{draft_id}, 21, 'draft id alias is rendered');
is($vars->{drafts}[0]{draft_subject}, '下書き件名', 'draft subject alias is rendered');
is($vars->{drafts}[0]{draft_body}, '本文', 'draft body alias is rendered');
like($vars->{drafts}[0]{display_date}, qr{^2026/07/20 12:34$}, 'date is formatted');
```

- [ ] **Step 2: テストが期待どおり失敗することを確認する**

Run: `wsl bash -lc "cd /mnt/d/0040_Aniti/letterBBS_ver2 && perl -Ipatio/lib t/controller_desk.t"`

Expected: 現行 `show` が下書きを取得・描画しないためFAILする。

- [ ] **Step 3: `Desk::show` へ下書き表示データを追加する**

セッションIDで下書きを取得し、既存テンプレート名に合わせて別名を追加する。元の `id`、`subject`、`body` は変更しない。

```perl
my $drafts = $self->{draft_m}->list_by_session($self->{session}->id());
for my $draft (@$drafts) {
    $draft->{draft_id}      = $draft->{id};
    $draft->{draft_subject} = $draft->{subject};
    $draft->{draft_body}    = $draft->{body};
    $draft->{display_date}  = _format_date($draft->{updated_at});
}
```

テンプレートへ `drafts => $drafts` と `draft_count => scalar @$drafts` を渡し、`Admin.pm` と同じ分単位の日時整形ヘルパーをファイル内へ追加する。

- [ ] **Step 4: デスク表示テストを再実行する**

Run: `wsl bash -lc "cd /mnt/d/0040_Aniti/letterBBS_ver2 && perl -Ipatio/lib t/controller_desk.t"`

Expected: PASS。

- [ ] **Step 5: 共通パスワード保存の回帰テストを追加する**

`api_send` に2件の同一セッション下書きと平文 `edit-pass` を渡し、偽投稿モデルが受けた2つの `password` が同一ハッシュで、平文ではなく、どちらも検証可能であることを確認する。

```perl
is($created->[0]{password}, $created->[1]{password}, 'one hash is shared by the batch');
isnt($created->[0]{password}, 'edit-pass', 'plain password is not stored');
ok(LetterBBS::Auth::verify_password('edit-pass', $created->[0]{password}), 'stored hash verifies');
```

現行APIはこの動作を既に備えるため、このテストは最初からPASSしてよい。これはサーバー側仕様を固定する特性テストとして扱う。

- [ ] **Step 6: 変更をコミットする**

```bash
git add t/controller_desk.t patio/lib/LetterBBS/Controller/Desk.pm
git commit -m "fix: render saved drafts on desk page"
```

## Task 4: デスクの両入口から共通パスワードを送信する

**Files:**
- Create: `test/desk-ui.test.js`
- Modify: `patio/cmn/app.js:333-355`
- Modify: `patio/tmpl/read.html:270-292`
- Verify unchanged field: `patio/tmpl/desk.html:71-80`

- [ ] **Step 1: JSをDOMスタブ上で読み込むテストヘルパーを書く**

Nodeの `vm` で `app.js` を評価する。`document.addEventListener` はコールバックを保存するだけにして自動初期化を走らせず、`window.confirm`、`document.getElementById`、`fetch` など必要最小限をスタブする。

```javascript
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');

function loadApp(elements = {}) {
  let reloadCount = 0;
  const document = {
    addEventListener() {},
    getElementById(id) { return elements[id] || null; },
    querySelector() { return null; },
    createElement() {
      return {
        className: '',
        textContent: '',
        classList: { add() {}, remove() {} },
        remove() {},
      };
    },
    cookie: '',
    body: { classList: { add() {}, remove() {} }, appendChild() {} },
  };
  const window = {
    document,
    confirm: () => true,
    LB_CONFIG: {},
    location: { reload() { reloadCount += 1; } },
  };
  const context = {
    window,
    document,
    fetch: async () => {},
    requestAnimationFrame(callback) { callback(); },
    setTimeout(callback) { callback(); return 0; },
    clearTimeout() {},
    console,
  };
  vm.runInNewContext(fs.readFileSync('patio/cmn/app.js', 'utf8'), context);
  return { lb: window.LetterBBS, reloadCount: () => reloadCount };
}
```

- [ ] **Step 2: 2つの入口の失敗テストを書く**

`LB.API.sendDrafts` を記録用関数へ差し替え、`sendAll` と `sendAllFromDesk` がそれぞれ対応する入力値を渡すことを期待する。

```javascript
test('panel batch send forwards its password', async () => {
  const { lb } = loadApp({ 'desk-panel-password': { value: 'panel-pass' } });
  lb.Desk.drafts = [{ id: 1 }, { id: 2 }];
  let args;
  let refreshed = 0;
  lb.API.sendDrafts = (ids, password) => { args = [ids, password]; return Promise.resolve({ posted: 2 }); };
  lb.Desk.refreshPanel = () => { refreshed += 1; };
  lb.Desk.sendAll();
  await Promise.resolve();
  assert.deepEqual(args, ['1,2', 'panel-pass']);
  assert.equal(refreshed, 1);
});

test('desk page batch send forwards its password', async () => {
  const app = loadApp({ 'desk-password': { value: 'desk-pass' } });
  const lb = app.lb;
  lb.Desk.drafts = [{ id: 1 }, { id: 2 }];
  let args;
  lb.API.sendDrafts = (ids, password) => { args = [ids, password]; return Promise.resolve({ posted: 2 }); };
  lb.Desk.sendAllFromDesk();
  await Promise.resolve();
  assert.deepEqual(args, ['1,2', 'desk-pass']);
  assert.equal(app.reloadCount(), 1);
});
```

- [ ] **Step 3: JSテストが期待どおり失敗することを確認する**

Run: `node --test test/desk-ui.test.js`

Expected: `sendAll` が空文字を渡し、`sendAllFromDesk` が未定義のためFAILする。

- [ ] **Step 4: 共通送信処理と2つの入口を実装する**

既存の送信本体を `_sendAllWithPassword(password)` へ移し、入口はDOMから値を読むだけにする。

```javascript
sendAll: function () {
  var input = document.getElementById('desk-panel-password');
  this._sendAllWithPassword(input ? input.value : '', false);
},

sendAllFromDesk: function () {
  var input = document.getElementById('desk-password');
  this._sendAllWithPassword(input ? input.value : '', true);
},

_sendAllWithPassword: function (password, reloadPage) {
  // 既存の空チェック、確認、ID連結を維持
  LB.API.sendDrafts(ids, password).then(function (result) {
    LB.UI.showToast(result.posted + '件の返信を送信しました');
    if (reloadPage) {
      window.location.reload();
    } else {
      LB.Desk.refreshPanel();
    }
  }).catch(function (err) {
    LB.UI.showToast('送信エラー: ' + err.message, 'error');
  });
},
```

- [ ] **Step 5: インラインパネルへパスワード欄を追加する**

`read.html` のデスクヘッダー内へ、既存デスクページと同じ最大8文字の任意入力を追加する。

```html
<label for="desk-panel-password">パスワード（一括）</label>
<input type="password" id="desk-panel-password" maxlength="8" placeholder="編集/削除用">
```

既存ボタンの `LB.Desk.sendAll()` 呼び出しは維持する。`desk.html` の既存 `#desk-password` は変更しない。

- [ ] **Step 6: JSテストと構文確認を実行する**

Run: `node --test test/desk-ui.test.js`

Expected: 2テストPASS。

Run: `node --check patio/cmn/app.js`

Expected: exit 0、出力なし。

- [ ] **Step 7: 変更をコミットする**

```bash
git add test/desk-ui.test.js patio/cmn/app.js patio/tmpl/read.html
git commit -m "fix: send desk batch password from both views"
```

## Task 5: 削除後のスレッド活動情報を再計算する

**Files:**
- Create: `test/database-consistency.test.py`
- Create: `t/database_initialize.t`
- Modify: `patio/lib/LetterBBS/Database.pm:67-103,262-317`

- [ ] **Step 1: 本番トリガーSQLを使う失敗テストを書く**

Pythonテストは `Database.pm` から `trg_post_count_delete` の `CREATE TRIGGER` 文字列を正規表現で抽出し、インメモリSQLiteへそのまま適用する。最小の `threads`、`posts` テーブルと親記事・返信2件を作る。

```python
class DeleteTriggerTest(unittest.TestCase):
    def test_deleting_latest_reply_restores_previous_activity(self):
        self.db.execute('UPDATE posts SET is_deleted = 1 WHERE id = 3')
        row = self.db.execute(
            'SELECT post_count, last_author, updated_at FROM threads WHERE id = 1'
        ).fetchone()
        self.assertEqual(row, (1, 'old reply', '2026-07-19 10:00:00'))

    def test_deleting_non_latest_reply_keeps_latest_activity(self):
        # post_countだけ減り、最新返信の投稿者・投稿日時を維持

    def test_deleting_last_reply_restores_parent_activity(self):
        # post_count=0、親投稿者・親投稿日へ戻る
```

抽出に失敗した場合はテストをスキップせずFAILさせ、本番SQLを検証していない状態を見逃さない。

- [ ] **Step 2: トリガーテストが期待どおり失敗することを確認する**

Run: `wsl bash -lc "cd /mnt/d/0040_Aniti/letterBBS_ver2 && python3 -m unittest test/database-consistency.test.py -v"`

Expected: 現行トリガーが削除投稿者を残し、削除時刻を設定するためFAILする。

- [ ] **Step 3: v2マイグレーションと削除トリガーを実装する**

`initialize` は新規DB作成後もローカルの `$version` を1へ更新し、そのままv2を適用する。

```perl
if ($version == 0) {
    # 既存の初期化
    $self->_set_schema_version(1);
    $version = 1;
}
if ($version < 2) {
    $self->_migrate_v2();
}
```

`_migrate_v2` はトランザクション内で旧トリガーを削除し、共通ヘルパー `_create_post_count_delete_trigger` で新定義を作成し、アクティブスレッドをバックフィルする。同じトランザクション内で `_set_schema_version(2)` を実行してからコミットし、失敗時はロールバックして再throwする。これにより、トリガー・バックフィルだけが反映されてバージョン記録が失敗する中間状態を作らない。

```perl
sub _migrate_v2 {
    my ($self) = @_;
    $self->begin_transaction();
    eval {
        $self->dbh->do('DROP TRIGGER IF EXISTS trg_post_count_delete');
        $self->_create_post_count_delete_trigger();
        $self->dbh->do($backfill_sql);
        $self->_set_schema_version(2);
        $self->commit();
    };
    if ($@) {
        my $error = $@;
        $self->rollback();
        die $error;
    }
}
```

新トリガーの更新式は次の形にする。

```sql
UPDATE threads SET
    post_count = (
        SELECT COUNT(*) FROM posts
        WHERE thread_id = new.thread_id AND seq_no > 0 AND is_deleted = 0
    ),
    last_author = COALESCE((
        SELECT author FROM posts
        WHERE thread_id = new.thread_id AND is_deleted = 0
        ORDER BY seq_no DESC LIMIT 1
    ), author),
    updated_at = COALESCE((
        SELECT created_at FROM posts
        WHERE thread_id = new.thread_id AND is_deleted = 0
        ORDER BY seq_no DESC LIMIT 1
    ), created_at)
WHERE id = new.thread_id;
```

`_create_triggers` からも同じヘルパーを呼び、新規DBと既存DBで定義を重複させない。

バックフィルは同じ相関サブクエリを使い、`WHERE status = 'active'` のスレッドだけを補正する。

- [ ] **Step 4: トリガーテストを再実行する**

Run: `wsl bash -lc "cd /mnt/d/0040_Aniti/letterBBS_ver2 && python3 -m unittest test/database-consistency.test.py -v"`

Expected: 3つの削除ケースがPASSする。

- [ ] **Step 5: v1バックフィルと新規DBバージョンのテストを追加する**

`Database.pm` からv2バックフィルSQLを抽出して、意図的に不整合なアクティブスレッドへ適用する。`post_count`、`last_author`、`updated_at` が最新の非削除記事へ揃うことを期待する。

`t/database_initialize.t` を必ず追加する。DBIがない環境でもロードできるよう、コンパイル前に最小スタブを登録する。

```perl
BEGIN {
    package DBI;
    our $errstr = '';
    sub import {}
    $INC{'DBI.pm'} = __FILE__;
}
use lib 'patio/lib';
use LetterBBS::Database;
```

偽DBHは `selectrow_array`、`do`、`prepare`、`begin_work`、`commit`、`rollback` を実装し、SQL、バインド値、トランザクションイベントを記録する。`prepare` は偽ステートメントを返し、その `execute` はデフォルト設定のバインド値を記録して真を返す。これにより、新規DB経路の `_insert_defaults()` まで省略せず実行する。

```perl
sub prepare {
    my ($self, $sql) = @_;
    push @{$self->{events}}, ['prepare', $sql];
    return bless { owner => $self, sql => $sql }, 'Local::Statement';
}

package Local::Statement;
sub execute {
    my ($self, @bind) = @_;
    push @{$self->{owner}{events}}, ['execute', $self->{sql}, @bind];
    return 1;
}
```

次の3ケースを独立して実行する。

```perl
subtest 'new database finishes at schema version 2' => sub {
    # sqlite_masterの存在確認は0を返す
    # initialize後、schema_versionのバインド値が1, 2の順
    # 最後のイベントがversion 2記録後のcommit
};

subtest 'version 1 database migrates atomically to version 2' => sub {
    # sqlite_master存在確認=1、MAX(version)=1
    # DROP旧トリガー、CREATE新トリガー、backfill、version 2記録、commitの順
    # 新規DB経路とv1経路で最後に作成された削除トリガーSQLが同一
};

subtest 'failed version recording rolls back migration' => sub {
    # version 2 INSERTで偽DBHがdieし、rollbackが記録されcommitされない
};
```

Run: `wsl bash -lc "cd /mnt/d/0040_Aniti/letterBBS_ver2 && perl -Ipatio/lib t/database_initialize.t"`

Expected: 新規DB・v1 DB・失敗時ロールバックの全ケースがPASSする。

- [ ] **Step 6: 編集時にスレッド活動情報を変えない回帰テストを追加する**

`t/model_post.t` の偽DBHで `Post::update` が発行するSQLを捕捉し、`UPDATE posts` のみで `UPDATE threads` を含まないことを確認する。

```perl
unlike(join("\n", @{$dbh->{do_sql}}), qr/UPDATE\s+threads/i,
    'editing a post does not bump thread activity');
```

- [ ] **Step 7: DB関連テストを再実行する**

Run: `wsl bash -lc "cd /mnt/d/0040_Aniti/letterBBS_ver2 && perl -Ipatio/lib t/model_post.t"`

Expected: PASS。

Run: `wsl bash -lc "cd /mnt/d/0040_Aniti/letterBBS_ver2 && python3 -m unittest test/database-consistency.test.py -v"`

Expected: 全テストPASS。

Run: `wsl bash -lc "cd /mnt/d/0040_Aniti/letterBBS_ver2 && perl -Ipatio/lib t/database_initialize.t"`

Expected: 全テストPASS。

- [ ] **Step 8: 変更をコミットする**

```bash
git add test/database-consistency.test.py t/database_initialize.t t/model_post.t patio/lib/LetterBBS/Database.pm
git commit -m "fix: recalculate thread activity after post deletion"
```

## Task 6: 全体回帰・文字コード・既存変更を確認する

**Files:**
- Verify: all files changed in Tasks 1-5
- Preserve: `patio/lib/LetterBBS/Controller/Thread.pm`

- [ ] **Step 1: Perl回帰テストをまとめて実行する**

Run: `wsl bash -lc "cd /mnt/d/0040_Aniti/letterBBS_ver2 && prove -Ipatio/lib -v t"`

Expected: 全テストPASS、失敗0。

- [ ] **Step 2: JavaScriptテストと構文確認を実行する**

Run: `node --test test/desk-ui.test.js`

Expected: 全テストPASS。

Run: `node --check patio/cmn/app.js`

Expected: exit 0。

- [ ] **Step 3: SQLite回帰テストを実行する**

Run: `wsl bash -lc "cd /mnt/d/0040_Aniti/letterBBS_ver2 && python3 -m unittest test/database-consistency.test.py -v"`

Expected: 全テストPASS。

- [ ] **Step 4: 関連Perlファイルの構文を確認する**

Run:

```bash
wsl bash -lc "cd /mnt/d/0040_Aniti/letterBBS_ver2 && perl -Ipatio/lib -c patio/lib/LetterBBS/Model/Post.pm && perl -Ipatio/lib -c patio/lib/LetterBBS/Controller/Admin.pm && perl -Ipatio/lib -c patio/lib/LetterBBS/Controller/Desk.pm && perl -Ipatio/lib -c patio/lib/LetterBBS/Controller/Thread.pm"
```

Expected: 各ファイル `syntax OK`。

`Database.pm` はWSLにDBIがないため通常の `perl -c` が実行できない。DBIスタブを使う構文確認を行うか、DBI導入がユーザーに承認された場合のみ実DBIで確認する。この制約を最終報告へ明記する。

- [ ] **Step 5: 日本語ファイルのUTF-8と差分を確認する**

対象ファイルごとに `git diff --check`、`iconv -f UTF-8 -t UTF-8`、先頭3バイト確認を実行する。BOMなし、置換文字なし、引用符・テンプレートコメントが閉じていることを確認する。

Run:

```bash
wsl bash -lc "cd /mnt/d/0040_Aniti/letterBBS_ver2 && git diff --check -- patio/lib/LetterBBS/Model/Post.pm patio/lib/LetterBBS/Controller/Admin.pm patio/lib/LetterBBS/Controller/Desk.pm patio/lib/LetterBBS/Database.pm patio/tmpl/admin/thread_detail.html patio/tmpl/read.html patio/cmn/app.js"
```

Expected: 出力なし、exit 0。

- [ ] **Step 6: 既存ユーザー変更が保持されていることを確認する**

Run: `git diff -- patio/lib/LetterBBS/Controller/Thread.pm`

Expected: 親記事の場合に `thread_m->delete($thread_id)` を呼ぶ既存の未コミット差分が残り、今回の作業による追加差分がない。

- [ ] **Step 7: 最終差分を要件ごとに照合する**

`git diff --stat` と各対象ファイルの差分を読み、次をチェックする。

- 新着返信が1ページ目に来る。
- 管理詳細に記事が表示され、安全に返信だけを削除できる。
- デスクの両入口で共通パスワードを送れる。
- 編集でスレッドが上がらない。
- 削除済み最新投稿者・削除時刻がトップへ残らない。
- 無関係な整形、依存関係更新、既存変更の上書きがない。

- [ ] **Step 8: 必要なら最終テスト調整だけをコミットする**

```bash
git add t test
git commit -m "test: cover LetterBBS consistency fixes"
```

変更がすべて各タスクのコミットに含まれている場合、この空コミットは作成しない。
