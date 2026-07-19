# PDFLite 浏览器联动

浏览器里看到 arXiv 论文,一键丢给 PDFLite 打开。底层都是同一条深链:

```
pdflite://open?url=<百分号编码的目标链接>
```

App 收到后走完整的「从 URL 打开」流水线:已下载过的秒开本地文件,没下载过的
弹进度面板下载、用论文标题命名入库。

## 方式一:Chrome 系插件(Chrome / Edge / Arc / Brave)

1. 打开 `chrome://extensions`(Edge 是 `edge://extensions`)
2. 右上角开启「开发者模式」
3. 点「加载已解压的扩展程序」,选择本目录(`browser-extension/`)

用法:

- **工具栏按钮**:在 arXiv 摘要页 / PDF 页点一下 → PDFLite 打开当前页面
- **右键链接** → 「用 PDFLite 打开链接」:不用先进入页面,列表页直接右键论文链接即可
- 首次触发浏览器会问「打开 PDFLite?」,勾选「始终允许」以后就是纯一键

## 方式二:Bookmarklet(任何浏览器,包括 Safari)

新建一个书签,名称随意(如「→ PDFLite」),网址填:

```
javascript:location.href='pdflite://open?url='+encodeURIComponent(location.href)
```

在论文页面点这个书签即可。
