const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');

const style = fs.readFileSync('patio/cmn/style.css', 'utf8');
const readTemplate = fs.readFileSync('patio/tmpl/read.html', 'utf8');
const settingsTemplate = fs.readFileSync('patio/tmpl/admin/settings.html', 'utf8');
const boardTemplate = fs.readFileSync('patio/tmpl/bbs.html', 'utf8');

test('mobile legend wraps between complete legend items', () => {
  const legendRule = style.match(/\.icon-list\s*\{([\s\S]*?)\}/);
  assert.ok(legendRule, 'icon-list rule exists');
  assert.match(legendRule[1], /flex-wrap\s*:\s*wrap\s*;/);

  const itemRule = style.match(/\.icon-list\s*>\s*span\s*\{([\s\S]*?)\}/);
  assert.ok(itemRule, 'direct legend item rule exists');
  assert.match(itemRule[1], /white-space\s*:\s*nowrap\s*;/);

  const legend = boardTemplate.match(/<div id="icon-mark"[\s\S]*?<\/div>/);
  assert.ok(legend, 'board legend exists');
  const items = [...legend[0].matchAll(/<span class="icon-item"><span class="ico-fld_[^"]+"><\/span>\s*[^<]+<\/span>/g)];
  assert.equal(items.length, 4, 'all four labels are grouped as complete legend items');
  assert.match(items[3][0], /ico-fld_lock[\s\S]*管理者コメント機能/);
});

test('reply-only navigation is hidden while a thread is locked', () => {
  const navigation = readTemplate.match(/<div class="bbs-navi">([\s\S]*?)<\/div>\s*\n\s*<!-- スレッド親記事 -->/);
  assert.ok(navigation, 'navigation block exists');

  const unlockedBlocks = [...navigation[1].matchAll(/<!-- unless:is_locked -->([\s\S]*?)<!-- \/unless:is_locked -->/g)];
  assert.equal(unlockedBlocks.length, 2, 'both reply navigation areas are unlocked-only');
  const unlockedHtml = unlockedBlocks.map((match) => match[1]).join('\n');
  assert.match(unlockedHtml, /href="#resform"[^>]*>[^<]*返信する/);
  assert.match(unlockedHtml, /href="#resform" class="jump-btn"/);

  const alwaysVisible = navigation[1].replace(/<!-- unless:is_locked -->[\s\S]*?<!-- \/unless:is_locked -->/g, '');
  assert.doesNotMatch(alwaysVisible, /href="#resform"/);
  assert.match(alwaysVisible, /一覧に戻る/);
  assert.match(alwaysVisible, /思い出を保存/);
});

test('admin settings exposes CAPTCHA enable and disable choices', () => {
  assert.match(settingsTemplate, /<select name="use_captcha">/);
  assert.match(settingsTemplate, /value="0"<!-- if:use_captcha_off --> selected/);
  assert.match(settingsTemplate, /value="1"<!-- if:use_captcha_on --> selected/);
});
