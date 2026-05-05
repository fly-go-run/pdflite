从截图路径看，你主要在 macOS 上读论文。我会把方案优先按 **macOS 原生桌面端** 来做，跨平台放到第二优先级。

## 结论

最推荐的路线是：

**Swift + AppKit + PDFKit，做一个轻量 macOS 原生 PDF 阅读器。**

理由很直接：你的核心诉求是流畅、低占用、划词翻译、少量高亮、单双页切换和 Command 加滚轮缩放。PDFKit 的 `PDFView` 本身支持 PDF 显示、文本选择、导航、缩放和复制文本，`PDFDisplayMode.twoUp` 支持双页显示，`scaleFactor` 可以控制缩放，高亮也可以用 `PDFAnnotation` 做。([Apple Developer][1])

PDFKit 自身是 Apple 框架，开源实现可以重点参考 **Skim**。Skim 是 macOS 上面向论文阅读和批注的 PDF reader and note taker，很适合作为论文阅读器的交互参考。([Skim][2])

## 现有开源实现怎么参考

**1. Skim，最值得看，适合 macOS 论文阅读器参考**

Skim 的定位就是在 macOS 上阅读和批注 scientific papers，功能方向和你的需求很接近。它的价值主要在高亮、笔记、目录、阅读体验，而不是复杂编辑。你的产品可以借鉴它的论文阅读逻辑，但界面做得更像 Chrome 或 Edge。([Skim][2])

**2. Sioyek，适合参考论文阅读工作流**

Sioyek 是一个专门面向 textbooks 和 research papers 的 PDF viewer，开源仓库显示它提供 Windows、macOS、Linux 安装包，开发分支需要 Qt 6.7 或 6.8。它的论文跳转、目录、书签、引用定位等设计值得研究，但它偏键盘驱动和极客风格，界面方向不太像你截图里的 Chrome。([GitHub][3])

**3. PDF.js，适合快速做 Chrome 风格 UI，但性能需要警惕**

PDF.js 是 Mozilla 支持的 HTML5 PDF viewer，目标是做基于 Web 标准的 PDF 解析和渲染平台，代码开源，适合 Tauri、Electron 或网页应用。它的默认 viewer 结构接近浏览器 PDF 阅读器，上手快，也容易实现划词弹窗。([GitHub][4])

但你已经觉得 Chrome 的 PDF 阅读有点卡，所以继续用 PDF.js 路线时，必须非常重视虚拟滚动、页面缓存、延迟渲染和文本层懒加载。PDF.js FAQ 也提到，PDF 渲染性能和单页大小、文件优化情况有关。([GitHub][5])

**4. MuPDF，适合追求极致性能，但许可证要先想清楚**

MuPDF 是轻量的开源 PDF、XPS、电子书查看和转换框架，性能和体积口碑都很好。它的 GitHub 仓库标注 AGPL 3.0 许可证，如果你的项目闭源或商业化，需要认真处理许可证问题，或者走商业授权。([GitHub][6])

**5. PDFium，适合跨平台高性能原生路线**

PDFium 和 Chromium 工具链关系很近，官方文档提到它使用 Chromium 的构建工具，并给出 Chromium PDF Plugin 作为示例。它更适合 C++ 或 Qt 路线，性能潜力好，但工程集成复杂度高于 PDFKit 和 PDF.js。([Pdfium][7])

**6. Qt PDF，适合跨平台，但文本选择可能要自己做更多**

Qt PDF 提供 `QPdfDocument`、`QPdfPageRenderer`、`QPdfSearchModel` 等类，能加载、渲染和搜索 PDF；`QPdfPageRenderer` 支持渲染队列，也可以用多线程模式；`QPdfSelection` 描述 PDF 单页中的文本选择范围和几何边界。([Qt Documentation][8])

这条路线适合后续做 Windows、Linux、macOS 三端统一，但第一版 macOS 论文阅读器会比 Swift + PDFKit 慢一些进入可用状态。

**7. Okular，适合参考完整批注系统**

Okular 可以查看和批注 PDF、PostScript、Comic Book 等格式，并支持 native PDF annotations。它功能很完整，适合参考批注侧栏、目录、搜索、页面导航，但你的需求更轻，不建议照着做大而全。([GitHub][9])

**8. SumatraPDF，适合参考极简和性能理念**

SumatraPDF 是 Windows 上的多格式阅读器，仓库说明它支持 PDF、EPUB、MOBI、CBZ、CBR、FB2、CHM、XPS、DjVu 等格式，许可证是 GPL 3.0 相关。它对 macOS 价值不在直接复用，而在学习“轻量、少功能、快打开”的产品取舍。([GitHub][10])

**9. Pot 和 Easydict，适合参考划词翻译和服务配置**

Pot 的 README 写明它支持划词翻译、输入翻译、外部调用、OCR、插件系统，并支持 Windows、macOS、Linux。它的插件列表里也有 DeepSeek 翻译插件，插件说明包含模型选择和 API key 配置。([GitHub][11])

