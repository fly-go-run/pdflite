# macOS 自用学术 PDF 阅读器：精简技术方案

> 2026-05-05 更新：本文件保留 Claude 原始方案，最终定案见 [plan-final.md](./plan-final.md)。
> 采纳点：SwiftUI 主壳、PDFKit/PDFView 核心阅读区、GRDB sidecar、NSPanel 浮卡、差异化功能优先。
> 修正点：API Key 改用 Keychain；保留轻量 `baseURL + model + targetLanguage` 配置；DeepSeek 模型名以官方文档为准，当前优先 `deepseek-v4-flash`，`deepseek-chat`/`deepseek-reasoner` 已标注将在 2026-07-24 废弃。
> 不采纳点：把 API Key 放 `Secrets.swift`、完全硬编码 DeepSeek、不做任何设置入口。

**前提条件**：自己用、不上架 MAS、不分发给他人、不商业化。这让技术选型可以大幅激进化。

**原始技术栈一句话**：**SwiftUI + NSViewRepresentable 包 PDFKit + @Observable/MVVM + GRDB 旁置 SQLite + NSPanel 浮卡 + URLSession 流式 SSE 直连 DeepSeek**。无沙盒、无公证、无 Sparkle、无完整 Provider 抽象。Keychain 和轻量配置已在最终方案中修正为保留。

预估 **6–8 周**（每周 10–15 小时）做到自用稳定版本。比商业化路线少 4–6 周，省下的时间应该投到差异化体验（Smart Jump、双语常驻面板、长 context 全文问答、与 FlowNote 联动）。

---

## 一、自用场景下可以直接砍掉的东西

| 砍掉的 | 原因 | 节省时间 |
|---|---|---|
| App Sandbox | 不上 MAS。砍掉后 security-scoped bookmark、文件权限弹窗、Open Recent 困境全消失 | 1 周 |
| Hardened Runtime + 公证 + Developer ID | 不分发。Xcode Personal Team 免费签名即可，或 ad-hoc `codesign --force --deep --sign -` | 0.5 周 |
| Sparkle 自动更新 | 自用直接 Xcode Run，要更新就 git pull + Cmd+R | 0.5 周 |
| Apple Developer Program $99/年 | 同上 | $99 |
| 多 LLM Provider 抽象 | 只用 DeepSeek（或加一个 Claude），单类硬编码即可 | 3–5 天 |
| ~~Keychain 存 API Key~~ | 旧判断已废弃。最终方案保留 Keychain，避免 API Key 进入配置文件或 git 历史 | ~~1–2 天~~ |
| 注释导出回 PDF / 跨工具兼容 | 不需要给别人传 | 3–5 天 |
| security-scoped bookmark | 没沙盒后直接存绝对路径 | 2–3 天 |

**MuPDF 重新可选但仍不推荐做主引擎**：AGPL 自用不触发，但 macOS 无 SPM 集成、需自 build C 库 + bridging header，集成成本仍高于价值。仅作为后期 PDFKit 在特定 PDF 上崩溃时的兜底备选（替代 PDFium 的位置，文本提取质量更好、API 更人性化）。

---

## 二、调整后的开发路线图

### Phase 0 — 环境（30 分钟）

新建 Xcode macOS App 项目，最低 macOS 14（覆盖 `@Observable`），**勾掉 App Sandbox + Hardened Runtime**，加 GRDB SPM 依赖。完事。

### Phase 1 — MVP 阅读器（2 周）

不变。核心工作量在这。

- `WindowGroup(for: URL.self)` 多窗口
- `PDFKitView: NSViewRepresentable` 包 `PDFView`
- `autoScales = true`，`displayMode = .singlePageContinuous`
- 文件菜单 + Open Panel + 最近打开
- Cmd+滚轮缩放：Coordinator 重写 `scrollWheel(with:)`，检测 `.command` 修饰键改 `pdfView.scaleFactor`，否则 `nextResponder?.scrollWheel(with: event)`
- 单/双页切换：`displayMode = .singlePageContinuous / .twoUpContinuous`

### Phase 2 — 侧栏/工具栏/搜索（2 周）

不变。

- 左侧目录：SwiftUI `List` + `OutlineGroup` 递归 `PDFOutline`，点击 `pdfView.go(to: outline.destination!)`
- 缩略图：`PDFThumbnailView` 嵌 NSViewRepresentable
- 三栏布局：`NavigationSplitView`，窗口 styleMask 加 `.fullSizeContentView`
- 工具栏：SwiftUI `.toolbar`（macOS 14+ 够用）
- 全文搜索：`PDFDocument.findString(_, withOptions:)`

### Phase 3 — 划词翻译（1 周，原 2 周）

**砍掉**多 Provider 抽象、Keychain、配置 UI。

