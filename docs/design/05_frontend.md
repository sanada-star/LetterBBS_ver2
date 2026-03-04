# LetterBBS ver2 — 詳細設計書: フロントエンド設計

> **文書バージョン**: 1.0
> **作成日**: 2026-03-04

---

## 1. 設計方針

- **フレームワーク不使用**: Vanilla HTML5 + CSS3 + JavaScript
- **モバイルファースト**: Flexbox / CSS Grid によるレスポンシブデザイン
- **JS統一**: 現行の bbs.js / bbs_v3.js / bbs_v4.js を1ファイル `app.js` に統合
- **テーマ**: CSS変数（`:root`）ベースでテーマ切替を実現
- **アクセシビリティ**: セマンティックHTML、ARIA属性、キーボード操作対応

---

## 2. JavaScript 設計（app.js）

### 2.1 モジュール構成

app.js は即時実行関数（IIFE）パターンで名前空間を管理する。
（ES Modulesはレンタルサーバー環境でのMIMEタイプ設定の問題を避けるため不使用）

```javascript
/**
 * LetterBBS Client Application
 */
(function(window, document) {
    'use strict';

    const LB = window.LetterBBS = {};

    // --- モジュール ---
    LB.Config    = { ... };  // 設定値
    LB.API       = { ... };  // サーバーAPI通信
    LB.Desk      = { ... };  // 文通デスク機能
    LB.Notify    = { ... };  // 通知タスク機能
    LB.Timeline  = { ... };  // タイムライン表示
    LB.Form      = { ... };  // フォーム操作
    LB.UI        = { ... };  // UI共通処理

    // --- 初期化 ---
    document.addEventListener('DOMContentLoaded', function() {
        LB.UI.init();
        LB.Form.init();
        // ページ固有の初期化はdata属性で判定
        if (document.querySelector('[data-page="desk"]')) {
            LB.Desk.init();
        }
        if (document.querySelector('[data-notify]')) {
            LB.Notify.init();
        }
    });

})(window, document);
```

### 2.2 LB.Config — 設定モジュール

```javascript
LB.Config = {
    apiUrl: './api.cgi',
    pollInterval: {
        idle: 60000,        // 未読なし: 60秒
        active: 30000,      // 未読あり: 30秒
        focused: 15000      // デスク表示中: 15秒
    },
    autoSaveInterval: 10000, // 下書き自動保存: 10秒
    maxDraftAge: 7 * 24 * 3600 * 1000  // 下書き最大保持: 7日
};
```

### 2.3 LB.API — サーバーAPI通信

```javascript
LB.API = {
    /**
     * APIリクエスト送信
     * @param {string} api - API名
     * @param {Object} params - パラメータ
     * @param {string} method - 'GET' or 'POST'
     * @returns {Promise<Object>} JSONレスポンス
     */
    request: function(api, params, method) {
        method = method || 'GET';
        var url = LB.Config.apiUrl + '?api=' + api;

        var options = {
            method: method,
            headers: {
                'X-Requested-With': 'XMLHttpRequest'
            }
        };

        if (method === 'GET' && params) {
            var qs = Object.keys(params).map(function(k) {
                return encodeURIComponent(k) + '=' + encodeURIComponent(params[k]);
            }).join('&');
            url += '&' + qs;
        } else if (method === 'POST' && params) {
            options.headers['Content-Type'] = 'application/x-www-form-urlencoded';
            options.body = Object.keys(params).map(function(k) {
                return encodeURIComponent(k) + '=' + encodeURIComponent(params[k]);
            }).join('&');
        }

        return fetch(url, options)
            .then(function(res) { return res.json(); })
            .then(function(data) {
                if (!data.success) {
                    throw new Error(data.error || '不明なエラー');
                }
                return data;
            });
    },

    // 便利メソッド
    getThreads: function(since) {
        return this.request('threads', since ? { since: since } : null);
    },
    getTimeline: function(myName, partnerName) {
        return this.request('timeline', { my_name: myName, partner_name: partnerName });
    },
    getDrafts: function() {
        return this.request('desk_list');
    },
    saveDraft: function(data) {
        return this.request('desk_save', data, 'POST');
    },
    deleteDraft: function(draftId) {
        return this.request('desk_delete', { draft_id: draftId }, 'POST');
    },
    sendDrafts: function(draftIds, password) {
        return this.request('desk_send', { draft_ids: draftIds, password: password }, 'POST');
    }
};
```

