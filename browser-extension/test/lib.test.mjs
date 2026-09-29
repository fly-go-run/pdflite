import { test } from "node:test";
import assert from "node:assert/strict";
import {
  PAPER_PAGE_PATTERNS,
  buildDeepLink,
  checkUrl,
  cleanTitle,
  extractTargetFromSelection,
  planOpen,
} from "../lib.js";

const ABS = "https://arxiv.org/abs/2510.26692";

// ---- checkUrl ----------------------------------------------------------------------------

test("checkUrl accepts http(s) pages", () => {
  for (const url of [ABS, "http://example.com/a.pdf", "https://github.com/o/r/blob/main/a.pdf"]) {
    assert.deepEqual(checkUrl(url), { ok: true }, url);
  }
});

test("checkUrl rejects everything else with an explanation", () => {
  const cases = [
    [undefined, /没有可发送的网址/],
    ["", /没有可发送的网址/],
    ["   ", /没有可发送的网址/],
    ["chrome://extensions", /浏览器内置页面/],
    ["chrome://newtab/", /浏览器内置页面/],
    ["edge://settings", /浏览器内置页面/],
    ["about:blank", /浏览器内置页面/],
    ["view-source:https://example.com", /浏览器内置页面/],
    ["chrome-extension://abcdef/page.html", /浏览器内置页面/],
    ["file:///Users/me/paper.pdf", /本地文件.*PDFLite/],
    ["ftp://example.com/a.pdf", /只支持 http\(s\)/],
    ["javascript:alert(1)", /只支持 http\(s\)/],
    ["not a url", /无法识别/],
  ];
  for (const [url, expected] of cases) {
    const r = checkUrl(url);
    assert.equal(r.ok, false, String(url));
    assert.match(r.reason, expected, String(url));
  }
});

test("checkUrl words the reason for links differently from pages", () => {
  assert.match(checkUrl("mailto:a@b.c", "链接").reason, /链接/);
  assert.match(checkUrl("chrome://settings", "链接").reason, /浏览器内置链接/);
});

// ---- selection extraction ----------------------------------------------------------------

test("extractTargetFromSelection recognizes arXiv ids in their usual spellings", () => {
  const cases = {
    "arXiv:2510.26692": "https://arxiv.org/abs/2510.26692",
    "arxiv:2510.26692v2": "https://arxiv.org/abs/2510.26692v2",
    "  2510.26692  ": "https://arxiv.org/abs/2510.26692",
    "2510.26692v3.": "https://arxiv.org/abs/2510.26692v3",
    "(arXiv:2510.26692)": "https://arxiv.org/abs/2510.26692",
    "[2510.26692]": "https://arxiv.org/abs/2510.26692",
    "See arXiv: 2510.26692 for details": "https://arxiv.org/abs/2510.26692",
    "as shown in 2510.26692 the authors": "https://arxiv.org/abs/2510.26692",
    "cs.CL/0301012": "https://arxiv.org/abs/cs.CL/0301012",
    "arXiv:cs.CL/0301012v2": "https://arxiv.org/abs/cs.CL/0301012v2",
    "arXiv:1706.03762": "https://arxiv.org/abs/1706.03762",
  };
  for (const [text, expected] of Object.entries(cases)) {
    assert.equal(extractTargetFromSelection(text), expected, JSON.stringify(text));
  }
});

test("extractTargetFromSelection returns http(s) URLs, trimming trailing punctuation", () => {
  const cases = {
    "https://arxiv.org/abs/2510.26692": "https://arxiv.org/abs/2510.26692",
    "Read https://arxiv.org/pdf/2510.26692v2.pdf, then reply": "https://arxiv.org/pdf/2510.26692v2.pdf",
    "(https://example.com/a.pdf).": "https://example.com/a.pdf",
    "http://example.com/a?x=1&y=2": "http://example.com/a?x=1&y=2",
    "https://a.com/x https://b.com/y": "https://a.com/x", // first one wins
    "arXiv:2510.26692 https://example.com/other.pdf": "https://example.com/other.pdf", // explicit URL beats an id
  };
  for (const [text, expected] of Object.entries(cases)) {
    assert.equal(extractTargetFromSelection(text), expected, JSON.stringify(text));
  }
});

