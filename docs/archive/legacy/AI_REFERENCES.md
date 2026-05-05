# AI_REFERENCES.md

本文件是参考项目地图。AI Coding 在写每个模块前，必须先在 `references/` 里通过 grep 或 find 找到对应代码，再写本项目实现。

## 1. setup

推荐第一批只拉 4 个核心参考项目。

```bash
mkdir -p references

git submodule add https://github.com/pinchen147/PageFlow references/PageFlow
git submodule add https://github.com/JackieXie168/skim references/skim
git submodule add https://github.com/Renset/macai references/macai
git submodule add https://github.com/frameworker/PDFAnnotationEditor references/PDFAnnotationEditor

git submodule status > references/REFERENCE_LOCK.txt

git add .gitmodules references/REFERENCE_LOCK.txt
git commit -m "chore: lock reference projects"
```

可选 UX 参考项目不要默认拉入 submodule。需要 Phase 3 或 Phase 4 时再临时 clone 到 `references_optional/`。

```bash
mkdir -p references_optional

git clone https://github.com/tisfeng/Easydict references_optional/Easydict
git clone https://github.com/windingwind/zotero-pdf-translate references_optional/zotero-pdf-translate
git clone https://github.com/Yiiipu/SimplePDF references_optional/SimplePDF
git clone https://github.com/ahrm/sioyek references_optional/sioyek
```

原因：这些项目主要用于 UX 和概念参考，且 GPL 或 AGPL 许可证更敏感，避免 AI 误复制源码。

## 2. 参考项目优先级

### 2.1 必读项目

1. PageFlow
   语言：Swift + SwiftUI + PDFKit。
   许可证：Apache 2.0。
   用途：SwiftUI + PDFKit 主骨架、多窗口、工具栏、搜索、单双页、注释结构。
   规则：可参考实现结构和关键 API 用法。复制超过少量片段时记录 license notice。

2. Skim (JackieXie168 fork)
   语言：Objective-C + AppKit + PDFKit。
   许可证：BSD-style。
   用途：PDFKit 深水区行为，包括 `PDFView` 子类、selection、annotation、outline、thumbnail、窗口协调。
   规则：只按需 grep，不通读整个项目。不要把 Obj-C 直接翻成伪 Swift。

3. Apple PDFKit 官方文档
   用途：API 校验最终源。
   规则：涉及 PDFKit 的代码，必须能对应到官方类或方法。

4. PDFAnnotationEditor
   语言：Swift。
   许可证：MIT。
   用途：PDFAnnotation 创建、编辑、hit testing。
   规则：可参考 annotation API 用法。

5. macai
   语言：Swift + SwiftUI。
   许可证：Apache 2.0。
   用途：URLSession SSE 流式调用、错误处理、流式 UI 更新。
   规则：只参考网络流式部分，不引入 Provider 抽象、CoreData、iCloud Sync。

### 2.2 后续概念参考

1. Easydict
   用途：macOS 划词翻译浮卡、翻译窗口 UX。
   规则：GPL 项目，只看概念，不复制源码。

2. zotero-pdf-translate
   用途：学术翻译 prompt、PDF 文本清洗、翻译 UX。
   规则：AGPL 项目，只看概念，不复制源码。

3. SimplePDF
   用途：PDF + LLM 的最小闭环、页码引用思路。
   规则：GPL 项目，只看概念。

4. Sioyek
   用途：Smart Jump、reference preview、figure/table 跳转。
   规则：GPL + C++/Qt，只看产品行为和 README。

## 3. Apple 官方文档

PDFKit API 以 Apple 文档为准。

1. PDFKit 总览
   https://developer.apple.com/documentation/pdfkit

2. PDFView
   https://developer.apple.com/documentation/pdfkit/pdfview

3. PDFDocument
   https://developer.apple.com/documentation/pdfkit/pdfdocument

4. PDFSelection
   https://developer.apple.com/documentation/pdfkit/pdfselection

5. PDFAnnotation
   https://developer.apple.com/documentation/pdfkit/pdfannotation

6. PDFKit Programming Guide
   https://developer.apple.com/library/archive/documentation/GraphicsImaging/Conceptual/PDFKitGuide/PDFKit_Prog_Conc/PDFKit_Prog_Conc.html

7. NSViewRepresentable
   https://developer.apple.com/documentation/swiftui/nsviewrepresentable

如果 grep 没找到对应 API，官方文档也没有该 API，不允许猜 Swift 方法名。

## 4. 模块 1：SwiftUI 包 PDFView 主骨架

Phase：1。

主参考：PageFlow + Apple 文档。

查找命令：