- 选区监听：`NSNotification.Name.PDFViewSelectionChanged` + 250ms 防抖
- 坐标转换：`selection.bounds(for: page)` → `pdfView.convert(_:from: page)` → `pdfView.convert(_:to: nil)` → `window.convertToScreen(_)`
- 浮卡：独立 NSPanel（`.borderless`、`.nonactivatingPanel`、`level = .popUpMenu`、`becomesKeyOnlyIfNeeded = true`）
- 翻译调用：`URLSession.shared.bytes(for:)` + `for try await line in bytes.lines` 解析 SSE，`AsyncThrowingStream<String, Error>` 流式输出到 UI
- API Key：`Secrets.swift`（gitignored）或读 `~/.config/myreader/config.json`
- 文本清洗：连字符断行正则 `([A-Za-z]{2,})-\s*\n\s*([a-z]{2,})` 合并 + soft hyphen `\u00AD` 删除，或直接 system prompt 让 LLM 处理

### Phase 4 — 注释持久化（1–1.5 周，原 2–3 周）

**砍掉** security-scoped bookmark、导出回 PDF、跨设备同步。

- GRDB schema 简化：
  - `Document(id, fileURL, fileHash, title, lastOpened, lastPage, lastZoom)` — 直接存绝对路径，文件移动了重新打开即可
  - `Annotation(id, documentId, pageIndex, type, bounds, color, content, createdAt)`
- 高亮：`PDFViewAnnotationHit` 监听创建 `PDFAnnotation` 同时持久化到 SQLite，**不写回 PDF 原文件**
- 阅读位置：存 `PDFView.currentDestination` 的 page index + bounds origin

### Phase 5 — 打磨（1 周）

- 快捷键：⌘F、⌘[/⌘]、⌘+/⌘-、⌘0
- 暗黑模式：`pdfView.invertDisplayColors`
- App Icon、文件关联（Info.plist `CFBundleDocumentTypes`）

### Phase 6（原发布阶段，砍掉）

`Cmd+R` from Xcode 即可使用。或 Archive 一次拷贝 .app 到 `/Applications`，ad-hoc 签名永久跑。

---

## 三、省下的 4–6 周该投到哪里

砍掉分发负担，正确做法是把时间投到 Preview/Chrome/Skim 都做不好的差异化体验。按 ROI 排序：

### 1. Smart Jump：点击 [12] 弹引用预览（最高 ROI）

学术阅读最高频痛点。PDFKit 的 `PDFAnnotation` 本身有 link 信息，但学术论文很多 PDF（尤其 arXiv 的）没正确嵌入 link。

实现路径：
- 划词或鼠标悬停时检测 `[\d+(?:[,\-–]\s*\d+)*]` 正则模式
- 命中后从全文提取 References 段（搜索"References"或"Bibliography" heading 之后的内容）
- 解析对应编号条目（一般是 `[12] Author et al. ...` 或 `12. Author et al. ...`）
- 弹小 NSPanel 显示该条目，附"在 Google Scholar 打开"按钮
- 进阶：检测图表引用 "Figure 3"、"Table 2"，跳到对应页

参考 Sioyek 的 Smart Jump 设计哲学，但用 PDFKit 重写。

### 2. 双语对照常驻面板（高 ROI）

沉浸式翻译做得好的核心是中英对照不打断阅读流。当前你画的方案是每次弹浮卡，长论文体验差。

改进：
- 工具栏加"对照模式"开关
- 开启后右侧固定一个 Inspector（SwiftUI `.inspector` macOS 14+ 原生支持）
- 划任何段落 → 译文流式追加到 Inspector，按时间倒序
- 每条带"跳回原文位置"按钮（点击 PDFView 滚到该 selection.bounds）
- 整篇翻译模式：按页喂给 LLM（参考 davideuler/pdf-translator-for-human 的分页缓存策略），右侧从头到尾对照显示

### 3. 长 context 全文问答（中高 ROI）

你做 AI infra，DeepSeek 64K context 长论文够用，不需要 RAG。

实现：
- 工具栏 "Ask" 按钮 → 弹 chat 面板
- 第一次打开论文时 `PDFDocument.string` 提全文（学术论文一般 30–50K tokens）
- 缓存到 SQLite 的 Document 表加 `fullText` 字段
- 每次提问 system prompt 带全文 + 用户问题 → 流式输出
- 进阶：让 LLM 输出引用页码（如"参见 §3.2"），点击页码跳转

### 4. 与 Mako/FlowNote 联动（中 ROI，但战略价值高）

两个自用工具串起来 > 单独两个工具。

实现：
- 划词翻译浮卡加 `⌘⇧S` "保存到笔记"按钮
- 格式：
  ```markdown
  > 原文（论文标题, p.页码）
  > 
  > 译文
  ```
- 通过 macOS `NSWorkspace.shared.open(URL(string: "flownote://append?content=..."))` 调起 FlowNote
- 或者直接写文件到 FlowNote watch 的目录
- FlowNote 端做对应的 URL scheme handler（如果还没有）

这一步会让你的工作流形成闭环，**比任何单点功能都更值钱**。

### 5. 论文相关性的轻量化：扫描 + 元数据（低优先级）

如果有空，加一个"打开过的论文库"视图：
- 提取 PDF metadata（title、author、DOI）
- DOI 调 `api.crossref.org/works/{doi}` 拉准确元数据 + 引用数
- 列表+搜索+标签