### 2.4 LB.Desk — 文通デスク

```javascript
LB.Desk = {
    drafts: [],
    autoSaveTimer: null,

    init: function() {
        this.loadDrafts();
        this.bindEvents();
        this.startAutoSave();
    },

    loadDrafts: function() {
        // サーバーから下書き一覧取得
        LB.API.getDrafts().then(function(data) {
            LB.Desk.drafts = data.drafts;
            LB.Desk.render();
            // 各下書きのタイムラインを読み込み
            data.drafts.forEach(function(draft) {
                LB.Desk.loadTimeline(draft);
            });
        });
    },

    loadTimeline: function(draft) {
        // 自分の名前と相手の名前からタイムラインを取得
        var myName = draft.author;
        var partnerName = (draft.thread_author === myName)
            ? draft.last_reply_author  // 自分のスレッド → 相手は返信者
            : draft.thread_author;     // 相手のスレッド → 相手はスレ主

        if (!partnerName) return;

        LB.API.getTimeline(myName, partnerName).then(function(data) {
            LB.Timeline.render(draft.thread_id, data.posts);
        });
    },

    saveDraft: function(draftId) {
        // フォームの現在値を取得してサーバーに保存
        var form = document.querySelector('[data-draft-id="' + draftId + '"]');
        if (!form) return;

        var data = {
            draft_id: draftId,
            thread_id: form.querySelector('[name="thread_id"]').value,
            author: form.querySelector('[name="author"]').value,
            subject: form.querySelector('[name="subject"]').value,
            body: form.querySelector('[name="body"]').value
        };

        LB.API.saveDraft(data).then(function(result) {
            LB.UI.showToast('下書きを保存しました');
        });
    },

    sendAll: function() {
        var ids = this.drafts.map(function(d) { return d.id; }).join(',');
        var password = document.querySelector('#desk-password').value;

        LB.API.sendDrafts(ids, password).then(function(result) {
            LB.UI.showToast(result.posted + '件の返信を送信しました');
            LB.Desk.loadDrafts();  // 再読み込み
        }).catch(function(err) {
            LB.UI.showToast('送信エラー: ' + err.message, 'error');
        });
    },

    startAutoSave: function() {
        this.autoSaveTimer = setInterval(function() {
            LB.Desk.drafts.forEach(function(draft) {
                LB.Desk.saveDraft(draft.id);
            });
        }, LB.Config.autoSaveInterval);
    },

    render: function() { /* DOM更新処理 */ },
    bindEvents: function() { /* イベントリスナー登録 */ }
};
```

### 2.5 LB.Notify — 通知タスク

