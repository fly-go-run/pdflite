// PDFLite Opener service worker. Turns a page / link / selection into a pdflite://open deep
// link and fires it in the current tab. A custom scheme never navigates the page away — the
// browser just asks "打开 PDFLite?" once (tick "始终允许" and it's silent afterwards).
// All decisions live in lib.js; this file only talks to the browser and reports the outcome
// on the toolbar icon, so an action never fails silently.
import { PAPER_PAGE_PATTERNS, buildDeepLink, planOpen } from "./lib.js";

const DEFAULT_TITLE = "用 PDFLite 打开当前页面";
const OK_COLOR = "#2e9e5b";
const ERROR_COLOR = "#d93025";
const OK_MS = 2000;
const ERROR_MS = 8000; // long enough to hover the icon and read why

const flashTimers = new Map(); // tabId -> timeout handle

// Runs each browser call, tolerating both a synchronous throw and a rejected promise — a tab
// closed mid-flash must never turn feedback into an error.
const settleAll = (...calls) =>
  Promise.allSettled(calls.map((call) => {
    try {
      return call();
    } catch (err) {
      return Promise.reject(err);
    }
  }));

// Short-lived badge on this tab's toolbar icon: green ✓ (sent) or red ! (why it wasn't).
// The tooltip carries the explanation. Tab-scoped, so it also disappears on navigation.
function flash(tabId, kind, message) {
  const scope = tabId == null ? {} : { tabId };
  const ok = kind === "ok";
  settleAll(
    () => chrome.action.setBadgeBackgroundColor({ color: ok ? OK_COLOR : ERROR_COLOR, ...scope }),
    () => chrome.action.setBadgeText({ text: ok ? "✓" : "!", ...scope }),
    () => chrome.action.setTitle({ title: message, ...scope }),
  );

  clearTimeout(flashTimers.get(tabId));
  flashTimers.set(tabId, setTimeout(() => {
    flashTimers.delete(tabId);
    settleAll(
      () => chrome.action.setBadgeText({ text: "", ...scope }),
      () => chrome.action.setTitle({ title: DEFAULT_TITLE, ...scope }),
    );
  }, ok ? OK_MS : ERROR_MS));
}

async function targetTabId(tab) {
  if (tab?.id != null) return tab.id;
  const [active] = await chrome.tabs.query({ active: true, lastFocusedWindow: true });
  return active?.id;
}

async function run(source, { tab, info } = {}) {
  const tabId = await targetTabId(tab);
  const plan = planOpen(source, { tab: tab ?? {}, info: info ?? {} });
  if (!plan.ok) {
    flash(tabId, "error", plan.reason);
    return;
  }
  if (tabId == null) {
    flash(tabId, "error", "找不到可用的标签页");
    return;
  }
  try {
    await chrome.tabs.update(tabId, { url: buildDeepLink(plan.target, plan.title) });
    flash(tabId, "ok", "已发送给 PDFLite");
  } catch (err) {
    flash(tabId, "error", `发送失败:${err?.message ?? err}`);
  }
}

// Toolbar button and the _execute_action keyboard shortcut (rebind at chrome://extensions/shortcuts).
chrome.action.onClicked.addListener((tab) => run("action", { tab }));

const MENU_SOURCES = {
  "pdflite-open-page": "page",
  "pdflite-open-link": "link",
  "pdflite-open-selection": "selection",
};

chrome.runtime.onInstalled.addListener(() => {
  // Menus persist across restarts and updates; start from a clean slate so renamed or removed
  // items don't linger and re-creating never trips over duplicate ids.
  chrome.contextMenus.removeAll(() => {
    const created = () => void chrome.runtime.lastError; // read it so Chrome doesn't log "unchecked"
    chrome.contextMenus.create({
      id: "pdflite-open-page",
      title: "用 PDFLite 打开此页面",
      contexts: ["page"],
      documentUrlPatterns: PAPER_PAGE_PATTERNS,
    }, created);
    chrome.contextMenus.create({
      id: "pdflite-open-link",
      title: "用 PDFLite 打开链接",
      contexts: ["link"],
    }, created);
    chrome.contextMenus.create({
      id: "pdflite-open-selection",
      title: "用 PDFLite 打开所选链接/编号",
      contexts: ["selection"],
    }, created);
  });
});

chrome.contextMenus.onClicked.addListener((info, tab) => {
  const source = MENU_SOURCES[info.menuItemId];
  if (source) return run(source, { tab, info });
});
