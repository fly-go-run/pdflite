// Pure logic for the PDFLite Opener service worker — no chrome.* access, so everything here
// runs under `node --test` (see test/). background.js is the thin shell that calls these and
// talks to the browser.

export const DEEP_LINK_BASE = "pdflite://open";

// Pages on which the right-click "用 PDFLite 打开此页面" item is offered. Match patterns, not
// regexes: `*.host` covers the bare host and every subdomain. Anywhere else the toolbar button
// and the keyboard shortcut still work, and links/selections have their own menu items.
// OpenReview and bioRxiv/medRxiv are deliberately absent: they put non-browser clients behind a
// bot challenge (403/429 — verified), so the app could only ever report a failed download.
export const PAPER_PAGE_PATTERNS = [
  "*://*.arxiv.org/*",
  "*://aclanthology.org/*",
  "*://huggingface.co/papers/*",
  "*://*.alphaxiv.org/*",
  "*://proceedings.mlr.press/*",
  "*://openaccess.thecvf.com/*",
  "*://papers.nips.cc/*",
  "*://proceedings.neurips.cc/*",
  "*://github.com/*/blob/*",
  "*://*/*.pdf",
  "*://*/*.pdf?*",
];

/** The pdflite:// link the app understands. `title` is optional page text (untrusted by the app). */
export function buildDeepLink(target, title) {
  let link = `${DEEP_LINK_BASE}?url=${encodeURIComponent(target)}`;
  if (title) link += `&title=${encodeURIComponent(title)}`;
  return link;
}

const BROWSER_SCHEMES = new Set([
  "chrome:", "chrome-extension:", "chrome-search:", "chrome-untrusted:", "devtools:",
  "edge:", "brave:", "about:", "view-source:", "vivaldi:", "opera:",
]);

/**
 * Can this URL be handed to PDFLite? Returns { ok: true } or { ok: false, reason } where
 * `reason` is a short Chinese explanation shown as the toolbar tooltip.
 * `subject` is what the URL belongs to: "页面" (tab) or "链接" (right-clicked link).
 */
export function checkUrl(url, subject = "页面") {
  if (typeof url !== "string" || url.trim() === "") {
    return { ok: false, reason: `此${subject}没有可发送的网址(新标签页?)` };
  }
  let parsed;
  try {
    parsed = new URL(url);
  } catch {
    return { ok: false, reason: `无法识别此${subject}的网址` };
  }
  if (parsed.protocol === "http:" || parsed.protocol === "https:") {
    return parsed.hostname
      ? { ok: true }
      : { ok: false, reason: `无法识别此${subject}的网址` };
  }
  if (parsed.protocol === "file:") {
    return { ok: false, reason: "本地文件请直接在 PDFLite 中打开(⌘O 或拖入窗口)" };
  }
  if (BROWSER_SCHEMES.has(parsed.protocol)) {
    return { ok: false, reason: `浏览器内置${subject}无法发送给 PDFLite` };
  }
  return { ok: false, reason: `只支持 http(s) ${subject}(当前是 ${parsed.protocol.replace(":", "")}:)` };
}

// arXiv ids. New style is yymm.number; the month check keeps "3.14159"-like noise and
// "2024.1234"-style year.number strings from being mistaken for a bare id.
const NEW_ID = String.raw`\d{2}(?:0[1-9]|1[0-2])\.\d{4,5}`;
const NEW_ID_ANY = String.raw`\d{4}\.\d{4,5}`;
const OLD_ID = String.raw`[a-z][a-z.-]*\/\d{7}`;
const VERSION = String.raw`(?:v\d+)?`;

const PREFIXED_ID = new RegExp(String.raw`arxiv:\s*((?:${NEW_ID_ANY}|${OLD_ID})${VERSION})(?!\d)`, "i");
const WHOLE_ID = new RegExp(String.raw`^(?:${NEW_ID_ANY}|${OLD_ID})${VERSION}$`, "i");
const BARE_NEW_ID = new RegExp(String.raw`(?<![\d.])(${NEW_ID}${VERSION})(?!\d)`);
const URL_IN_TEXT = /https?:\/\/[^\s<>"'`]+/i;
const TRAILING_PUNCT = /[.,;:!?)\]}>'"”’。，、；]+$/;

/**
 * Pull something PDFLite can open out of selected text: an http(s) URL, or an arXiv id
 * ("arXiv:2510.26692", "2510.26692v2", "cs.CL/0301012") which is returned as an
 * https://arxiv.org/abs/… URL so the deep link always carries a URL. Null if nothing usable.
 */