Easydict 是 macOS 词典翻译 App，支持离线 OCR、系统翻译、OpenAI、Gemini、DeepL、Google、Bing、腾讯、百度、阿里等服务，适合参考 macOS 翻译弹窗和服务配置体验。([GitHub][12])

## 技术路线推荐

### 第一选择：Swift + AppKit + PDFKit

这是我给你的主方案。

适合：只做 macOS，追求流畅和低占用，功能重点是读论文。

核心结构：

1. `NSWindow` 做主窗口。
2. `NSToolbar` 做顶部工具栏，参考 Chrome PDF 工具栏。
3. `NSSplitView` 做左侧目录和缩略图。
4. `PDFView` 做主阅读区域。
5. 右侧用一个可收起的翻译和高亮面板。
6. 翻译 API 用 `URLSession`。
7. API key 存 macOS Keychain。
8. 设置项用本地 plist 或 SQLite。

这条路线能很快实现：

1. 单页连续阅读。
2. 双页连续阅读。
3. Command 加滚轮缩放。
4. 高亮。
5. 文本选择。
6. 划词后弹出翻译浮窗。
7. 左侧目录和缩略图。
8. 顶部页码、缩放百分比、搜索框。

### 第二选择：C++ + Qt 6 + PDFium 或 Qt PDF

适合：你一开始就想做跨平台版本。

优点是跨平台，长期可控。缺点是第一版会更重，尤其是文本选择、高亮、页面坐标映射、触控板手势和 macOS 原生体验都要投入更多工程量。

### 第三选择：Tauri + PDF.js

适合：你想快速做出 Chrome 样式 UI，并且前端开发更熟。

Tauri 的官方文档说明，它可以用 Web 前端做 UI，用 Rust、Swift、Kotlin 等做后端逻辑，并且通过系统 WebView 减少包体积。([Tauri][13])

但 PDF 渲染本质仍然依赖 PDF.js。你的痛点来自 Chrome 卡顿，这条路线需要重点优化页面虚拟化和缓存。

### 不建议第一版用 Electron

Electron 适合跨平台和 Web 技术栈，但官方文档也明确说它会把 Chromium 和 Node.js 嵌进二进制里，性能很大程度取决于开发者自己的优化。你的第一诉求是轻量流畅，所以第一版用 Electron 风险更高。([Electron][14])

## 划词翻译怎么做

翻译模块建议做成 **OpenAI 兼容 Provider 抽象**，不要把 DeepSeek 写死。

DeepSeek 官方文档写明，它的 API 使用 OpenAI 和 Anthropic 兼容格式，OpenAI 兼容的 `base_url` 是 DeepSeek API 地址，当前模型包括 `deepseek-v4-flash`、`deepseek-v4-pro`，旧的 `deepseek-chat` 和 `deepseek-reasoner` 文档中标注未来会弃用。([DeepSeek API Docs][15])

配置项建议这样设计：

1. 服务名称，例如 DeepSeek、OpenAI、Gemini、本地模型。
2. Base URL。
3. API Key，存 Keychain。
4. Model，可自由输入。
5. 目标语言，默认中文。
6. Prompt 模板。
7. 是否流式输出。
8. 超时时间。
9. 是否缓存相同文本的翻译。
10. 是否自动带上下文，比如选中文本前后各 300 字。

划词交互建议：

1. 用户选中英文文本。
2. 选区旁边弹出小浮窗，显示“翻译、解释术语、复制原文”。
3. 点击翻译后右侧面板或浮窗流式展示结果。
4. 翻译结果包含中文译文、术语解释、公式和缩写保留说明。
5. 只上传选中的文字和少量上下文，不自动上传整篇 PDF。

Prompt 可以设计成这种风格：

```text
你是论文阅读助手。请把下面的英文论文片段翻译成中文。
要求：
1. 保留专业术语，必要时给出括号解释。
2. 保留公式、变量名、引用编号。
3. 先给译文，再给 3 个以内的术语解释。
4. 不要扩写原文没有的信息。

文本：
{{selected_text}}
```

## 高亮和笔记怎么存

有两种路线：

1. **标准 PDF 注释**

   优点是可以被 Preview、Adobe、Okular 等其他 PDF 阅读器识别。适合你未来换工具或者同步文件。PDFKit 的高亮可以用 `PDFAnnotation` 做。([Apple Developer][16])

2. **本地 sidecar 数据**

   例如 `paper.pdf.annotations.json` 或 SQLite。优点是不改原 PDF，保存快，也容易做撤销和同步。缺点是换阅读器后看不到你的高亮。

我的建议是第一版这样做：

1. 默认使用本地 sidecar，保证速度和安全。
2. 提供“导出为 PDF 标准注释”。
3. 高亮数据保存 page index、quad points、颜色、原文、译文、时间戳。
4. 需要兼容其他 PDF 阅读器时再写回 PDF。

## 性能关键点

为了比 Chrome 更流畅，关键不在功能多，关键在渲染策略。