```javascript
LB.Notify = {
    watchName: '',          // 監視する名前
    lastCheck: null,        // 最終チェック時刻（サーバー時刻）
    tasks: [],              // 未読タスクリスト
    pollTimer: null,

    init: function() {
        // LocalStorageから設定復元
        this.watchName = localStorage.getItem('lb_notify_name') || '';
        this.tasks = JSON.parse(localStorage.getItem('lb_notify_tasks') || '[]');

        if (this.watchName) {
            this.startPolling();
            this.renderBadge();
        }

        this.bindEvents();
    },

    setup: function(name) {
        this.watchName = name;
        localStorage.setItem('lb_notify_name', name);
        this.tasks = [];
        this.lastCheck = null;
        this.startPolling();
    },

    startPolling: function() {
        if (this.pollTimer) clearInterval(this.pollTimer);

        var interval = this.tasks.length > 0
            ? LB.Config.pollInterval.active
            : LB.Config.pollInterval.idle;

        this.poll();  // 即時実行
        this.pollTimer = setInterval(function() {
            LB.Notify.poll();
        }, interval);
    },

    poll: function() {
        var params = {};
        if (this.lastCheck) {
            params.since = this.lastCheck;
        }

        LB.API.getThreads(this.lastCheck).then(function(data) {
            LB.Notify.lastCheck = data.server_time;

            // 自分宛の新着をチェック
            data.threads.forEach(function(thread) {
                if (thread.last_author !== LB.Notify.watchName &&
                    (thread.author === LB.Notify.watchName ||
                     LB.Notify.isRelated(thread))) {
                    LB.Notify.addTask(thread);
                }
            });

            LB.Notify.renderBadge();
            LB.Notify.saveToStorage();
        });
    },

    addTask: function(thread) {
        // 重複チェック
        var exists = this.tasks.some(function(t) {
            return t.thread_id === thread.id;
        });
        if (exists) return;

        this.tasks.push({
            thread_id: thread.id,
            subject: thread.subject,
            from: thread.last_author,
            at: thread.updated_at
        });

        // ブラウザ通知
        this.showBrowserNotification(thread);
    },

    completeTask: function(threadId) {
        this.tasks = this.tasks.filter(function(t) {
            return t.thread_id !== threadId;
        });
        this.renderBadge();
        this.saveToStorage();
    },

    showBrowserNotification: function(thread) {
        if (!('Notification' in window)) return;
        if (Notification.permission === 'granted') {
            new Notification('新しい手紙が届きました', {
                body: thread.last_author + 'さんから: ' + thread.subject,
                icon: './cmn/fld_new.gif'
            });
        }
    },

    saveToStorage: function() {
        localStorage.setItem('lb_notify_tasks', JSON.stringify(this.tasks));
    },

    renderBadge: function() { /* 未読バッジ表示更新 */ },
    bindEvents: function() { /* イベントリスナー登録 */ },
    isRelated: function(thread) { /* 自分宛かチェック */ return false; }
};
```

### 2.6 LB.Timeline — タイムライン表示

```javascript
LB.Timeline = {
    /**
     * タイムラインをチャット風に表示
     * @param {number} threadId - 対象スレッドID
     * @param {Array} posts - 投稿データ配列（direction付き）
     */
    render: function(threadId, posts) {
        var container = document.querySelector('[data-timeline="' + threadId + '"]');
        if (!container) return;

        container.innerHTML = '';

        posts.forEach(function(post) {
            var div = document.createElement('div');
            div.className = 'timeline-msg timeline-' + post.direction;
            // direction: 'sent' = 右寄せ, 'received' = 左寄せ

            div.innerHTML =
                '<div class="timeline-meta">' +
                    '<span class="timeline-author">' + LB.UI.escapeHtml(post.author) + '</span>' +
                    '<span class="timeline-date">' + post.created_at + '</span>' +
                '</div>' +
                '<div class="timeline-body">' + post.body + '</div>';

            container.appendChild(div);
        });

        // 最下部にスクロール
        container.scrollTop = container.scrollHeight;
    }
};
```

### 2.7 LB.Form — フォーム操作

```javascript
LB.Form = {
    init: function() {
        this.restoreCookieValues();
        this.bindSubmitValidation();
        this.bindImagePreview();
    },

    restoreCookieValues: function() {
        // クッキーから名前・メール・パスワードを復元
        var nameField = document.querySelector('input[name="name"]');
        var emailField = document.querySelector('input[name="email"]');
        var pwdField = document.querySelector('input[name="pwd"]');

        if (nameField) nameField.value = this.getCookie('letterbbs_name') || nameField.value;
        if (emailField) emailField.value = this.getCookie('letterbbs_email') || emailField.value;
        if (pwdField) pwdField.value = this.getCookie('letterbbs_pwd') || pwdField.value;
    },

    bindSubmitValidation: function() {
        // 投稿フォームのバリデーション
        var forms = document.querySelectorAll('form[data-validate]');
        forms.forEach(function(form) {
            form.addEventListener('submit', function(e) {
                if (!LB.Form.validate(form)) {
                    e.preventDefault();
                }
            });
        });
    },

    validate: function(form) {
        var valid = true;
        var required = form.querySelectorAll('[required]');
        required.forEach(function(field) {
            if (!field.value.trim()) {
                field.classList.add('field-error');
                valid = false;
            } else {
                field.classList.remove('field-error');
            }
        });
        if (!valid) {
            LB.UI.showToast('必須項目を入力してください', 'error');
        }
        return valid;
    },

    bindImagePreview: function() {
        // 画像選択時のプレビュー表示
    },

    getCookie: function(name) {
        var match = document.cookie.match(new RegExp('(^| )' + name + '=([^;]+)'));
        return match ? decodeURIComponent(match[2]) : '';
    }
};
```