```bash
find references/PageFlow -iname "*PDF*View*.swift"
find references/PageFlow -iname "*App.swift"
find references/PageFlow -iname "*Recent*.swift"

grep -rn "WindowGroup" references/PageFlow
grep -rn "NSViewRepresentable" references/PageFlow
grep -rn "PDFView" references/PageFlow
grep -rn "scrollWheel" references/PageFlow
grep -rn "scaleFactor" references/PageFlow
```

参考内容：

1. `NSViewRepresentable` 包 PDFView 的方式。
2. SwiftUI 和 PDFView 状态绑定。
3. 多窗口管理。
4. Open Recent。
5. 单页和双页模式。
6. 搜索入口。

禁止复制：

1. sandbox 代码。
2. security-scoped bookmark 代码。
3. 与发布和签名相关的代码。

给 AI 的任务模板：

```text
Phase 1 实现 SwiftUI 包 PDFKit 的 PDFView。
先用 find 和 grep 在 references/PageFlow 找到 PDFView 包装实现。
写一个简化版 PDFKitView。
不要引入 sandbox 和 security-scoped bookmark。
updateNSView 必须避免重复设置 document。
Coordinator 或 ReaderPDFView 负责 Command 加滚轮缩放。
```

## 5. 模块 2：PDFKit 文本选择和坐标转换

Phase：2。

主参考：Skim + Apple PDFSelection 文档。

查找命令：

```bash
grep -rn "PDFViewSelectionChanged" references/skim
grep -rn "selectionsByLine" references/skim
grep -rn "selectionForRange" references/skim
grep -rn "convertPoint:fromPage:" references/skim
grep -rn "boundsForPage:" references/skim

find references/skim -name "SKPDFView.m"
find references/skim -name "SKMainWindowController.m"
```

Objective-C 到 Swift 对照表：

| Objective-C | Swift | 说明 |
|---|---|---|
| `[pdfView currentSelection]` | `pdfView.currentSelection` | 属性，没有括号 |
| `[selection boundsForPage:page]` | `selection.bounds(for: page)` | 选区在某页的 bounds |
| `[selection selectionsByLine]` | `selection.selectionsByLine()` | 仍是方法 |
| `NSNotificationCenter.defaultCenter` | `NotificationCenter.default` | 通知中心 |
| `PDFViewSelectionChangedNotification` | `Notification.Name.PDFViewSelectionChanged` | 选区变化通知 |
| `[pdfView convertPoint:p fromPage:page]` | `pdfView.convert(p, from: page)` | page 坐标转 view 坐标 |
| `[pdfView convertPoint:p toView:nil]` | `pdfView.convert(p, to: nil)` | nil 表示 window 坐标 |
| `[[PDFAnnotation alloc] initWithBounds:bounds forType:@"Highlight" withProperties:nil]` | `PDFAnnotation(bounds: bounds, forType: .highlight, withProperties: nil)` | annotation type 用枚举 |
| `@property (nonatomic) NSColor *color;` | `var color: NSColor` | macOS 用 NSColor |
| `[page addAnnotation:annot]` | `page.addAnnotation(annot)` | 添加注释 |

实现规则：

1. 监听 `Notification.Name.PDFViewSelectionChanged`。
2. 选区为空时隐藏浮卡。
3. 使用 `selection.selectionsByLine()` 处理跨行高亮。
4. 不要用一个大矩形覆盖多行或双栏选区。
5. 浮卡定位需要 page 坐标转 view 坐标，再转 window/screen 坐标。

禁止：

1. 不抄 Skim 的 HFS+ 扩展属性注释存储方式。
2. 不抄 Skim 的 AppleScript scripting。
3. 不让 AI 通读 `SKMainWindowController.m` 全文件，只 grep 相关方法。

给 AI 的任务模板：

```text
Phase 2 实现选区监听和跨行高亮。
先 grep references/skim 里的 PDFViewSelectionChanged 和 selectionsByLine。
参考 Objective-C 到 Swift 对照表重写成 Swift。
所有 PDFKit API 都要能在 Apple PDFSelection 或 PDFView 文档中找到。
```

## 6. 模块 3：高亮、下划线、笔记

Phase：2。

主参考：PDFAnnotationEditor + Skim 行为参考。

查找命令：

```bash
ls references/PDFAnnotationEditor

grep -rn "PDFAnnotation(bounds:" references/PDFAnnotationEditor
grep -rn "addAnnotation" references/PDFAnnotationEditor
grep -rn "highlight" references/PDFAnnotationEditor

grep -rn "annotationAdded" references/skim
grep -rn "annotationRemoved" references/skim
```

实现规则：

1. 选中文本后创建 `.highlight` 类型的 `PDFAnnotation`。
2. 用 `page.addAnnotation()` 显示。
3. 同时保存到 SQLite。
4. 下次打开文档时从 SQLite 恢复 annotation。
5. 第一版不写回原 PDF。

SQLite 保存字段：

