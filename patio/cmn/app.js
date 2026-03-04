/**
 * LetterBBS ver2 — 統合クライアントスクリプト
 * 文通デスク・通知・タイムライン・フォーム操作を統合管理する
 */
(function(window, document) {
  'use strict';

  var LB = window.LetterBBS = {};

  /* ============================================================
     Config — 設定値
     ============================================================ */
  LB.Config = {
    apiUrl: (window.LB_CONFIG && window.LB_CONFIG.apiUrl) || './api.cgi',
    cgiUrl: (window.LB_CONFIG && window.LB_CONFIG.cgiUrl) || './patio.cgi',
    csrfToken: (window.LB_CONFIG && window.LB_CONFIG.csrfToken) || '',
    threadId: (window.LB_CONFIG && window.LB_CONFIG.threadId) || 0,
    pollInterval: { idle: 60000, active: 30000, focused: 15000 },
    autoSaveInterval: 10000
  };

  /* ============================================================
     UI — 共通UI処理
     ============================================================ */
  LB.UI = {
    init: function() {
      // ページ固有のdata属性ベース初期化
    },

    // トースト通知
    showToast: function(message, type) {
      type = type || 'success';
      var toast = document.createElement('div');
      toast.className = 'toast' + (type === 'error' ? ' toast-error' : '');
      toast.textContent = message;
      document.body.appendChild(toast);

      requestAnimationFrame(function() {
        toast.classList.add('toast-show');
      });

      setTimeout(function() {
        toast.classList.remove('toast-show');
        setTimeout(function() { toast.remove(); }, 300);
      }, 3000);
    },

    // HTMLエスケープ
    escapeHtml: function(str) {
      if (!str) return '';
      var div = document.createElement('div');
      div.textContent = str;
      return div.innerHTML;
    },

    confirm: function(message) {
      return window.confirm(message);
    }
  };

  /* ============================================================
     API — サーバーAPI通信
     ============================================================ */
  LB.API = {
    // 汎用リクエスト
    request: function(api, params, method) {
      method = method || 'GET';
      var url = LB.Config.apiUrl + '?api=' + api;

      var options = {
        method: method,
        headers: { 'X-Requested-With': 'XMLHttpRequest' }
      };

      if (method === 'GET' && params) {
        var qs = Object.keys(params).map(function(k) {
          return encodeURIComponent(k) + '=' + encodeURIComponent(params[k]);
        }).join('&');
        url += '&' + qs;
      } else if (method === 'POST' && params) {
        options.headers['Content-Type'] = 'application/x-www-form-urlencoded';
        var body = Object.keys(params).map(function(k) {
          return encodeURIComponent(k) + '=' + encodeURIComponent(params[k]);
        }).join('&');
        options.body = body;
      }

      return fetch(url, options)
        .then(function(res) { return res.json(); })
        .then(function(data) {
          if (!data.success) {
            throw new Error(data.error || '不明なエラーが発生しました');
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

  /* ============================================================
     Desk — 文通デスク機能
     ============================================================ */
  LB.Desk = {
    drafts: [],
    panelVisible: false,

    /* --- 記事閲覧ページからの操作 --- */

    // 「デスクに置く」ボタン押下 → インライン入力エリア表示
    addFromThread: function(threadId, author, btn) {
      var article = btn.closest('.post');
      if (!article) return;
      var area = article.querySelector('.desk-input-area');
      if (!area) return;

      // トグル表示
      if (area.style.display === 'none' || area.style.display === '') {
        area.style.display = 'block';
        // 名前のデフォルト値をクッキーから復元
        var nameInput = area.querySelector('.desk-name');
        if (nameInput && !nameInput.value) {
          nameInput.value = LB.Form.getCookie('letterbbs_name') || '';
        }
        // タイムライン読み込み
        var timelineArea = area.querySelector('.desk-timeline');
        if (timelineArea) {
          var myName = nameInput ? nameInput.value : '';
          if (myName && author) {
            LB.API.getTimeline(myName, author).then(function(data) {
              if (data.posts && data.posts.length > 0) {
                timelineArea.style.display = 'block';
                LB.Timeline.renderInto(timelineArea, data.posts);
              }
            }).catch(function() { /* タイムライン取得失敗は無視 */ });
          }
        }
      } else {
        area.style.display = 'none';
      }
    },

    // インライン入力エリアの「保存してデスクへ」ボタン
    saveFromInput: function(threadId, author, btn) {
      var area = btn.closest('.desk-input-area');
      if (!area) return;

      var name    = area.querySelector('.desk-name').value.trim();
      var subject = area.querySelector('.desk-subject').value.trim();
      var body    = area.querySelector('.desk-textarea').value.trim();

      if (!name) {
        LB.UI.showToast('名前を入力してください', 'error');
        return;
      }
      if (!body) {
        LB.UI.showToast('メッセージを入力してください', 'error');
        return;
      }

      LB.API.saveDraft({
        thread_id: threadId,
        author: name,
        subject: subject,
        body: body,
        csrf_token: LB.Config.csrfToken
      }).then(function(data) {
        LB.UI.showToast('デスクに保存しました');
        area.style.display = 'none';
        area.querySelector('.desk-textarea').value = '';
        area.querySelector('.desk-subject').value = '';
        // パネルの件数を更新
        LB.Desk.refreshPanel();
      }).catch(function(err) {
        LB.UI.showToast('保存エラー: ' + err.message, 'error');
      });
    },

    // インライン入力エリアを閉じる
    closeInput: function(btn) {
      var area = btn.closest('.desk-input-area');
      if (area) area.style.display = 'none';
    },

    /* --- 文通デスクパネル --- */

    // パネル表示/非表示切り替え
    togglePanel: function() {
      var panel = document.getElementById('correspondeskPanel');
      if (!panel) return;

      this.panelVisible = !this.panelVisible;
      panel.style.display = this.panelVisible ? 'block' : 'none';

      if (this.panelVisible) {
        this.refreshPanel();
      }
    },

    // パネルの下書き一覧を更新
    refreshPanel: function() {
      var list = document.getElementById('deskItemList');
      var emptyMsg = document.getElementById('deskEmptyMsg');
      if (!list) return;

      LB.API.getDrafts().then(function(data) {
        LB.Desk.drafts = data.drafts || [];
        list.innerHTML = '';

        if (LB.Desk.drafts.length === 0) {
          if (emptyMsg) emptyMsg.style.display = 'block';
          return;
        }

        if (emptyMsg) emptyMsg.style.display = 'none';

        LB.Desk.drafts.forEach(function(draft) {
          var item = document.createElement('div');
          item.className = 'desk-draft-item';
          item.innerHTML =
            '<div class="desk-draft-head">' +
              '<strong>' + LB.UI.escapeHtml(draft.thread_subject || '(無題)') + '</strong>' +
              '<span class="desk-draft-meta">' +
                LB.UI.escapeHtml(draft.author) + ' → ' + LB.UI.escapeHtml(draft.thread_author) +
              '</span>' +
            '</div>' +
            '<div class="desk-draft-body">' + LB.UI.escapeHtml(draft.body).substring(0, 80) + '</div>' +
            '<div class="desk-draft-actions">' +
              '<button onclick="LB.Desk.removeDraft(' + draft.id + ')" class="btn-cancel-desk">削除</button>' +
            '</div>';
          list.appendChild(item);
        });
      }).catch(function() {
        LB.UI.showToast('下書きの読み込みに失敗しました', 'error');
      });
    },

    // 下書き個別削除
    removeDraft: function(draftId) {
      if (!LB.UI.confirm('この下書きを削除しますか？')) return;
      LB.API.deleteDraft(draftId).then(function() {
        LB.UI.showToast('下書きを削除しました');
        LB.Desk.refreshPanel();
      }).catch(function(err) {
        LB.UI.showToast('削除エラー: ' + err.message, 'error');
      });
    },

    // 一括送信
    sendAll: function() {
      if (this.drafts.length === 0) {
        LB.UI.showToast('送信する下書きがありません', 'error');
        return;
      }
      if (!LB.UI.confirm(this.drafts.length + '件の返信を一括送信しますか？')) return;

      var ids = this.drafts.map(function(d) { return d.id; }).join(',');
      LB.API.sendDrafts(ids, '').then(function(result) {
        LB.UI.showToast(result.posted + '件の返信を送信しました');
        LB.Desk.refreshPanel();
      }).catch(function(err) {
        LB.UI.showToast('送信エラー: ' + err.message, 'error');
      });
    },

    // 全てクリア
    clearAll: function() {
      if (this.drafts.length === 0) return;
      if (!LB.UI.confirm('全ての下書きを削除しますか？')) return;

      var promises = this.drafts.map(function(d) {
        return LB.API.deleteDraft(d.id);
      });
      Promise.all(promises).then(function() {
        LB.UI.showToast('全ての下書きを削除しました');
        LB.Desk.refreshPanel();
      }).catch(function(err) {
        LB.UI.showToast('削除エラー: ' + err.message, 'error');
      });
    }
  };

  /* ============================================================
     Timeline — タイムライン表示
     ============================================================ */
  LB.Timeline = {
    // 指定コンテナにタイムラインを描画
    renderInto: function(container, posts) {
      if (!container || !posts) return;
      container.innerHTML = '';

      posts.forEach(function(post) {
        var div = document.createElement('div');
        div.className = 'timeline-msg timeline-' + (post.direction || 'received');
        div.innerHTML =
          '<div class="timeline-meta">' +
            '<span class="timeline-author">' + LB.UI.escapeHtml(post.author) + '</span>' +
            '<span class="timeline-date">' + (post.created_at || '') + '</span>' +
          '</div>' +
          '<div class="timeline-body">' + LB.UI.escapeHtml(post.body || '').substring(0, 200) + '</div>';
        container.appendChild(div);
      });

      container.scrollTop = container.scrollHeight;
    }
  };

  /* ============================================================
     Notify — 通知タスク
     ============================================================ */
  LB.Notify = {
    watchName: '',
    lastCheck: null,
    tasks: [],
    pollTimer: null,

    init: function() {
      try {
        this.watchName = localStorage.getItem('lb_notify_name') || '';
        this.tasks = JSON.parse(localStorage.getItem('lb_notify_tasks') || '[]');
      } catch (e) {
        this.watchName = '';
        this.tasks = [];
      }

      if (this.watchName) {
        this.startPolling();
        this.renderBadge();
      }
    },

    setup: function(name) {
      this.watchName = name;
      try {
        localStorage.setItem('lb_notify_name', name);
      } catch (e) {}
      this.tasks = [];
      this.lastCheck = null;
      this.startPolling();
      LB.UI.showToast('「' + name + '」宛の通知を有効にしました');
    },

    startPolling: function() {
      if (this.pollTimer) clearInterval(this.pollTimer);
      var interval = this.tasks.length > 0
        ? LB.Config.pollInterval.active
        : LB.Config.pollInterval.idle;
      this.poll();
      var self = this;
      this.pollTimer = setInterval(function() { self.poll(); }, interval);
    },

    poll: function() {
      var self = this;
      LB.API.getThreads(this.lastCheck).then(function(data) {
        self.lastCheck = data.server_time;

        (data.threads || []).forEach(function(thread) {
          if (thread.last_author !== self.watchName &&
              thread.author === self.watchName) {
            self.addTask(thread);
          }
        });

        self.renderBadge();
        self.saveToStorage();
      }).catch(function() { /* ポーリングエラーは静かに無視 */ });
    },

    addTask: function(thread) {
      var exists = this.tasks.some(function(t) { return t.thread_id === thread.id; });
      if (exists) return;

      this.tasks.push({
        thread_id: thread.id,
        subject: thread.subject,
        from: thread.last_author,
        at: thread.updated_at
      });

      // ブラウザ通知
      if ('Notification' in window && Notification.permission === 'granted') {
        new Notification('新しい手紙が届きました', {
          body: thread.last_author + 'さんから: ' + thread.subject
        });
      }
    },

    completeTask: function(threadId) {
      this.tasks = this.tasks.filter(function(t) { return t.thread_id !== threadId; });
      this.renderBadge();
      this.saveToStorage();
    },

    renderBadge: function() {
      var badge = document.getElementById('notify-badge');
      if (!badge) return;
      if (this.tasks.length > 0) {
        badge.style.display = 'inline-block';
        badge.textContent = this.tasks.length;
      } else {
        badge.style.display = 'none';
      }
    },

    saveToStorage: function() {
      try {
        localStorage.setItem('lb_notify_tasks', JSON.stringify(this.tasks));
      } catch (e) {}
    }
  };

  /* ============================================================
     Form — フォーム操作
     ============================================================ */
  LB.Form = {
    init: function() {
      this.restoreCookieValues();
    },

    restoreCookieValues: function() {
      var nameField = document.querySelector('input[name="name"]');
      if (nameField && !nameField.value) {
        nameField.value = this.getCookie('letterbbs_name') || '';
      }
    },

    getCookie: function(name) {
      var match = document.cookie.match(new RegExp('(^| )' + name + '=([^;]+)'));
      return match ? decodeURIComponent(match[2]) : '';
    }
  };

  /* ============================================================
     初期化
     ============================================================ */
  document.addEventListener('DOMContentLoaded', function() {
    // LB_CONFIG のマージ（テンプレートからの設定値反映）
    if (window.LB_CONFIG) {
      LB.Config.apiUrl = window.LB_CONFIG.apiUrl || LB.Config.apiUrl;
      LB.Config.cgiUrl = window.LB_CONFIG.cgiUrl || LB.Config.cgiUrl;
      LB.Config.csrfToken = window.LB_CONFIG.csrfToken || LB.Config.csrfToken;
      LB.Config.threadId = window.LB_CONFIG.threadId || LB.Config.threadId;
    }

    LB.UI.init();
    LB.Form.init();

    // 通知の初期化
    LB.Notify.init();
  });

})(window, document);
