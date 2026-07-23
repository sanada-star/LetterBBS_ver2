# Admin Management Fixes Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** ADM-13、ADM-15、ADM-16を既存管理画面との互換性を維持して修正する。

**Architecture:** `admin.cgi` の入力境界で同名パラメータを配列保持し、ControllerでIDを正規化して全件処理する。管理一覧は既存の `status` 引数とテンプレート条件分岐を使い、会員表示値はControllerで生成する。

**Tech Stack:** Perl 5、SQLite、独自テンプレート、Test::More

---

### Task 1: 管理CGIの複数値パラメータを保持する

**Files:**
- Modify: `patio/admin.cgi`
- Create: `t/admin_cgi_params.t`

- [ ] **Step 1: URLエンコードの失敗テストを書く**

`t/admin_cgi_params.t` に、`ids=1&ids=2&action=thread_exec` を実際のパーサー部分へ渡し、次を検証するテストを追加する。

```perl
is_deeply([ $cgi->param('ids') ], ['1', '2'], 'returns every duplicate value in list context');
is(scalar $cgi->param('ids'), '2', 'preserves the last value in scalar context');
is(scalar $cgi->param('action'), 'thread_exec', 'preserves ordinary scalar parameters');
```

テストでは `admin.cgi` をUTF-8で読み、`#--- 管理画面用CGIパラメータ取得 ---` から末尾までを抽出して一時Perlスクリプトへ書く。各ケースを別の子Perlプロセスで実行し、本番コードそのものを検証する。

- URLエンコード用子プロセスへ `REQUEST_METHOD=POST`、`CONTENT_TYPE=application/x-www-form-urlencoded`、本文バイト長の `CONTENT_LENGTH` を設定し、STDINへ本文を渡す。
- multipart用子プロセスへ `REQUEST_METHOD=POST`、boundary付き `CONTENT_TYPE`、本文バイト長の `CONTENT_LENGTH` を設定し、STDINへmultipart本文を渡す。
- `$_admin_parsed` のキャッシュを共有しないよう、URLエンコードとmultipartは必ず別プロセスにする。
- 子プロセスはリスト値とスカラー値をJSONでSTDOUTへ返し、親テストが `decode_json` して検証する。

- [ ] **Step 2: URLエンコードテストが期待どおり失敗することを確認する**

Run:

```powershell
& 'C:\Program Files\Git\usr\bin\perl.exe' t/admin_cgi_params.t
```

Expected: リスト取得が `['2']` となりFAIL。

- [ ] **Step 3: URLエンコードの同名値保持を最小実装する**

`patio/admin.cgi` に値追加用の内部関数を追加する。

```perl
sub _admin_store_param {
    my ($key, $value) = @_;
    if (exists $_admin_params{$key}) {
        my $current = $_admin_params{$key};
        $_admin_params{$key} = ref $current eq 'ARRAY'
            ? [@$current, $value]
            : [$current, $value];
    } else {
        $_admin_params{$key} = $value;
    }
}
```

URLエンコードとクエリ文字列の代入をすべて `_admin_store_param` に置き換える。`_admin_get_param` は文脈を保つ。

```perl
sub _admin_get_param {
    _admin_parse_params();
    my ($key) = @_;
    my $value = $_admin_params{$key};
    return wantarray
        ? (ref $value eq 'ARRAY' ? @$value : defined $value ? ($value) : ())
        : (ref $value eq 'ARRAY' ? $value->[-1] : $value);
}
```

`LetterBBS::AdminCGI::param` も `wantarray` を維持して `_admin_get_param` を呼ぶ。

- [ ] **Step 4: URLエンコードテストの成功を確認する**

Run: Task 1 Step 2と同じ。

Expected: PASS。

- [ ] **Step 5: multipartの失敗テストを書く**

同名フィールド `ids=3`、`ids=4` を含むmultipart本文を渡し、リスト取得が `['3', '4']`、スカラー取得が `'4'` となることを追加する。

- [ ] **Step 6: multipartテストが期待どおり失敗することを確認する**

Run: Task 1 Step 2と同じ。

Expected: multipartのリスト取得でFAIL。

- [ ] **Step 7: multipartの同名値保持を実装する**

multipartフィールドとmultipart時のクエリ文字列の代入も `_admin_store_param` に置き換える。

- [ ] **Step 8: パラメータ境界テストを成功させる**

Run: Task 1 Step 2と同じ。

Expected: 全テストPASS。

### Task 2: 管理Controllerの一覧・会員表示・複数操作を修正する

**Files:**
- Modify: `patio/lib/LetterBBS/Controller/Admin.pm`
- Modify: `patio/tmpl/admin/threads.html`
- Modify: `t/controller_admin.t`

- [ ] **Step 1: ADM-13の失敗テストを書く**

`thread_list` に `status=archived` と複数ページ相当の件数を渡し、テンプレート変数 `is_active`、`is_archived`、対象status、`pagination` を確認する。ページリンクが `action=threads&status=archived&page=2` を含むことも検証する。テンプレート静的検査で次を確認する。

```perl
like($template, qr/status=active/, 'links to active threads');
like($template, qr/status=archived/, 'links to archived threads');
like($template, qr/value="restore"/, 'provides restore action');
like($template, qr/name="status"/, 'submits the current status with bulk actions');
```

- [ ] **Step 2: ADM-13テストの失敗を確認する**

Run:

```powershell
& 'C:\Program Files\Git\usr\bin\perl.exe' t/controller_admin.t
```

Expected: 切替変数と復元UIがなくFAIL。

- [ ] **Step 3: ADM-15の失敗テストを書く**

会員モデルに次の既知値2件と未知値1件を返させ、表示用値を確認する。