### 2.8 LB.UI — UI共通処理

```javascript
LB.UI = {
    init: function() {
        // ナビゲーションのハイライト等
    },

    showToast: function(message, type) {
        type = type || 'success';
        var toast = document.createElement('div');
        toast.className = 'toast toast-' + type;
        toast.textContent = message;
        document.body.appendChild(toast);

        // アニメーション表示
        requestAnimationFrame(function() {
            toast.classList.add('toast-show');
        });

        setTimeout(function() {
            toast.classList.remove('toast-show');
            setTimeout(function() { toast.remove(); }, 300);
        }, 3000);
    },

    escapeHtml: function(str) {
        var div = document.createElement('div');
        div.textContent = str;
        return div.innerHTML;
    },

    confirm: function(message) {
        return window.confirm(message);
    }
};
```

---

## 3. CSS 設計

### 3.1 ファイル構成

| ファイル | 用途 |
|---------|------|
| `style.css` | デフォルトテーマ（Pop/Chaotic） |
| `style_gloomy.css` | Gloomy テーマ |
| `style_simple.css` | Simple テーマ |
| `style_fox.css` | Fox テーマ |
| `admin.css` | 管理画面専用 |

### 3.2 CSS変数によるテーマ管理

全テーマが共通の変数名を使用し、値のみ変更する：

```css
/* style.css (Pop/Chaotic) */
:root {
    /* カラーパレット */
    --color-bg:         #dfe4ea;
    --color-card:       #ffffff;
    --color-text:       #2f3542;
    --color-primary:    #ff4757;
    --color-secondary:  #2ed573;
    --color-accent:     #ffa502;
    --color-border:     #a4b0be;
    --color-muted:      #747d8c;

    /* タイムライン */
    --color-sent:       #d4edda;      /* 送信メッセージ背景 */
    --color-received:   #f8f9fa;      /* 受信メッセージ背景 */

    /* フォント */
    --font-heading:     'Mochiy Pop One', sans-serif;
    --font-body:        'Zen Maru Gothic', sans-serif;

    /* スペーシング */
    --space-xs:   0.25rem;
    --space-sm:   0.5rem;
    --space-md:   1rem;
    --space-lg:   1.5rem;
    --space-xl:   2rem;

    /* 角丸 */
    --radius-sm:  4px;
    --radius-md:  8px;
    --radius-lg:  12px;

    /* シャドウ */
    --shadow-sm:  0 1px 3px rgba(0,0,0,0.12);
    --shadow-md:  0 4px 6px rgba(0,0,0,0.1);
}
```

### 3.3 レスポンシブブレークポイント

```css
/* モバイルファースト */
/* デフォルト: ~767px（モバイル） */

@media (min-width: 768px) {
    /* タブレット */
}

@media (min-width: 1024px) {
    /* デスクトップ */
}
```

### 3.4 主要コンポーネントのCSS

**スレッド一覧**:
```css
.thread-list { display: flex; flex-direction: column; gap: var(--space-sm); }
.thread-item { display: flex; align-items: center; padding: var(--space-md);
               background: var(--color-card); border-radius: var(--radius-md);
               box-shadow: var(--shadow-sm); }
```

