"use strict";

const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const test = require("node:test");
const vm = require("node:vm");

const root = path.resolve(__dirname, "..");
const appSource = fs.readFileSync(path.join(root, "patio/cmn/app.js"), "utf8");

function loadApp(elements) {
  let reloads = 0;
  const document = {
    addEventListener: function () {},
    getElementById: function (id) {
      return elements[id] || null;
    },
    querySelector: function () {
      return null;
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
    LB_CONFIG: {},
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

test("panel batch send passes its password and refreshes the panel", async function () {
  const app = loadApp({ "desk-panel-password": { value: "panel-pass" } });
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
  assert.equal(refreshes, 1);
  assert.equal(app.reloads(), 0);
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

test("read template exposes the shared password field for edit and delete", function () {
  const html = fs.readFileSync(path.join(root, "patio/tmpl/read.html"), "utf8");
  const input = html.match(/<input\b[^>]*\bid=["']desk-panel-password["'][^>]*>/i);

  assert.match(html, /<label\b[^>]*\bfor=["']desk-panel-password["'][^>]*>\s*パスワード（一括）\s*<\/label>/i);
  assert.ok(input, "desk-panel-password input should exist");
  assert.match(input[0], /\btype=["']password["']/i);
  assert.match(input[0], /\bmaxlength=["']8["']/i);
  assert.match(input[0], /\bplaceholder=["']編集\/削除用["']/i);
});