test("extractTargetFromSelection rejoins a URL that wrapped across lines", () => {
  assert.equal(
    extractTargetFromSelection("https://arxiv.org/abs/2510.\n26692"),
    "https://arxiv.org/abs/2510.26692",
  );
  assert.equal(
    extractTargetFromSelection("https://example.com/very/long/\r\npath/paper.pdf"),
    "https://example.com/very/long/path/paper.pdf",
  );
  // Two separate URLs on two lines are not one wrapped URL.
  assert.equal(
    extractTargetFromSelection("https://a.com/x\nhttps://b.com/y"),
    "https://a.com/x",
  );
});

test("extractTargetFromSelection ignores things that merely look numeric", () => {
  for (const text of [
    undefined, null, 42, "", "   ", "hello world",
    "In 2024.1234 we", // year.number — month 24 is impossible
    "Figure 3.14159 shows", "version 1.2.3.45678", "arXiv:2510.266923", "12345",
    "ftp://example.com/a.pdf",
  ]) {
    assert.equal(extractTargetFromSelection(text), null, JSON.stringify(text));
  }
});

// ---- titles ------------------------------------------------------------------------------

test("cleanTitle strips arXiv id prefixes and site chrome", () => {
  const cases = [
    ["[2510.26692] Kimi Linear: An Expressive, Efficient Attention Architecture", ABS,
      "Kimi Linear: An Expressive, Efficient Attention Architecture"],
    ["[arXiv:2510.26692v2] Some Title Here", ABS, "Some Title Here"],
    ["[cs.CL/0301012] Old Style Title", "https://arxiv.org/abs/cs.CL/0301012", "Old Style Title"],
    ["Paper page - Kimi Linear: An Expressive Architecture", "https://huggingface.co/papers/2510.26692",
      "Kimi Linear: An Expressive Architecture"],
    ["Kimi Linear: An Expressive Architecture | alphaXiv", "https://www.alphaxiv.org/abs/2510.26692",
      "Kimi Linear: An Expressive Architecture"],
    ["Unsupervised Cross-lingual Representation Learning at Scale - ACL Anthology",
      "https://aclanthology.org/2020.acl-main.747/", "Unsupervised Cross-lingual Representation Learning at Scale"],
    ["Graph Attention Networks | OpenReview", "https://openreview.net/forum?id=rJXMpikCZ",
      "Graph Attention Networks"],
    ["Learning Transferable Visual Models From Natural Language Supervision",
      "https://proceedings.mlr.press/v139/radford21a.html",
      "Learning Transferable Visual Models From Natural Language Supervision"],
    ["  Multi\n line   title  ", "https://example.com/", "Multi line title"],
    // Only arXiv-id brackets are stripped.
    ["[Survey] A Big Paper", "https://example.com/", "[Survey] A Big Paper"],
  ];
  for (const [raw, url, expected] of cases) {
    assert.equal(cleanTitle(raw, url), expected, raw);
  }
});

test("cleanTitle gives up on hosts whose titles say nothing about the paper", () => {
  assert.equal(cleanTitle("CVPR 2016 Open Access Repository",
    "https://openaccess.thecvf.com/content_cvpr_2016/html/He_paper.html"), null);
  assert.equal(cleanTitle("paper.pdf at main · owner/repo",
    "https://github.com/owner/repo/blob/main/paper.pdf"), null);
  // arXiv PDF tabs show the PDF's metadata title; the app asks the arXiv API instead.
  assert.equal(cleanTitle("main.dvi", "https://arxiv.org/pdf/2510.26692"), null);
  assert.equal(cleanTitle("A Perfectly Fine Metadata Title", "https://arxiv.org/pdf/2510.26692v2"), null);
  // ...but the same title on the abstract page is kept.
  assert.equal(cleanTitle("[2510.26692] A Perfectly Fine Title", ABS), "A Perfectly Fine Title");
});

