"use strict";

const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const test = require("node:test");
const vm = require("node:vm");

const root = path.resolve(__dirname, "..");
const appSource = fs.readFileSync(path.join(root, "patio/cmn/app.js"), "utf8");

function loadApp(elements, config) {
  let reloads = 0;
  const document = {
    addEventListener: function () {},
    getElementById: function (id) {
      return elements[id] || null;
    },
    querySelector: function (selector) {
      return elements[selector] || null;
    },
    createElement: function () {
      return {
        classList: { add: function () {}, remove: function () {} },
        remove: function () {},
      };
    },
    body: {
      appendChild: function () {},
      classList: { add: function () {}, remove: function () {} },
    },
  };
  const window = {
    confirm: function () {
      return true;
    },
    location: {
      reload: function () {
        reloads += 1;
      },
    },
    LB_CONFIG: config || {},
  };
  const context = {
    document: document,
    fetch: function () {
      return Promise.resolve({ json: function () { return Promise.resolve({}); } });
    },
    requestAnimationFrame: function (callback) {
      callback();
    },
    setTimeout: function (callback) {
      callback();
    },
    window: window,
  };

  vm.runInNewContext(appSource, context, { filename: "patio/cmn/app.js" });
  return { LB: window.LB, reloads: function () { return reloads; } };
}

function draftForm(values) {
  return {
    querySelector: function (selector) {
      const name = selector.match(/^\[name="([^"]+)"\]$/);
      return name ? { value: values[name[1]] } : null;
    },
  };
}

test("panel batch send passes its password and refreshes the panel", async function () {
  const passwordInput = { value: "panel-pass" };
  const app = loadApp({ "desk-panel-password": passwordInput });
  const calls = [];
  let refreshes = 0;
  app.LB.Desk.drafts = [{ id: 1 }, { id: 2 }];
  app.LB.API.sendDrafts = function (ids, password) {
    calls.push([ids, password]);
    return Promise.resolve({ posted: 2 });
  };
  app.LB.Desk.refreshPanel = function () {
    refreshes += 1;
  };

  app.LB.Desk.sendAll();
  await Promise.resolve();

  assert.deepEqual(calls, [["1,2", "panel-pass"]]);
  assert.equal(passwordInput.value, "");
  assert.equal(refreshes, 1);
  assert.equal(app.reloads(), 0);
});

test("panel batch send falls back to an empty password without an input", async function () {
  const app = loadApp({});
  const calls = [];
  app.LB.Desk.drafts = [{ id: 1 }, { id: 2 }];
  app.LB.API.sendDrafts = function (ids, password) {
    calls.push([ids, password]);
    return Promise.resolve({ posted: 2 });
  };
  app.LB.Desk.refreshPanel = function () {};

  app.LB.Desk.sendAll();
  await Promise.resolve();

  assert.deepEqual(calls, [["1,2", ""]]);
});

test("dedicated desk batch send passes its password and reloads", async function () {
  const app = loadApp({ "desk-password": { value: "desk-pass" } });
  const calls = [];
  let refreshes = 0;
  app.LB.Desk.drafts = [{ id: 1 }, { id: 2 }];
  app.LB.API.sendDrafts = function (ids, password) {
    calls.push([ids, password]);
    return Promise.resolve({ posted: 2 });
  };
  app.LB.Desk.refreshPanel = function () {
    refreshes += 1;
  };

  app.LB.Desk.sendAllFromDesk();
  await Promise.resolve();

  assert.deepEqual(calls, [["1,2", "desk-pass"]]);
  assert.equal(refreshes, 0);
  assert.equal(app.reloads(), 1);
});

test("dedicated desk save passes the edited form values and reloads", async function () {
  const selector = '.desk-edit-form[data-draft-id="7"]';
  const form = draftForm({
    thread_id: "11",
    author: " Alice ",
    subject: " Updated subject ",
    body: " Updated body ",
  });
  const app = loadApp({ [selector]: form }, { csrfToken: "csrf-value" });
  const calls = [];
  app.LB.API.saveDraft = function (data) {
    calls.push(data);
    return Promise.resolve({ draft_id: 7 });
  };

  app.LB.Desk.saveDraft(7);
  await Promise.resolve();

  assert.deepEqual(JSON.parse(JSON.stringify(calls)), [{
    draft_id: 7,
    thread_id: "11",
    author: "Alice",
    subject: "Updated subject",
    body: "Updated body",
    csrf_token: "csrf-value",
  }]);
  assert.equal(app.reloads(), 1);
});

test("dedicated desk remove reloads after a successful delete", async function () {
  const app = loadApp({});
  app.LB.API.deleteDraft = function () {
    return Promise.resolve({});
  };
  let refreshes = 0;
  app.LB.Desk.refreshPanel = function () {
    refreshes += 1;
  };

  app.LB.Desk.removeDraft(7);
  await Promise.resolve();

  assert.equal(app.reloads(), 1);
  assert.equal(refreshes, 0);
});

test("panel remove refreshes the panel after a successful delete", async function () {
  const app = loadApp({ deskItemList: {} });
  app.LB.API.deleteDraft = function () {
    return Promise.resolve({});
  };
  let refreshes = 0;
  app.LB.Desk.refreshPanel = function () {
    refreshes += 1;
  };

  app.LB.Desk.removeDraft(7);
  await Promise.resolve();

  assert.equal(refreshes, 1);
  assert.equal(app.reloads(), 0);
});

test("layout uses the current app.js cache version", function () {
  const html = fs.readFileSync(path.join(root, "patio/tmpl/layout.html"), "utf8");

  assert.match(html, /<script src="\.\/cmn\/app\.js\?v=20260721_1"><\/script>/);
});

test("desk template configures the csrf token for the app", function () {
  const html = fs.readFileSync(path.join(root, "patio/tmpl/desk.html"), "utf8");
  const scripts = Array.from(html.matchAll(/<script>([\s\S]*?)<\/script>/g));
  const configScript = scripts.find(function (match) {
    return match[1].includes("LB_CONFIG");
  });

  assert.ok(configScript, "desk template should define LB_CONFIG");
  const source = configScript[1]
    .replace("<!-- var:api_url -->", "/custom/api.cgi")
    .replace("<!-- var:cgi_url -->", "/custom/patio.cgi")
    .replace("<!-- var:csrf_token -->", "csrf-from-template");
  const context = { window: {} };
  vm.runInNewContext(source, context, { filename: "patio/tmpl/desk.html" });

  assert.equal(context.window.LB_CONFIG.apiUrl, "/custom/api.cgi");
  assert.equal(context.window.LB_CONFIG.cgiUrl, "/custom/patio.cgi");
  assert.equal(context.window.LB_CONFIG.csrfToken, "csrf-from-template");
});

test("read template exposes the shared password field for edit and delete", function () {
  const html = fs.readFileSync(path.join(root, "patio/tmpl/read.html"), "utf8");
  const input = html.match(/<input\b[^>]*\bid=["']desk-panel-password["'][^>]*>/i);

  assert.match(html, /<label\b[^>]*\bfor=["']desk-panel-password["'][^>]*>\s*パスワード（一括）\s*<\/label>/i);
  assert.ok(input, "desk-panel-password input should exist");
  assert.match(input[0], /\btype=["']password["']/i);
  assert.match(input[0], /\bmaxlength=["']8["']/i);
  assert.match(input[0], /\bplaceholder=["']編集\/削除用["']/i);
});