1. 只渲染可视区域附近的页面，例如当前可见页加前后两页。
2. 缩放时先缩放已有 bitmap，用户停下后再重新渲染清晰版本。
3. 页面缓存按 page、scale、display mode、屏幕倍率建立 key。
4. 设置内存上限，超过后 LRU 淘汰。
5. 目录、文本层、缩略图都懒加载。
6. 快速滚动时取消旧的渲染任务。
7. Command 加滚轮缩放要节流，缩放百分比按 5% 或 10% 步进。
8. 高亮时只更新对应页 overlay，避免整页重绘。
9. 翻译请求异步流式返回，不能阻塞 PDFView 主线程。
10. 打开大 PDF 时先显示第一页，目录和缩略图后台生成。

## 界面建议，参考你的截图

主界面可以做成这样：

1. 顶部工具栏
   左侧是侧栏按钮和文件标题，中间是页码输入、总页数、缩放百分比，右侧是单页双页切换、适合宽度、搜索、翻译设置、更多菜单。

2. 左侧栏
   两个 tab：目录和缩略图。默认显示目录，因为读论文时目录比缩略图更常用。

3. 中央阅读区
   深灰背景，白色页面，单页或双页连续滚动。页间距保持类似 Chrome。

4. 右侧栏
   默认隐藏。划词翻译后自动展开，显示译文、术语解释、复制按钮和加入笔记按钮。

5. 浮窗
   选中文本后出现一个小浮窗，只放“翻译”和“高亮”。不要一开始放太多按钮。

## 推荐的 MVP 功能边界

第一版只做这些：

1. 打开本地 PDF。
2. 单页连续和双页连续。
3. Command 加滚轮缩放。
4. 顶部页码跳转和缩放百分比。
5. 左侧目录。
6. 文本选择。
7. 划词翻译。
8. DeepSeek API 配置。
9. 高亮。
10. 保存阅读进度和高亮。

先不要做：

1. 全文翻译。
2. OCR。
3. 手写批注。
4. PDF 编辑。
5. 云同步。
6. 文献管理。
7. 多人协作。
8. 复杂插件系统。

## 最终建议

按你的需求，我建议第一版就走：

**Swift + AppKit + PDFKit + DeepSeek OpenAI 兼容 Provider + 本地 sidecar 高亮数据。**

开源参考顺序：

1. Skim，学习 macOS 论文阅读和批注。
2. Sioyek，学习论文阅读专用功能。
3. PDF.js，学习 Chrome 风格工具栏和 viewer 结构。
4. Pot，学习划词翻译、插件和 API 配置。
5. Okular，学习标准 PDF 注释和侧栏结构。

这条路线最符合你现在的痛点：比浏览器更轻，功能集中在读论文，划词翻译可配置，界面能接近 Chrome 和 Edge。

[1]: https://developer.apple.com/documentation/pdfkit/pdfview?utm_source=chatgpt.com "PDFView | Apple Developer Documentation"
[2]: https://skim-app.sourceforge.io/ "Skim | Home"
[3]: https://github.com/ahrm/sioyek "GitHub - ahrm/sioyek: Sioyek is a PDF viewer with a focus on textbooks and research papers · GitHub"
[4]: https://github.com/mozilla/pdf.js/ "GitHub - mozilla/pdf.js: PDF Reader in JavaScript · GitHub"
[5]: https://github.com/mozilla/pdf.js/wiki/frequently-asked-questions "Frequently Asked Questions · mozilla/pdf.js Wiki · GitHub"
[6]: https://github.com/ArtifexSoftware/mupdf "GitHub - ArtifexSoftware/mupdf: mupdf mirror · GitHub"
[7]: https://pdfium.googlesource.com/pdfium/%2B/master/README.md "PDFium - PDFium"
[8]: https://doc.qt.io/qt-6/qtpdf-index.html "Qt PDF | Qt 6.11.0"
[9]: https://github.com/KDE/okular "GitHub - KDE/okular: KDE document viewer · GitHub"
[10]: https://github.com/sumatrapdfreader/sumatrapdf?utm_source=chatgpt.com "SumatraPDF reader"
[11]: https://github.com/pot-app/pot-desktop/blob/master/README_EN.md "pot-desktop/README_EN.md at master · pot-app/pot-desktop · GitHub"
[12]: https://github.com/tisfeng/easydict "GitHub - tisfeng/Easydict: 一个简洁优雅的词典翻译 macOS App。开箱即用，支持离线 OCR 识别，支持有道词典， 苹果系统词典， 苹果系统翻译，OpenAI，Gemini，DeepL，Google，Bing，腾讯，百度，阿里，小牛，彩云和火山翻译。A concise and elegant Dictionary and Translator macOS App for looking up words and translating text. · GitHub"
[13]: https://v2.tauri.app/start/ "What is Tauri? | Tauri"
[14]: https://electronjs.org/docs/latest "Introduction | Electron"
[15]: https://api-docs.deepseek.com/ "Your First API Call | DeepSeek API Docs"
[16]: https://developer.apple.com/documentation/pdfkit/pdfannotation?utm_source=chatgpt.com "PDFAnnotation | Apple Developer Documentation"