```perl
[
    { id => 1, rank => 2, is_active => 1, created_at => '2026-07-23 10:11:12' },
    { id => 2, rank => 1, is_active => 0, created_at => '2026-07-22 09:08:07' },
]
```

期待値は「書込可／有効／2026/07/23 10:11」と「閲覧のみ／無効／2026/07/22 09:08」。
未知値 `{ rank => 9, is_active => 7 }` はそれぞれ文字列 `9`、`7` を表示し、未定義値は警告や例外を起こさず「未設定」と表示する。

- [ ] **Step 4: ADM-15テストの失敗を確認する**

Run: Task 2 Step 2と同じ。

Expected: 表示用3項目がなくFAIL。

- [ ] **Step 5: ADM-16の失敗テストを書く**

テスト用Threadモデルに `destroy`、`update`、`find` の呼び出し記録を追加する。`ids => [7, 8, 8, 'bad', 0]` を使い、削除、`toggle_lock`、archive、restoreの4操作が正規化済みID 7、8へ一度ずつ適用されることを個別subtestで検証する。`thread_id` 単一指定の互換性も検証する。

- [ ] **Step 6: ADM-16テストの失敗を確認する**

Run: Task 2 Step 2と同じ。

Expected: 重複・不正値の正規化または複数処理でFAIL。

- [ ] **Step 7: Controllerとテンプレートを最小実装する**

`thread_list` へ次の表示値とページングを追加する。

```perl
is_active   => $status eq 'active' ? 1 : 0,
is_archived => $status eq 'archived' ? 1 : 0,
```

`_admin_pagination` を追加し、ベースURLに `action=threads&status=$status` を含めたページリンクを生成して `pagination` へ渡す。

`threads.html` へ状態切替リンクを追加し、操作フォームへ `<input type="hidden" name="status" ...>` を追加する。`is_active` では既存3操作、`is_archived` では削除と復元を表示する。

`member_list` で各会員へ次を追加する。

```perl
$user->{rank_label}   = _admin_user_rank_label($user->{rank});
$user->{status_label} = _admin_user_status_label($user->{is_active});
$user->{display_date} = _format_date($user->{created_at});
```

`_admin_user_rank_label` は1/2を既知ラベル、それ以外は定義済みなら元値、未定義なら「未設定」で返す。`_admin_user_status_label` も0/1を既知ラベル、それ以外は同じ方針とする。

Controllerに正の整数の重複を除く `_admin_param_ids` を追加し、`ids` と `post_ids` に使用する。操作フォームの `status` を `active|archived` に正規化し、スレッド一覧操作後は `?action=threads&status=$status` へ戻す。テストではarchive後はactive、restore後はarchived一覧を維持することを確認する。

- [ ] **Step 8: Controllerテストを成功させる**

Run: Task 2 Step 2と同じ。

Expected: 全テストPASS。

### Task 3: 全回帰試験と品質確認

**Files:**
- Verify all modified files

- [ ] **Step 1: Perl全テストを実行する**

```powershell
$perl='C:\Program Files\Git\usr\bin\perl.exe'
Get-ChildItem 't\*.t' | ForEach-Object {
    & $perl $_.FullName
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
}
```

Expected: 全ファイルPASS。

- [ ] **Step 2: Node・Python回帰試験を実行する**

```powershell
node --test test\desk-ui.test.js test\acceptance-ui-regression.test.js
py -3 test\database-consistency.test.py
```

Expected: Node 12件、Python 7件がPASS。

- [ ] **Step 3: Perl構文確認を実行する**

```powershell
& 'C:\Program Files\Git\usr\bin\perl.exe' -Ipatio/lib -c patio/admin.cgi
& 'C:\Program Files\Git\usr\bin\perl.exe' -Ipatio/lib -c patio/lib/LetterBBS/Controller/Admin.pm
```

Expected: `syntax OK`。

- [ ] **Step 4: 日本語・差分確認を実行する**

```powershell
git diff --check
node -e "const fs=require('fs'); for (const f of process.argv.slice(1)) { const b=fs.readFileSync(f); const t=b.toString('utf8'); console.log(f,{bom:b[0]===0xef&&b[1]===0xbb&&b[2]===0xbf,replacement:t.includes('\ufffd')}); }" patio/admin.cgi patio/lib/LetterBBS/Controller/Admin.pm patio/tmpl/admin/threads.html t/controller_admin.t t/admin_cgi_params.t
```

Expected: whitespace error、BOM、U+FFFDなし。

- [ ] **Step 5: 変更をコミットする**

```powershell
git add patio/admin.cgi patio/lib/LetterBBS/Controller/Admin.pm patio/tmpl/admin/threads.html t/controller_admin.t t/admin_cgi_params.t
git commit -m "Fix remaining admin management issues"
```

- [ ] **Step 6: アップロード対象を提示する**

次の3ファイルを本番同等環境へアップロードする対象として提示する。

- `patio/admin.cgi`
- `patio/lib/LetterBBS/Controller/Admin.pm`
- `patio/tmpl/admin/threads.html`

- [ ] **Step 7: アップロード後に本番同等環境で再試験する**

ユーザーのアップロード完了後、専用データだけで次を実施する。

- ADM-13: 専用スレッドを過去ログ化し、「過去ログ」一覧へ切り替えて表示を確認後、「復元」で現行一覧へ戻ることを確認する。
- ADM-15: 専用会員を作成し、権限・状態・登録日が表示されることを確認後、削除する。
- ADM-16: 専用スレッド2件の両チェック済み状態を記録し、一括削除後に両方が一覧から消えることを確認する。

試験後は専用スレッド、専用会員、設定変更をすべて後片付けし、試験票へ結果を追記する。