但这一步会让项目从"阅读器"扩展成"文献管理器"，是 Zotero 的领域，**慎入**。除非你确实想替代 Zotero。

---

## 四、不变的关键决策

这些在自用/商业版本下都成立：

- **PDFKit 做主体引擎**：性能上限 = Safari/Preview，没必要用 PDFium/PDF.js。
- **SwiftUI 主壳 + NSViewRepresentable 包 PDFView**：2024–2025 macOS 原生开发现实。
- **`@Observable` + 简单 MVVM，不上 TCA**：单人项目过度工程。
- **GRDB.swift 旁置 SQLite，不用 SwiftData**：稳定、性能好、没坑。
- **不全靠 PDF 原生注释**：Skim 早期把注释存 HFS+ 扩展属性丢失过的教训。
- **NSPanel 浮卡而不是 NSPopover**：popover 在全屏 PDF 上各种不友好。

---

## 五、必装的 3 个库（砍到最少）

- [GRDB.swift](https://github.com/groue/GRDB.swift) — SQLite 持久化
- [swift-markdown-ui](https://github.com/gonzalezreal/swift-markdown-ui) — 渲染 LLM markdown 输出
- [KeyboardShortcuts](https://github.com/sindresorhus/KeyboardShortcuts) — 全局快捷键（如果做 FlowNote 联动需要）

**不需要**：MacPaw/OpenAI（直接 URLSession + SSE 30 行搞定，多一层抽象不如不要）、Sparkle、KeychainAccess、DSFToolbar（SwiftUI 14 toolbar 够用）。

---

## 六、关键参考项目（直接抄代码）

- [PageFlow](https://github.com/pinchen147/PageFlow) — 2025 年 11 月新出的纯 SwiftUI+PDFKit 项目，多窗口+per-window undo+Recent Files 的正确做法。**第一周就 clone 下来读完。**
- [Yiiipu/SimplePDF](https://github.com/Yiiipu/SimplePDF) — 最小可行 PDFKit + 划词调 LLM + 引用页码
- [Skim](https://skim-app.sourceforge.io/) trunk 的 `SKMainWindowController`、`SKPDFView`（继承 `PDFView`）、`SKNote*` — 学术 PDF 阅读 20 年金标准的具体代码
- [zotero-pdf-translate](https://github.com/windingwind/zotero-pdf-translate) — 翻译 UX 细节（分隔符包裹译文便于重译、正则去 LLM 思考标签）
- [macai](https://github.com/Renset/macai) — macOS 原生 LLM 客户端架构（虽然你不需要多 Provider 抽象，但流式渲染和聊天 UI 可借鉴）

---

## 七、12 个不变的坑

无论自用还是商用，这些坑都会踩到，提前知道：

1. **PDFKit 历史 bug 多** — `PDFDocument(url:)` 必须 try/catch；不要写 `creationDateAttribute`（已知崩溃源）
2. **PDFView 切 document 闪屏**（Apple Forums 763408） — `updateNSView` 守卫 `if pdf != pdfView.document` 并 `layoutDocumentView()`
3. **大量注释+缩放卡顿** — 缩放手势期间 `annotations.shouldDisplay = false`，结束恢复
4. **多列文本高亮跨列 bug** — PDFKit 已知问题，需应用层列检测或后期 fallback PDFium/MuPDF
5. **PDFView 内嵌 SwiftUI ScrollView 会丢内容** — 让 PDFView 自己当滚动容器
6. **Cmd+滚轮 vs trackpad pinch** — 区分 `event.phase`，否则双重缩放
7. **NSToolbar 高级定制需下沉 AppKit** — 搜索字段位置、动态显示
8. **SwiftUI 内存泄漏** — 闭包捕获 self、`@StateObject` 误用为 `@ObservedObject`、Environment 大对象。Instruments → Allocations + SwiftUI template
9. **DeepSeek/OpenAI 流式错误响应** — 失败时第一行可能不是 `data:` 而是 error JSON，先尝试 JSON 解析
10. **Outline 中文乱码** — 部分 PDF 用 PDFDocEncoding/UTF-16BE 混合，PDFKit 偶发解码失败，自己解析或 `PDFOutline.label` 兜底
11. **学术 PDF 数学公式复制乱码** — glyph 拆分后丢失语义，检测"非字母数字>30%"提示截图翻译或调 Vision framework
12. **CJK 文本段内换行处理** — 中文段落内换行应直接删除（与英文连字符规则相反）

---

## 总结

自用场景下，**真正的工程任务就 6 周**：2 周 MVP + 2 周阅读体验 + 1 周翻译 + 1 周注释。剩下的时间全部投在差异化（Smart Jump、双语面板、全文问答、FlowNote 联动）上才是正确选择。

你已经有 Mako/FlowNote 这一手，把 PDF Reader 做成「论文阅读 → 划词翻译 → 笔记沉淀」工作流的入口节点，比单做一个"流畅的 PDF 阅读器"价值高一个量级。
