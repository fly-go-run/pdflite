// 把目标 URL 转成 pdflite://open 深链并在当前标签页触发。
// 自定义 scheme 不会真正导航离开页面 —— 浏览器只弹一次"打开 PDFLite?"确认
// (勾选"始终允许"后不再询问),页面本身保持原样。
function openInPDFLite(tabId, url) {
  if (!url || !/^https?:\/\//i.test(url)) return;
  const deepLink = "pdflite://open?url=" + encodeURIComponent(url);
  chrome.tabs.update(tabId, { url: deepLink });
}

// 工具栏按钮:发送当前页面(arXiv 摘要页/PDF 页都行,app 侧会归一化)。
chrome.action.onClicked.addListener((tab) => {
  openInPDFLite(tab.id, tab.url);
});

chrome.runtime.onInstalled.addListener(() => {
  chrome.contextMenus.create({
    id: "pdflite-open-link",
    title: "用 PDFLite 打开链接",
    contexts: ["link"],
  });
  chrome.contextMenus.create({
    id: "pdflite-open-page",
    title: "用 PDFLite 打开此页面",
    contexts: ["page"],
  });
});

chrome.contextMenus.onClicked.addListener((info, tab) => {
  if (!tab) return;
  const target = info.menuItemId === "pdflite-open-link" ? info.linkUrl : info.pageUrl;
  openInPDFLite(tab.id, target);
});