test("cleanTitle drops empty, filename-like, id-like, URL-like and generic titles", () => {
  for (const raw of [
    undefined, null, 5, "", "   ", "abc",
    "paper.pdf", "2510.26692v2.pdf", "Paper.PDF", "main.tex", "draft.docx", "slides.pptx",
    "2510.26692", "2510.26692v1", "arXiv:2510.26692", "cs.CL/0301012", "a439842ff6",
    "https://arxiv.org/abs/2510.26692", "arxiv.org/abs/2510.26692", "www.example.com",
    "Untitled", "untitled 2", "Microsoft Word - final.docx", "[2510.26692]", "index", "Main",
  ]) {
    assert.equal(cleanTitle(raw, "https://example.com/x.pdf"), null, JSON.stringify(raw));
  }
});

test("cleanTitle caps runaway titles", () => {
  const long = "Word ".repeat(200);
  assert.ok(cleanTitle(long, "https://example.com/").length <= 300);
});

// ---- deep link ---------------------------------------------------------------------------

test("buildDeepLink encodes the target and only adds title when present", () => {
  assert.equal(
    buildDeepLink(ABS),
    "pdflite://open?url=https%3A%2F%2Farxiv.org%2Fabs%2F2510.26692",
  );
  assert.equal(buildDeepLink(ABS, null), buildDeepLink(ABS));
  assert.equal(buildDeepLink(ABS, ""), buildDeepLink(ABS));

  const title = "Kimi Linear & 注意力 = 100%? #1";
  const link = buildDeepLink("https://example.com/a?x=1&y=2", title);
  // Round-trips through a real URL parser, the way the app's URLComponents reads it.
  const parsed = new URL(link);
  assert.equal(parsed.protocol, "pdflite:");
  assert.equal(parsed.searchParams.get("url"), "https://example.com/a?x=1&y=2");
  assert.equal(parsed.searchParams.get("title"), title);
  assert.equal([...parsed.searchParams.keys()].length, 2);
});

// ---- planOpen ----------------------------------------------------------------------------

test("planOpen for toolbar/shortcut sends the tab URL with a cleaned title", () => {
  const tab = { url: ABS, title: "[2510.26692] Kimi Linear" };
  assert.deepEqual(planOpen("action", { tab }), { ok: true, target: ABS, title: "Kimi Linear" });
});

test("planOpen page item prefers the menu's pageUrl and keeps the tab title", () => {
  const plan = planOpen("page", {
    tab: { url: "https://other.example/", title: "Some Paper Title" },
    info: { pageUrl: "https://aclanthology.org/2020.acl-main.747/" },
  });
  assert.deepEqual(plan, {
    ok: true, target: "https://aclanthology.org/2020.acl-main.747/", title: "Some Paper Title",
  });
});

test("planOpen explains unsupported pages instead of failing silently", () => {
  for (const [url, expected] of [
    ["chrome://extensions", /浏览器内置页面/],
    ["chrome://newtab/", /浏览器内置页面/],
    ["file:///Users/me/a.pdf", /本地文件/],
    ["", /新标签页/],
    [undefined, /新标签页/],
  ]) {
    const plan = planOpen("action", { tab: { url, title: "x" } });
    assert.equal(plan.ok, false, String(url));
    assert.match(plan.reason, expected, String(url));
  }
});

test("planOpen link/selection never send a title", () => {
  assert.deepEqual(
    planOpen("link", { tab: { title: "Page Title Here" }, info: { linkUrl: "https://example.com/a.pdf" } }),
    { ok: true, target: "https://example.com/a.pdf", title: null },
  );
  assert.deepEqual(
    planOpen("selection", { tab: { title: "Page Title Here" }, info: { selectionText: "arXiv:2510.26692" } }),
    { ok: true, target: ABS, title: null },
  );
});

