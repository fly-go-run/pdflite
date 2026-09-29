// Wiring test for background.js against a fake `chrome`: menus are rebuilt cleanly, every
// trigger ends in either a deep-link navigation + green ✓ or a red ! with an explanation.
import { test, beforeEach, mock } from "node:test";
import assert from "node:assert/strict";
import { PAPER_PAGE_PATTERNS } from "../lib.js";

const calls = [];
const handlers = {};
let updateImpl;

globalThis.chrome = {
  action: {
    onClicked: { addListener: (fn) => { handlers.action = fn; } },
    setBadgeText: async (a) => { calls.push(["badgeText", a]); },
    setBadgeBackgroundColor: async (a) => { calls.push(["badgeColor", a]); },
    setTitle: async (a) => { calls.push(["title", a]); },
  },
  runtime: { onInstalled: { addListener: (fn) => { handlers.installed = fn; } }, lastError: undefined },
  contextMenus: {
    removeAll: (cb) => { calls.push(["removeAll"]); cb(); },
    create: (item, cb) => { calls.push(["create", item]); cb?.(); },
    onClicked: { addListener: (fn) => { handlers.menu = fn; } },
  },
  tabs: {
    update: async (id, props) => { calls.push(["update", id, props]); return updateImpl(id, props); },
    query: async () => [{ id: 99 }],
  },
};

await import("../background.js");

beforeEach(() => {
  calls.length = 0;
  updateImpl = async (id) => ({ id });
  mock.timers.reset();
  mock.timers.enable({ apis: ["setTimeout"] });
});

const of = (name) => calls.filter(([n]) => n === name).map(([, ...rest]) => rest);
const lastBadge = () => of("badgeText").at(-1)[0];
const lastTitle = () => of("title").at(-1)[0];

test("onInstalled clears old menus first, then creates page (paper hosts only), link and selection", () => {
  handlers.installed();
  assert.equal(calls[0][0], "removeAll");
  const items = of("create").map(([item]) => item);
  assert.deepEqual(items.map((i) => i.id),
    ["pdflite-open-page", "pdflite-open-link", "pdflite-open-selection"]);
  assert.deepEqual(items[0].contexts, ["page"]);
  assert.deepEqual(items[0].documentUrlPatterns, PAPER_PAGE_PATTERNS);
  assert.deepEqual(items[1].contexts, ["link"]);
  assert.equal(items[1].documentUrlPatterns, undefined);
  assert.deepEqual(items[2].contexts, ["selection"]);
});

test("toolbar click on a paper page navigates to the deep link with the cleaned title, then shows ✓", async () => {
  await handlers.action({ id: 7, url: "https://arxiv.org/abs/2510.26692", title: "[2510.26692] Kimi Linear" });
  const [id, props] = of("update")[0];
  assert.equal(id, 7);
  assert.equal(props.url,
    "pdflite://open?url=https%3A%2F%2Farxiv.org%2Fabs%2F2510.26692&title=Kimi%20Linear");
  assert.deepEqual(lastBadge(), { text: "✓", tabId: 7 });

  mock.timers.tick(2000);
  await Promise.resolve();
  assert.deepEqual(lastBadge(), { text: "", tabId: 7 });
  assert.equal(lastTitle().title, "用 PDFLite 打开当前页面");
});

test("toolbar click on an unsupported page shows a red ! with the reason and sends nothing", async () => {
  await handlers.action({ id: 3, url: "chrome://extensions", title: "Extensions" });
  assert.equal(of("update").length, 0);
  assert.deepEqual(lastBadge(), { text: "!", tabId: 3 });
  assert.match(lastTitle().title, /浏览器内置页面/);
  assert.equal(lastTitle().tabId, 3);

  mock.timers.tick(8000);
  await Promise.resolve();
  assert.deepEqual(lastBadge(), { text: "", tabId: 3 });
});

test("link menu item sends the link without a title", async () => {
  await handlers.menu(
    { menuItemId: "pdflite-open-link", linkUrl: "https://example.com/a.pdf" },
    { id: 5, url: "https://news.example.com/", title: "News Site Front Page" },
  );
  assert.equal(of("update")[0][1].url, "pdflite://open?url=https%3A%2F%2Fexample.com%2Fa.pdf");
  assert.equal(lastBadge().text, "✓");
});

test("selection menu item extracts an arXiv id, or complains when there is none", async () => {
  await handlers.menu(
    { menuItemId: "pdflite-open-selection", selectionText: "arXiv:2510.26692" },
    { id: 5, url: "https://example.com/", title: "Whatever" },
  );
  assert.equal(of("update")[0][1].url,
    "pdflite://open?url=https%3A%2F%2Farxiv.org%2Fabs%2F2510.26692");

  calls.length = 0;
  await handlers.menu(
    { menuItemId: "pdflite-open-selection", selectionText: "no paper here" },
    { id: 5, url: "https://example.com/" },
  );
  assert.equal(of("update").length, 0);
  assert.deepEqual(lastBadge(), { text: "!", tabId: 5 });
  assert.match(lastTitle().title, /没有识别到/);
});

test("a failing navigation is reported, not swallowed", async () => {
  updateImpl = async () => { throw new Error("No tab with id: 7"); };
  await handlers.action({ id: 7, url: "https://arxiv.org/abs/2510.26692", title: "x" });
  assert.deepEqual(lastBadge(), { text: "!", tabId: 7 });
  assert.match(lastTitle().title, /发送失败.*No tab/);
});

test("without a tab object the active tab is used for feedback", async () => {
  await handlers.menu({ menuItemId: "pdflite-open-selection", selectionText: "junk" }, undefined);
  assert.deepEqual(lastBadge(), { text: "!", tabId: 99 });
});
