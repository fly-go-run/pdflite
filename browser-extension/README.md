# PDFLite 浏览器联动

浏览器里看到 arXiv 论文,一键丢给 PDFLite 打开。底层都是同一条深链:

```
pdflite://open?url=<百分号编码的目标链接>[&title=<百分号编码的页面标题>]
```

`title` 可选(旧链接和 Bookmarklet 不带也完全兼容)。App 收到后走完整的「从 URL 打开」流水线:
已下载过的秒开本地文件(不弹面板),没下载过的弹进度面板下载、用论文标题命名入库;
下载途中又收到的链接会排队,逐篇打开,某一篇失败不影响后面的。

## 方式一:Chrome 系插件(Chrome / Edge / Arc / Brave)

1. 打开 `chrome://extensions`(Edge 是 `edge://extensions`)
2. 右上角开启「开发者模式」
3. 点「加载已解压的扩展程序」,选择本目录(`browser-extension/`)

更新代码后在扩展页点一下该扩展的「重新加载」即可(右键菜单会自动重建)。

用法:

- **工具栏按钮 / 快捷键 `Alt+Shift+P`**:在 arXiv 摘要页 / PDF 页、GitHub 的 PDF blob 页等点一下 → PDFLite 打开当前页面。
  快捷键可在 `chrome://extensions/shortcuts` 改键(找「PDFLite Opener」的「激活扩展程序」)。
- **右键页面** → 「用 PDFLite 打开此页面」:只在 App 能下载的论文站点出现(arXiv、ACL Anthology、
  Hugging Face Papers、alphaXiv、PMLR、CVF、NeurIPS、GitHub blob 页,以及 `*.pdf` 直链),
  其他页面不打扰(OpenReview、bioRxiv / medRxiv 见下文,不在此列);任何页面都可以用工具栏按钮 / 快捷键。
- **右键链接** → 「用 PDFLite 打开链接」:不用先进入页面,列表页直接右键论文链接即可。
- **右键选中文字** → 「用 PDFLite 打开所选链接/编号」:选中 `arXiv:2510.26692`、`2510.26692v2`、
  `cs.CL/0301012` 或一段 http(s) 链接(参考文献里跨行折断的链接也能拼回去)即可;识别不到会给出提示。
- 首次触发浏览器会问「打开 PDFLite?」,勾选「始终允许」以后就是纯一键

**操作反馈**:每次操作后工具栏图标会短暂出现徽标——绿色 ✓ 表示已发送给 PDFLite;红色 ! 表示没能发送,
鼠标悬停图标可看原因(例如浏览器内置页 `chrome://`、新标签页、本地 `file://` 文件——本地文件请直接用 PDFLite 的 ⌘O 或拖入)。

**标题传递**:工具栏 / 快捷键 / 右键页面会把标签页标题一并带给 App,作为下载后的文件名
(自动去掉 `[2510.26692] ` 前缀、`Paper page - `、`| alphaXiv` 等站点噪声;空标题、`xxx.pdf` 之类文件名、
arXiv PDF 标签页、GitHub 与 CVF 这类标题无意义的站点不传,交给 App 用 arXiv API 或链接推断)。
右键链接 / 选中文字不带标题。标题在 App 侧会再次校验和净化,不会影响文件路径。

权限与之前一致,只有 `contextMenus` 和 `activeTab`,不读取页面内容、不联网。

### App 侧的站点归一化

以下「网页壳」链接会在下载前(以及去重判断前)自动改写成真正的 PDF,所以不同写法的同一篇论文只会入库一次:

| 站点 | 改写 |
|---|---|
| arXiv(abs / pdf / html / 裸编号 / `arXiv:` 前缀) | `https://arxiv.org/pdf/<id>` |
| huggingface.co/papers/`<id>`、alphaxiv.org/abs 或 overview/`<id>` | 同上(编号在路径里) |
| aclanthology.org/`<论文编号>/` | `…/<论文编号>.pdf` |
| proceedings.mlr.press/vN/`<name>`.html | vN ≥ 54:`/vN/<name>/<name>.pdf`;更早卷:`/vN/<name>.pdf` |
| openaccess.thecvf.com `…/html/X_paper.html` | `…/papers/X_paper.pdf` |
| papers.nips.cc / proceedings.neurips.cc `…/hash/<hash>-Abstract….html` | `…/file/<hash>-Paper….pdf` |
| GitHub blob / raw | `raw.githubusercontent.com/…` |

短链(如 t.co)如果重定向到上述论文页面,App 会自动改用归一化后的地址重试一次。
其余站点凡是直链 PDF 都能开。**OpenReview、bioRxiv / medRxiv 暂不支持**:它们的 PDF 地址对非浏览器请求
返回 403/429 的人机验证,App 无法下载(不做 Cookie 下载)。

## 方式二:Bookmarklet(任何浏览器,包括 Safari)

新建一个书签,名称随意(如「→ PDFLite」),网址填:

```
javascript:location.href='pdflite://open?url='+encodeURIComponent(location.href)
```

在论文页面点这个书签即可。想顺带传标题可在末尾加 `+'&title='+encodeURIComponent(document.title)`。

## 开发

纯逻辑(URL/编号提取、标题清洗、可用性检查、右键菜单匹配范围)在 `lib.js`(ES module),
`background.js` 只做浏览器调用。无需 npm / 构建。测试用 Node 自带的测试运行器(需 Node 22+):

```
node --test browser-extension/test/*.test.mjs
```