test("planOpen rejects unusable links and selections with a reason", () => {
  const link = planOpen("link", { info: { linkUrl: "mailto:a@b.c" } });
  assert.equal(link.ok, false);
  assert.match(link.reason, /链接/);

  const selection = planOpen("selection", { info: { selectionText: "just some words" } });
  assert.equal(selection.ok, false);
  assert.match(selection.reason, /没有识别到/);

  assert.equal(planOpen("selection", { info: {} }).ok, false);
  assert.equal(planOpen("bogus").ok, false);
});

// ---- context menu patterns ---------------------------------------------------------------

// Minimal Chrome match-pattern matcher, enough to check our own list.
function matchesPattern(pattern, url) {
  const m = pattern.match(/^(\*|https?):\/\/([^/]+)(\/.*)$/);
  assert.ok(m, `not a match pattern: ${pattern}`);
  const [, scheme, host, path] = m;
  const u = new URL(url);
  if (scheme !== "*" && `${scheme}:` !== u.protocol) return false;
  if (!["http:", "https:"].includes(u.protocol)) return false;
  if (host !== "*") {
    if (host.startsWith("*.")) {
      const base = host.slice(2);
      if (u.hostname !== base && !u.hostname.endsWith(`.${base}`)) return false;
    } else if (u.hostname !== host) {
      return false;
    }
  }
  const glob = new RegExp(`^${path.replace(/[.+?^${}()|[\]\\]/g, "\\$&").replace(/\*/g, ".*")}$`);
  return glob.test(u.pathname + u.search);
}

const onPaperPage = (url) => PAPER_PAGE_PATTERNS.some((p) => matchesPattern(p, url));

test("page menu is not offered where the app cannot download (bot-challenged hosts)", () => {
  for (const url of [
    "https://openreview.net/forum?id=rJXMpikCZ",
    "https://www.biorxiv.org/content/10.1101/2020.03.22.002386v1",
    "https://www.medrxiv.org/content/10.1101/2020.03.09.20033217v1",
  ]) {
    assert.ok(!onPaperPage(url), url);
  }
});

test("page menu appears on paper hosts and direct PDFs", () => {
  for (const url of [
    "https://arxiv.org/abs/2510.26692",
    "https://export.arxiv.org/abs/2510.26692",
    "https://aclanthology.org/2020.acl-main.747/",
    "https://huggingface.co/papers/2510.26692",
    "https://www.alphaxiv.org/abs/2510.26692",
    "https://alphaxiv.org/overview/2510.26692",
    "https://proceedings.mlr.press/v139/radford21a.html",
    "https://openaccess.thecvf.com/content/ICCV2023/html/K_paper.html",
    "https://papers.nips.cc/paper_files/paper/2017/hash/3f5e-Abstract.html",
    "https://proceedings.neurips.cc/paper_files/paper/2022/hash/0022-Abstract-Conference.html",
    "https://github.com/owner/repo/blob/main/paper.pdf",
    "https://example.com/files/paper.pdf",
    "https://example.com/download/paper.pdf?token=abc",
  ]) {
    assert.ok(onPaperPage(url), url);
  }
});

test("page menu stays out of the way elsewhere", () => {
  for (const url of [
    "https://example.com/",
    "https://www.google.com/search?q=paper",
    "https://github.com/owner/repo",
    "https://github.com/owner/repo/issues/1",
    "https://huggingface.co/models",
    "https://news.ycombinator.com/item?id=1",
    "https://notarxiv.org/abs/1",
  ]) {
    assert.ok(!onPaperPage(url), url);
  }
});

test("every pattern is a syntactically valid match pattern", () => {
  for (const pattern of PAPER_PAGE_PATTERNS) {
    assert.match(pattern, /^\*:\/\/(\*|\*\.[a-z0-9.-]+|[a-z0-9.-]+)\/\S*$/, pattern);
  }
});