export function extractTargetFromSelection(text) {
  if (typeof text !== "string") return null;
  const trimmed = text.trim().slice(0, 2000);
  if (!trimmed) return null;

  // A URL that wrapped across lines when copied out of a PDF: http(s)://… / continuation lines
  // without spaces. Only when the whole selection is that one URL.
  const lines = trimmed.split(/\r?\n/).map((l) => l.trim()).filter(Boolean);
  if (lines.length > 1 && lines.length <= 4 && /^https?:\/\//i.test(lines[0])
      && lines.every((l) => !/\s/.test(l))
      && lines.slice(1).every((l) => !l.includes("://"))) {
    return cleanUrl(lines.join(""));
  }

  const url = trimmed.match(URL_IN_TEXT);
  if (url) return cleanUrl(url[0]);

  const prefixed = trimmed.match(PREFIXED_ID);
  if (prefixed) return arxivAbs(prefixed[1]);

  const stripped = trimmed.replace(/^[\s([{<"'“‘]+|[\s)\]}>"'”’.,;:]+$/g, "");
  if (WHOLE_ID.test(stripped)) return arxivAbs(stripped);

  const bare = trimmed.match(BARE_NEW_ID);
  if (bare) return arxivAbs(bare[1]);

  return null;
}

function cleanUrl(raw) {
  const cleaned = raw.replace(TRAILING_PUNCT, "");
  try {
    return new URL(cleaned).hostname ? cleaned : null;
  } catch {
    return null;
  }
}

function arxivAbs(id) {
  return `https://arxiv.org/abs/${id}`;
}

// ---- titles ----------------------------------------------------------------------------

const ID_LIKE = new RegExp(String.raw`^(?:arxiv:\s*)?(?:${NEW_ID_ANY}|${OLD_ID})${VERSION}$`, "i");
const FILENAME_LIKE = /^\S+\.(pdf|tex|dvi|docx?|pptx?|html?|ps)$/i;
const GENERIC_TITLE = /^(untitled|document|main|paper|manuscript|draft|output|index|title)\b[\s\d._-]*$/i;
const OFFICE_JUNK = /^microsoft (word|powerpoint|excel)\s*-\s*/i;
const ARXIV_ID_PREFIX = new RegExp(String.raw`^\[\s*(?:arxiv:\s*)?(?:${NEW_ID_ANY}|${OLD_ID})${VERSION}\s*\]\s*`, "i");
const SITE_PREFIXES = [/^Paper page\s*-\s*/i];
const SITE_SUFFIXES = [
  /\s*[-|·–—]\s*ACL Anthology$/i,
  /\s*[-|·–—]\s*alphaXiv$/i,
  /\s*[-|·–—]\s*OpenReview$/i,
  /\s*[-|·–—]\s*(bio|med)Rxiv$/i,
];
const MAX_TITLE = 300;

/**
 * A tab title worth naming the file after, or null. The app vets it again and falls back to
 * the arXiv API / URL-derived name, so being conservative here just means "no title param".
 */
export function cleanTitle(rawTitle, pageUrl = "") {
  if (typeof rawTitle !== "string") return null;

  let host = "";
  let path = "";
  try {
    const u = new URL(pageUrl);
    host = u.hostname.toLowerCase().replace(/^www\./, "");
    path = u.pathname;
  } catch { /* no usable page URL: judge the title alone */ }

  // Sites whose tab title says nothing about the paper.
  if (host === "github.com" || host === "raw.githubusercontent.com") return null; // "x.pdf at main · owner/repo"
  if (host === "thecvf.com" || host.endsWith(".thecvf.com")) return null;          // "CVPR 2016 Open Access Repository"
  // arXiv PDF tabs carry the PDF's own metadata title, often junk; the app fetches the real
  // title from the arXiv API instead.
  if ((host === "arxiv.org" || host.endsWith(".arxiv.org")) && path.startsWith("/pdf/")) return null;

  let title = rawTitle.replace(/\s+/g, " ").trim();
  title = title.replace(ARXIV_ID_PREFIX, "");
  for (const re of SITE_PREFIXES) title = title.replace(re, "");
  for (const re of SITE_SUFFIXES) title = title.replace(re, "");
  title = title.trim();

  if (title.length < 4) return null;
  if (FILENAME_LIKE.test(title) || ID_LIKE.test(title) || GENERIC_TITLE.test(title)) return null;
  if (OFFICE_JUNK.test(title) || /^[0-9a-f]{8,}$/i.test(title)) return null;
  if (title.includes("://") || /^www\./i.test(title)) return null;
  // Chrome titles a still-loading tab with its address ("arxiv.org/abs/2510.26692") — one
  // host- or path-shaped token, never a paper title.
  if (/^[a-z0-9-]+(\.[a-z0-9-]+)+(\/\S*)?$/i.test(title)) return null;
  return title.slice(0, MAX_TITLE);
}

// ---- what to do for each trigger ---------------------------------------------------------

/**
 * Decide what a click means. `source` is "action" (toolbar button / shortcut), "page",
 * "link" or "selection". Returns { ok: true, target, title } — title is null for links and
 * selections, which say nothing about the current tab's paper — or { ok: false, reason }.
 */
export function planOpen(source, { tab = {}, info = {} } = {}) {
  switch (source) {
    case "action":
    case "page": {
      const url = source === "page" ? (info.pageUrl || tab.url) : tab.url;
      const check = checkUrl(url, "页面");
      if (!check.ok) return check;
      return { ok: true, target: url, title: cleanTitle(tab.title, url) };
    }
    case "link": {
      const check = checkUrl(info.linkUrl, "链接");
      if (!check.ok) return check;
      return { ok: true, target: info.linkUrl, title: null };
    }
    case "selection": {
      const target = extractTargetFromSelection(info.selectionText);
      if (!target) {
        return { ok: false, reason: "所选文字里没有识别到 arXiv 编号或 http(s) 链接" };
      }
      return { ok: true, target, title: null };
    }
    default:
      return { ok: false, reason: "未知操作" };
  }
}