1. document_id。
2. page_index。
3. annotation_type。
4. bounds_json，多行 rect。
5. color。
6. selected_text。
7. note_content。
8. created_at 和 updated_at。

给 AI 的任务模板：

```text
Phase 2 实现高亮注释。
先看 references/PDFAnnotationEditor 中 PDFAnnotation 创建方式。
选区高亮要按 selectionsByLine 拆成多个 rect。
注释显示用 PDFKit，持久化用 GRDB。
不要写回原 PDF 文件。
```

## 7. 模块 4：DeepSeek SSE 流式调用

Phase：3。

主参考：macai。

查找命令：

```bash
grep -rn "URLSession.shared.bytes" references/macai
grep -rn "AsyncThrowingStream" references/macai
grep -rn "data:" references/macai

find references/macai -iname "*ChatGPT*"
find references/macai -iname "*APIHandler*"
find references/macai -iname "*MessageParser*"
```

实现规则：

1. 只写 `Features/Translation/DeepSeekClient.swift`。
2. 暴露 `func translate(_ text: String) -> AsyncThrowingStream<String, Error>`。
3. 使用 `URLSession.shared.bytes(for:)`。
4. 逐行解析 SSE。
5. 处理 `[DONE]`。
6. first chunk 可能是 error JSON，要先尝试 JSON 解析。
7. UI 层流式追加输出。
8. API key 从 `~/.config/myreader/config.json` 读取。

禁止：

1. 不引入 Provider 协议。
2. 不引入 OpenAI SDK。
3. 不引入 Alamofire。
4. 不复制 macai 的 CoreData 或 iCloud Sync。

给 AI 的任务模板：

```text
Phase 3 实现 DeepSeekClient。
先 grep references/macai 里的 URLSession.shared.bytes 和 AsyncThrowingStream。
只参考 SSE 解析方式，不引入 Provider 抽象。
API key 从 ~/.config/myreader/config.json 读。
错误响应可能不是 data: 前缀，必须处理。
```

## 8. 模块 5：翻译 Prompt 设计

Phase：3。

主参考：zotero-pdf-translate，概念参考，不复制代码。

如果已拉取可选参考：

```bash
find references_optional/zotero-pdf-translate -name "*.ts" | xargs grep -l "system" | head
grep -rn "hyphen" references_optional/zotero-pdf-translate
grep -rn "newline" references_optional/zotero-pdf-translate
grep -rn "translate" references_optional/zotero-pdf-translate/src | head
```

PromptBuilder 默认模板：

```text
You are an academic translation assistant for a researcher reading English papers in AI, machine learning and computer systems.

Rules:
1. Translate the input English text to Simplified Chinese.
2. Preserve technical terminology with bilingual format on first occurrence: 中文（English）.
3. Preserve LaTeX formulas $...$ and $$...$$ as-is.
4. Preserve citation markers like [12], [3,4], [1-3] in their original positions.
5. The input text may contain artifacts from PDF copy-paste, including hyphenated line breaks, soft hyphens and excessive whitespace. Clean them silently before translating.
6. For paragraphs with CJK characters, treat in-line newlines as no-space joins. For English paragraphs, treat them as space joins.
7. Output only the translation. No preamble, no markdown fences, no unrelated explanations.

Text:
{{selected_text}}
```

LLM 输出清洗：

```swift
let cleaned = response.replacingOccurrences(
    of: "<think>[\\s\\S]*?</think>",
    with: "",
    options: .regularExpression
)
```

可选译文边界：

```text
###TRANSLATION_START###
译文内容
###TRANSLATION_END###
```

## 9. 模块 6：macOS 划词浮卡 NSPanel

Phase：3。

主参考：Easydict，概念参考，不复制 GPL 源码。

如果已拉取可选参考：

```bash
find references_optional/Easydict -iname "*Window*Manager*"
find references_optional/Easydict -iname "*Floating*"
grep -rn "addGlobalMonitor" references_optional/Easydict
grep -rn "screen" references_optional/Easydict | grep -i "frame\|bound\|clamp"
```

实现规则：

1. 不使用 NSPopover。
2. 使用独立 NSPanel。
3. 浮卡内容使用 SwiftUI，嵌入 NSHostingController。
4. 不监听全局选区，只监听当前 PDFView 内的选区。
5. 点击外部关闭。
6. 屏幕边界 clamp。
7. 流式翻译逐 token 渲染。

推荐 NSPanel 配置：

```swift
let panel = NSPanel(
    contentRect: rect,
    styleMask: [.borderless, .nonactivatingPanel],
    backing: .buffered,
    defer: false
)
panel.level = .popUpMenu
panel.becomesKeyOnlyIfNeeded = true
panel.isFloatingPanel = true
```

给 AI 的任务模板：