**タイムライン（チャット風表示）**:
```css
.timeline-container { display: flex; flex-direction: column; gap: var(--space-sm);
                      max-height: 400px; overflow-y: auto; padding: var(--space-md); }
.timeline-msg { max-width: 75%; padding: var(--space-sm) var(--space-md);
                border-radius: var(--radius-lg); }
.timeline-sent { align-self: flex-end; background: var(--color-sent); }
.timeline-received { align-self: flex-start; background: var(--color-received); }
```

**文通デスク**:
```css
.desk-item { display: grid; grid-template-columns: 1fr 1fr; gap: var(--space-md);
             padding: var(--space-lg); background: var(--color-card);
             border-radius: var(--radius-md); margin-bottom: var(--space-md); }
@media (max-width: 767px) {
    .desk-item { grid-template-columns: 1fr; }
}
```

**トースト通知**:
```css
.toast { position: fixed; top: var(--space-lg); right: var(--space-lg);
         padding: var(--space-sm) var(--space-lg); border-radius: var(--radius-md);
         background: var(--color-primary); color: white; z-index: 9999;
         transform: translateX(120%); transition: transform 0.3s ease; }
.toast-show { transform: translateX(0); }
.toast-error { background: #e74c3c; }
```

---

## 4. テンプレート設計

### 4.1 共通レイアウト（layout.html）

```html
<!DOCTYPE html>
<html lang="ja">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title><!-- var:page_title --> - <!-- var:bbs_title --></title>
    <link rel="stylesheet" href="<!-- var:css_url -->">
    <link rel="preconnect" href="https://fonts.googleapis.com">
    <link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
    <!-- raw:google_fonts_link -->
</head>
<body data-page="<!-- var:page_id -->">
    <header class="site-header">
        <h1 class="site-title">
            <a href="<!-- var:cgi_url -->"><!-- var:bbs_title --></a>
        </h1>
        <nav class="site-nav">
            <a href="<!-- var:cgi_url -->">一覧</a>
            <a href="<!-- var:cgi_url -->?action=form">新規投稿</a>
            <a href="<!-- var:cgi_url -->?action=search">検索</a>
            <a href="<!-- var:cgi_url -->?action=past">過去ログ</a>
            <a href="<!-- var:cgi_url -->?action=desk">文通デスク</a>
            <a href="<!-- var:cgi_url -->?action=manual">使い方</a>
        </nav>
        <div class="header-actions">
            <button id="notify-setup-btn" data-notify>通知設定</button>
            <span id="notify-badge" class="badge" style="display:none">0</span>
        </div>
    </header>

    <main class="site-main">
        <!-- raw:content -->
    </main>

    <footer class="site-footer">
        <p>Base Script: Patio (c) KENT WEB / Modified by: Sanada</p>
    </footer>

    <script src="./cmn/app.js"></script>
</body>
</html>
```

### 4.2 テンプレート変数命名規則

| プレフィックス | 用途 | 例 |
|---------------|------|---|
| `page_` | ページ固有の情報 | `page_title`, `page_id` |
| `bbs_` | 掲示板全体の設定 | `bbs_title`, `bbs_url` |
| `thread_` | スレッド情報 | `thread_id`, `thread_subject` |
| `post_` | 投稿情報 | `post_author`, `post_body` |
| `form_` | フォームの初期値 | `form_name`, `form_email` |
| `is_` | 真偽値フラグ | `is_locked`, `is_admin` |
| `has_` | 存在フラグ | `has_image`, `has_captcha` |
| `css_` / `js_` | リソースURL | `css_url`, `js_url` |

---

## 5. LocalStorage の使用範囲

ver2 では文通デスクの下書きはサーバー側保存だが、LocalStorage も補助的に使用する。

| キー | 用途 | 説明 |
|------|------|------|
| `lb_notify_name` | 通知監視名 | 通知機能で監視する名前 |
| `lb_notify_tasks` | 未読タスクリスト | 未読の手紙リスト（JSON） |
| `lb_form_backup_{threadId}` | フォーム一時保存 | 入力途中のフォーム内容（ブラウザクラッシュ対策） |

**注意**: 文通デスクの下書きデータ本体はLocalStorageに保存しない（サーバー側に保存する）。