```text
Phase 3 实现划词翻译浮卡。
用 NSPanel + NSHostingController。
不要用 NSPopover。
不要监听全局选区。
选区变化来自 PDFViewSelectionChanged。
浮卡需要屏幕边界 clamp，点击外部关闭。
```

## 10. 模块 7：学术 PDF 文本清洗

Phase：3。

核心实现直接写在本项目，不需要引入 NLP 依赖。

Swift regex：

```swift
let dehyphenated = text.replacingOccurrences(
    of: "([A-Za-z]{2,})-\\s*\\n\\s*([a-z]{2,})",
    with: "$1$2",
    options: .regularExpression
)

let withoutSoftHyphen = dehyphenated.replacingOccurrences(of: "\u{00AD}", with: "")

let normalized = withoutSoftHyphen.replacingOccurrences(
    of: "\\s+",
    with: " ",
    options: .regularExpression
)
```

规则：

1. 英文连字符断行合并。
2. soft hyphen 删除。
3. 英文多余空白合并为一个空格。
4. CJK 段落内换行直接删除。
5. 数学公式复制乱码时提示用户改小选区或截图翻译。

## 11. 模块 8：Smart Jump

Phase：4。

主参考：Sioyek，概念参考，只看 README 和产品行为。

如果已拉取可选参考：

```bash
cat references_optional/sioyek/README.md | grep -A 30 "Smart"
```

PDFKit 复刻路径：

1. `ReaderPDFView` 监听 `mouseMoved`。
2. 鼠标停留超过 300ms 后，取当前 page。
3. 使用当前鼠标位置附近的 line selection。
4. 正则匹配引用编号、Figure、Table、Equation。
5. 引用编号从 References 段落解析。
6. Figure 和 Table 通过全文搜索定位。
7. 用 NSPanel 展示预览。
8. 点击跳转并记录返回位置。

正则示例：

```swift
let citationPattern = #"\[(\d+(?:[,\-–]\s*\d+)*)\]"#
let figurePattern = #"(?:Figure|Fig\.|Table|Eq\.)\s*\d+"#
```

## 12. AI Coding 工作流

### 12.1 Session 启动 prompt

```text
请先读这三个文件：
1. AGENTS.md
2. docs/ARCHITECTURE.md
3. docs/AI_REFERENCES.md

然后告诉我：
1. 当前应该处于哪个 Phase。
2. 这个 Phase 允许参考哪些项目。
3. 这个 Phase 禁止参考哪些项目。
4. 你准备先实现哪个最小功能。
```

### 12.2 写新功能前 prompt

```text
现在实现 [功能名]。
在写任何代码前：
1. 在 references/ 里 grep 相关关键字，找到对应实现。
2. 告诉我你具体看了哪个文件、哪个方法。
3. 如果涉及 PDFKit，给出 Apple 官方文档 URL。
4. 确认当前 Phase 允许参考该项目。
5. 确认不会引入 AGENTS.md 禁止项。
做完后再开始写代码。
```

### 12.3 写完代码后的自检三问

```text
你刚写的代码请自答：
1. 参考了 references/ 里哪个项目、哪个文件、哪个方法？
2. 这段 PDFKit API 在 Apple 官方文档里的对应类是什么？给出 URL。
3. 这段代码有没有引入 AGENTS.md 禁止的依赖、架构或功能？
答不出来或答得含糊就重写。
```

## 13. 跑偏识别速查

| 跑偏症状 | 纠正话术 |
|---|---|
| 出现 `UIView` / `UIViewRepresentable` | macOS only，use NSView equivalents |
| 调用 `pdfView.startSelection()` 等不存在方法 | 先 grep references/，再查 Apple 文档 |
| 出现 `@Model` 或 `NSManagedObject` | 用 GRDB，禁止 SwiftData/CoreData |
| 出现 `startAccessingSecurityScopedResource` | 项目不开沙盒，删除 bookmark 代码 |
| Obj-C 方法翻译错 | 看本文件 Objective-C 到 Swift 对照表 |
| Package.swift 加了非白名单依赖 | 依赖白名单见 AGENTS.md，其他先询问 |
| 出现 Provider 协议和多实现 | 第一版只用 DeepSeekClient |
| 写了模型切换配置 UI | 第一版不做 Provider 配置 UI |
| 开始做论文库、DOI、标签 | 第一版只做阅读器和划词翻译 |

## 14. Token 使用纪律

1. PageFlow 可以让 AI 通读主要 Swift 文件。
2. Skim 不要通读，只 grep 相关方法。
3. macai 只看 API handler 和 SSE 相关文件。
4. Easydict 只看窗口和浮卡相关文件。
5. zotero-pdf-translate 只看 prompt 和文本清洗思路。
6. Sioyek 只看 README 的 Smart Jump 和 product behavior。
