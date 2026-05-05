# PDFLite 系统设计方案

状态：唯一权威设计文档，后续 AI coding 以本文为准  
更新时间：2026-05-05

本文档是 PDFLite 第一版的唯一权威设计文档。后续 AI coding、架构 review、Phase 拆分、依赖判断、参考项目选择，都以本文为准。`AGENTS.md` 只作为入口文件，旧方案文档放入 `docs/archive/`，不得作为实现基准。

## 1. 设计目标

PDFLite 第一版是一个 macOS 原生学术论文 PDF 阅读器，不是文献管理器，也不是通用 PDF 编辑器。

核心目标：

1. 打开本地 PDF 并提供接近 Preview/Safari 的原生阅读体验。
2. 支持单页连续、双页连续、页码跳转、搜索、目录和缩略图。
3. 支持 Command 加鼠标滚轮缩放，触控板 pinch 交给 PDFKit。
4. 支持文本选择、高亮、删除高亮、阅读位置恢复。
5. 支持划词翻译：选区浮卡、DeepSeek SSE 流式输出、右侧翻译面板、翻译缓存。
6. 所有用户数据使用 SQLite sidecar，不写回原 PDF。
7. AI coding 阶段严格按 Phase 参考 `references/`，避免乱引依赖和过度架构。

非目标：

1. 不做 OCR、全文翻译、手写批注、PDF 编辑、签名、云同步。
2. 不做论文库、标签、DOI 元数据、Zotero 替代能力。
3. 第一版不做完整多 Provider 抽象和模型切换 UI。
4. 第一版不为 App Store、分发、公证、沙盒做额外工程。
5. 第一版不引入 PDFium、MuPDF、PDF.js、Qt、Electron、Tauri。

## 1.1 固定技术栈和禁止项

固定技术栈不可替换，除非用户明确修改本文档：

1. Swift + SwiftUI 做应用外壳，包括窗口、侧栏、工具栏、设置、Inspector。
2. AppKit `PDFView` 子类做核心阅读区，通过 `NSViewRepresentable` 嵌入 SwiftUI。
3. PDFKit 做 PDF 渲染、文本选择、目录、缩略图、搜索、注释。
4. GRDB.swift + SQLite sidecar 做持久化，包括高亮、阅读位置、翻译缓存。
5. URLSession + AsyncThrowingStream 调 DeepSeek OpenAI-compatible streaming API。
6. NSPanel 做划词翻译浮卡，不使用 NSPopover。
7. `@Observable` + 简单 MVVM 做状态管理。
8. 最低支持 macOS 14。

第一版严格禁止：

1. Electron、Tauri、Web 主阅读器、Qt、PDF.js。
2. MuPDF、PDFium、Poppler。
3. CoreData、SwiftData、TCA。
4. App Sandbox、Hardened Runtime、security-scoped bookmark、Sparkle。
5. OpenAI SDK、Alamofire、多 LLM Provider registry。
6. API Key 写入源码、SQLite 或日志。
7. 论文库、标签系统、DOI 抓取、Zotero 替代能力。

第一版依赖白名单：

1. GRDB.swift。
2. swift-markdown-ui。
3. KeyboardShortcuts，仅在需要 FlowNote 联动或全局快捷键时使用。

其他依赖必须先经过用户确认。

## 1.2 许可证和参考代码规则

1. 不复制 GPL、AGPL、LGPL 项目源码，除非用户明确决定本项目采用兼容许可证。
2. GPL、AGPL、LGPL 项目只能参考交互、产品行为、架构思路。
3. PageFlow、PDFAnnotationEditor、macai 可参考实现结构和关键 API 用法。
4. 如复制超过少量代码片段，必须保留对应 LICENSE notice，并在 `THIRD_PARTY_NOTICES.md` 记录来源。
5. Skim 使用 BSD-style 许可证，但它是 Objective-C + AppKit 老工程，默认只做 PDFKit 深水区行为参考。
6. 任何复制行为都要在提交信息里说明来源。

## 2. 总体架构

系统分为六层：

```text
SwiftUI App Shell
  Window / Commands / Toolbar / Sidebar / Inspector / Settings placeholder

Document Session
  每个窗口一个会话，协调 PDF、阅读状态、选区、搜索、翻译、注释

PDF Bridge
  NSViewRepresentable + ReaderPDFView: PDFView
  承接 PDFKit、滚轮、坐标转换、选区事件、运行时 annotation

Domain Services
  DocumentService / SelectionService / AnnotationService / TranslationService / SearchService

Persistence
  GRDB + SQLite sidecar
  documents / annotations / translations / app_settings 或 config mirror

External Inputs
  本地 PDF 文件
  ~/.config/myreader/config.json
  DeepSeek OpenAI-compatible streaming API
```

关键原则：

1. SwiftUI 只负责壳和普通 UI，不直接处理 PDFView 细节。
2. `ReaderPDFView` 只负责 PDF 交互，不直接写数据库，不直接调 LLM。
3. `DocumentSession` 是窗口级协调者，负责把 PDF 事件转成应用状态和服务调用。
4. SQLite 是唯一的第一版持久化来源，不写 PDF 原文件。
5. DeepSeek 调用在 Translation 层内聚，不扩展成 Provider registry。
6. `references/` 只读，不参与应用 target 编译。

## 3. 模块划分

### 3.1 App Shell

职责：

1. 启动 app。
2. 创建主窗口和文档窗口。
3. 提供菜单命令：打开文件、关闭窗口、搜索、缩放、单双页切换。
4. 组织三栏 UI：左侧 Sidebar，中间 PDF Reader，右侧 Inspector。
5. 管理 toolbar 的显示状态和快捷键入口。

建议模块：

```text
App/
  PDFLiteApp
  AppDelegate
  AppCommands

Features/Reader/
  ReaderWindow
  ReaderView
```

设计约束：

1. 每个打开的 PDF 对应一个 `DocumentSession`。
2. 不把多个 PDF 塞进同一个全局 view model。
3. 不做 tab 系统，第一版以多窗口为主。
4. 没有打开文档时，显示轻量空状态和“打开 PDF”入口，不做营销 landing page。

### 3.2 Document Session

`DocumentSession` 是窗口级状态中心，负责协调 PDF、UI 和后台服务。

它应持有或引用：

1. 当前文件 URL。
2. 当前 `PDFDocument`。
3. 当前 document database id。
4. 阅读状态：当前页、缩放、display mode、scroll position。
5. Sidebar 状态：目录/缩略图 tab、是否展开。
6. Selection 状态：当前选区文本、选区 rects、选区所在页、浮卡位置。
7. Annotation 状态：当前文档已恢复的高亮和笔记。
8. Translation 状态：当前流式请求、历史译文、缓存命中状态、错误状态。
9. Search 状态：query、results、current result index。

它不应负责：

1. 自己解析 SSE。
2. 自己拼 SQL。
3. 直接处理 `scrollWheel(with:)`。
4. 直接创建 NSPanel。

事件入口：

1. App Shell 发来：打开文件、关闭窗口、toolbar 命令。
2. PDF Bridge 发来：页码变化、选区变化、缩放变化、annotation 点击。
3. Sidebar 发来：目录跳转、缩略图跳转。
4. Translation UI 发来：翻译、取消、保存译文、高亮并翻译。

输出：

1. 更新 SwiftUI 状态。
2. 调用 ReaderPDFView 执行跳转或显示 annotation。
3. 调用 Repository 保存阅读状态、高亮、译文。
4. 调用 TranslationService 发起或取消翻译。

### 3.3 PDF Bridge

PDF Bridge 由两部分组成：

```text
PDFKitRepresentable
ReaderPDFView: PDFView
```

`PDFKitRepresentable` 职责：

1. 在 SwiftUI 中创建并持有 `ReaderPDFView`。
2. 把 `PDFDocument`、display mode、scale intent 等状态传入 PDFView。
3. 暴露 PDFView 事件回调给 `DocumentSession`。
4. 避免 `updateNSView` 重复设置 document。

`ReaderPDFView` 职责：

1. 重写滚轮事件，实现 Command 加滚轮缩放。
2. 保持普通滚动、pinch、文本选择等 PDFKit 原生行为。
3. 监听或转发选区变化。
4. 做 page/view/window/screen 坐标转换。
5. 创建和移除运行时 `PDFAnnotation`。
6. 提供页面跳转、缩放、fit width、actual size 等命令入口。

PDF Bridge 对外事件：

```text
documentLoaded(pageCount)
pageChanged(pageIndex)
scaleChanged(scaleFactor)
selectionChanged(selectionSnapshot)
selectionCleared
annotationClicked(annotationId?)
openFailed(error)
```

`selectionSnapshot` 应包含：

1. 原始选区文本。
2. 清洗前 page index。
3. 多行 rects。
4. 用于浮卡定位的 screen rect。
5. 可选的 PDFSelection 引用，但不要把它持久化。

关键不变量：

1. PDFView 不放进 SwiftUI `ScrollView`。
2. 未按 Command 时滚轮必须交还给 PDFKit。
3. 高亮 rect 必须按行保存，避免双栏 PDF 被一个大矩形误伤。
4. 任何 PDFKit API 在实现前必须能对应到 Apple 文档或 references grep 结果。

### 3.4 Sidebar

Sidebar 第一版包含两个 tab：

1. 目录 Outline。
2. 缩略图 Thumbnails。

Outline 数据来源：

1. 优先使用 `PDFDocument.outlineRoot`。
2. 构建轻量树结构供 SwiftUI List/OutlineGroup 显示。
3. 点击节点跳转到 PDFDestination。

Thumbnail 数据来源：

1. 第一版可直接封装 `PDFThumbnailView`。
2. 不自研缩略图缓存，除非 PDFThumbnailView 性能不够。
3. 缩略图选择变化与当前页同步。

约束：

1. Sidebar 不直接访问数据库。
2. Sidebar 不持有 PDFDocument 生命周期。
3. 没有目录的 PDF 显示空状态，不尝试 AI 生成目录。

### 3.5 Toolbar 和 Commands

Toolbar 第一版控件：

1. Sidebar toggle。
2. 文件标题。
3. 当前页 / 总页数。
4. 上一页 / 下一页。
5. 缩放百分比。
6. 缩小 / 放大。
7. fit width。
8. actual size。
9. 单页连续 / 双页连续切换。
10. 搜索入口。
11. 翻译面板 toggle。

快捷键：

1. `Command-O` 打开 PDF。
2. `Command-F` 搜索。
3. `Command-+` 放大。
4. `Command--` 缩小。
5. `Command-0` actual size 或 fit width，review 时定。
6. `Command-[` / `Command-]` 返回和前进阅读位置，Phase 4 可增强。

设计约束：

1. Toolbar 不直接调用 PDFKit。
2. Toolbar 命令先进入 `DocumentSession`，再由 session 转发给 PDF Bridge。
3. 页码输入需要校验范围，非法输入不改变 PDFView 状态。

### 3.6 Search

Search 第一版目标是可用，不做复杂索引。

职责：

1. 接收 query。
2. 调用 PDFKit 文本搜索能力。
3. 展示结果数量和当前序号。
4. 支持 next/previous。
5. 跳转时让 PDFView 高亮当前搜索结果。

约束：

1. 不做全文索引数据库。
2. 不把 search results 持久化。
3. 大 PDF 搜索时需要异步或分批，避免卡主线程。

### 3.7 Annotation

Annotation 分为运行时显示和持久化两部分。

运行时显示：

1. 使用 PDFKit `PDFAnnotation` 添加到 `PDFPage`。
2. annotation 只用于当前 app 内展示。
3. 不写回 PDF 文件。

持久化：

1. SQLite 保存 annotation record。
2. 用 document id + page index + rects_json 恢复。
3. rects_json 存每行 rect。
4. selected_text 用于 hover/面板显示和翻译绑定。
5. note_content 可为空。

Annotation 生命周期：

```text
用户选中文本
  -> SelectionService 生成多行 rects
  -> 用户点击高亮
  -> AnnotationService 创建运行时 PDFAnnotation
  -> AnnotationRepository 保存
  -> DocumentSession 更新 annotation state

重新打开文档
  -> DocumentRepository 找到 document
  -> AnnotationRepository 读取记录
  -> AnnotationService 恢复 PDFAnnotation
```

删除高亮：

1. 用户点击高亮或在右侧面板选择删除。
2. 从 PDFPage 移除运行时 annotation。
3. 从 SQLite 删除或软删除记录。
4. 第一版优先硬删除，除非后续需要 undo。

约束：

1. 不实现 PDF 标准注释导出。
2. 不保存到 extended attributes。
3. 不使用 Skim 的注释存储方式。
4. annotation id 与 PDFAnnotation 的映射只在运行时存在。

### 3.8 Translation

Translation 模块由五部分组成：

```text
ConfigLoader
TextCleaner
PromptBuilder
DeepSeekClient
TranslationService
```

ConfigLoader：

1. 第一版按 `AGENTS.md`，从 `~/.config/myreader/config.json` 读取。
2. 不把 API Key 写入源码。
3. 不把 API Key 写入 SQLite。
4. 配置文件缺失时 UI 给出明确提示。
5. Keychain 作为后续增强，不进入第一版实现。

TextCleaner：

1. 合并英文连字符断行。
2. 删除 soft hyphen。
3. 英文换行转空格。
4. CJK 段内换行删除。
5. 保留公式、引用编号、英文缩写。

PromptBuilder：

1. 默认学术翻译 prompt。
2. 不做用户可编辑 prompt UI。
3. 输出要求稳定，避免 markdown fence 和无关解释。

DeepSeekClient：

1. 只负责 HTTP 请求和 SSE 解析。
2. 使用 OpenAI-compatible streaming endpoint。
3. 逐行解析 `data:`。
4. 处理 `[DONE]`。
5. 对非 SSE error JSON 做兜底解析。
6. 支持取消。

TranslationService：

1. 协调 config、clean、prompt、client、cache。
2. 翻译前先查缓存。
3. 缓存 key 包含 source text hash、target language、model。
4. 流式 token 推给 UI。
5. 完成后写 SQLite。
6. 请求失败时保留用户选区和重试入口。

翻译交互：

```text
选中文本
  -> 浮卡出现
  -> 用户点击翻译
  -> 先查 translations cache
  -> 命中：直接展示
  -> 未命中：DeepSeek SSE 流式输出
  -> 浮卡展示短结果
  -> Inspector 展示完整结果和历史
  -> 完成后写 cache
```

约束：

1. 不引入 OpenAI SDK。
2. 不引入 Provider 协议和 registry。
3. 不阻塞 PDFView 主线程。
4. 用户取消或切换选区时取消旧请求。
5. 日志不得输出 API Key。

### 3.9 Translation Panel 和 Inspector

浮卡：

1. 使用 `NSPanel + NSHostingController`。
2. 由选区 screen rect 定位。
3. 屏幕边缘做 clamp。
4. 默认只显示“翻译”“高亮”“复制”。
5. 翻译中显示简短流式内容。
6. 点击外部或选区清空时关闭。

右侧 Inspector：

1. 默认隐藏。
2. 翻译后自动展开。
3. 显示当前选区译文。
4. 显示历史翻译列表。
5. 每条记录显示页码、原文摘要、译文、复制、跳回原文、保存为笔记。
6. 后续可作为 FlowNote 联动入口。

约束：

1. 浮卡不承载长段落阅读。
2. 长结果以 Inspector 为主。
3. Inspector 不直接调用 DeepSeekClient。

## 4. 数据设计

### 4.1 数据位置

SQLite：

```text
~/Library/Application Support/PDFLite/reader.sqlite
```

DeepSeek 配置：

```text
~/.config/myreader/config.json
```

说明：

1. SQLite 路径使用产品名 `PDFLite`。
2. 配置路径当前按 `AGENTS.md` 保持 `myreader`，review 时建议决定是否统一改为 `~/.config/pdflite/config.json`。
3. API Key 不进入仓库，不进入 SQLite。

### 4.2 核心实体

Document：

1. id。
2. file_url。
3. file_hash。
4. title。
5. page_count。
6. last_opened_at。
7. last_page。
8. last_zoom。
9. last_scroll_y。
10. display_mode。
11. created_at / updated_at。

Annotation：

1. id。
2. document_id。
3. page_index。
4. annotation_type。
5. bounds_json。
6. color。
7. selected_text。
8. note_content。
9. created_at / updated_at。

Translation：

1. id。
2. document_id。
3. page_index。
4. text_hash。
5. source_text。
6. target_text。
7. provider。
8. model。
9. created_at。

ReadingHistory 可选：

第一版可先不单独建表，只在 Document 里记录最后位置。Phase 4 若做返回栈，再增加 navigation history。

### 4.3 数据一致性规则

1. `file_hash` 是文档身份的主判断。
2. 同一路径文件变化后，如果 hash 变化，应作为新文档处理或提示用户确认。
3. annotations 依赖 document id，删除 document 记录时级联删除。
4. translations 可以关联 document，也允许 document_id 为空以支持跨文档缓存；第一版建议都关联 document，降低复杂度。
5. `bounds_json` 的坐标系必须明确为 PDF page 坐标，不存 view/screen 坐标。
6. `text_hash` 使用清洗后的 source text + target language + model。
7. 数据库迁移必须版本化，不手写临时 SQL 覆盖旧库。

## 5. 关键数据流

### 5.1 打开 PDF

```text
用户 Command-O
  -> App Shell 打开文件选择器
  -> DocumentService 校验 URL 和文件类型
  -> 后台计算 file_hash
  -> PDFDocumentLoader 创建 PDFDocument
  -> DocumentRepository upsert document
  -> DocumentSession 初始化状态
  -> PDF Bridge 设置 document
  -> AnnotationRepository 读取高亮
  -> PDF Bridge 恢复 annotation
  -> 恢复 last page / zoom / display mode
```

错误处理：

1. 文件不存在：提示重新选择。
2. PDFDocument 创建失败：提示无法打开。
3. 加密 PDF：第一版提示不支持或依赖 PDFKit 原生密码流程。
4. 数据库失败：阅读仍可继续，但提示无法保存状态。

### 5.2 阅读状态保存

触发点：

1. 当前页变化。
2. 缩放变化。
3. display mode 变化。
4. 窗口关闭。
5. app 进入后台。

策略：

1. 页码和缩放变化做 debounce。
2. 窗口关闭时强制 flush。
3. 不在滚动每一帧写数据库。

### 5.3 选区到浮卡

```text
PDFViewSelectionChanged
  -> ReaderPDFView 捕获当前 selection
  -> SelectionService 生成 snapshot
  -> TextCleaner 做轻量预清洗
  -> DocumentSession 更新 selection state
  -> TranslationPanelController 定位 NSPanel
```

规则：

1. 选区为空时关闭浮卡。
2. 选区过短时只显示复制/高亮。
3. 选区跨页时第一版可以只支持首个 page，并提示用户缩小范围；后续再增强。
4. selection snapshot 不持久化，只有高亮/翻译时才落库。

### 5.4 选区到高亮

```text
用户点击高亮
  -> DocumentSession 读取 current selection snapshot
  -> AnnotationService 创建 PDFAnnotation
  -> PDF Bridge 添加 annotation
  -> AnnotationRepository 保存
  -> Inspector 或浮卡显示已保存
```

失败处理：

1. 没有 page 或 rects：按钮置灰。
2. SQLite 保存失败：撤回运行时 annotation 或标记未保存。
3. PDFKit 添加 annotation 失败：不写数据库。

### 5.5 选区到翻译

```text
用户点击翻译
  -> TranslationService 查 cache
  -> 命中：立即更新浮卡和 Inspector
  -> 未命中：创建 streaming request
  -> DeepSeekClient 返回 token stream
  -> UI 主线程追加 token
  -> 完成后保存 translations
```

取消策略：

1. 用户点击取消。
2. 用户关闭文档。
3. 用户选择新文本并开始新翻译。
4. 请求超时。

### 5.6 搜索跳转

```text
用户 Command-F 输入 query
  -> SearchService 调 PDFKit 搜索
  -> 结果列表写入 session state
  -> next/previous 跳转 PDFSelection
  -> PDFView 高亮当前搜索结果
```

第一版不把搜索结果写数据库。

## 6. 状态模型

窗口级状态建议分组：

```text
DocumentState
  fileURL
  documentID
  title
  pageCount
  loadState

ReaderState
  currentPage
  scaleFactor
  displayMode
  fitMode
  isSidebarVisible
  isInspectorVisible

SelectionState
  sourceText
  cleanedText
  pageIndex
  rects
  screenRect
  availableActions

AnnotationState
  annotationsByPage
  selectedAnnotationID

TranslationState
  currentRequest
  currentOutput
  history
  error
  isStreaming

SearchState
  query
  results
  currentIndex
  isSearching
```

设计原则：

1. 状态分组清晰，但不提前拆成复杂 store。
2. 第一版一个 `DocumentSession` 足够，不上 TCA。
3. 大对象如 `PDFDocument` 不进入可序列化状态。
4. UI 派生状态由 session 计算，不写入数据库。

## 7. 并发和性能

主线程：

1. 所有 AppKit/PDFKit UI 操作。
2. SwiftUI 状态更新。
3. NSPanel 显示和定位。

后台任务：

1. file hash 计算。
2. 数据库读写。
3. 搜索大文档时的分批处理。
4. 文本清洗。
5. DeepSeek 网络请求和 SSE 解析。

取消点：

1. 打开新文件时取消旧加载任务。
2. 新选区翻译开始时取消旧翻译任务。
3. 窗口关闭时取消该 session 所有后台任务。
4. 快速滚动时减少不必要的状态保存。

性能策略：

1. PDFKit 自己负责渲染，第一版不自研页面 bitmap cache。
2. 缩略图优先使用 PDFThumbnailView，不提前生成所有缩略图。
3. Outline 懒展开。
4. 阅读状态保存 debounce。
5. 选区变化 debounce 250ms。
6. 翻译流式输出节流刷新，避免每 token 都触发过重 UI diff。
7. 大 PDF 打开先显示第一页，目录/注释恢复可随后完成。

## 8. 错误处理和用户反馈

错误类型：

1. PDF 打开失败。
2. 文件移动或删除。
3. 数据库初始化失败。
4. 数据库写入失败。
5. 配置文件缺失或 API Key 缺失。
6. DeepSeek HTTP 错误。
7. SSE 解析错误。
8. 网络超时。
9. PDF 文本提取乱码。

反馈原则：

1. 阅读功能优先，不因为翻译或数据库失败阻断 PDF 打开。
2. 翻译错误显示在浮卡/Inspector 内，不弹系统模态框打断阅读。
3. 数据库失败需要明显提示，因为会影响阅读进度和高亮保存。
4. API Key 缺失时给出配置文件路径和最小配置格式。
5. 不在 UI 或日志显示 API Key。

## 9. 安全和隐私

第一版不做沙盒，但仍遵守基本安全边界：

1. API Key 不写源码。
2. API Key 不写 SQLite。
3. API Key 不进入日志。
4. 只把用户主动选择的文本发给 DeepSeek。
5. 第一版不自动上传全文。
6. 翻译缓存只保存在本机 SQLite。
7. 配置文件建议 `chmod 600`。

后续如果开源或分发，需要新增：

1. Keychain。
2. App Sandbox。
3. Hardened Runtime。
4. 公证。
5. 隐私说明。
6. 第三方 license notice。

## 10. Phase 交付设计

### Phase 1：阅读闭环

范围：

1. 项目骨架。
2. 打开 PDF。
3. PDFView 显示。
4. 单页连续和双页连续。
5. Command 加滚轮缩放。
6. 页码显示和跳转。
7. Outline。
8. Thumbnail。
9. Search。
10. 最近打开文件。

允许参考：

1. PageFlow。
2. Apple PDFKit 文档。

默认不主动参考 Skim。

验收标准：

1. 能打开至少 3 个不同论文 PDF。
2. 滚动、缩放、页码跳转不卡 UI。
3. 单双页切换后页码状态正确。
4. `Command-F` 能搜索并跳转。
5. 关闭重开后能恢复最近打开记录。
6. 代码里没有 sandbox、SwiftData、CoreData、Provider 抽象。

### Phase 2：注释和阅读状态

范围：

1. 选区监听。
2. selection rects 计算。
3. 高亮创建。
4. SQLite schema 和 GRDB repositories。
5. 重新打开恢复高亮。
6. 阅读位置恢复。
7. 删除高亮。

允许参考：

1. PageFlow。
2. Apple PDFKit 文档。
3. Skim。
4. PDFAnnotationEditor。

验收标准：

1. 单行、多行选区高亮位置正确。
2. 双栏 PDF 不用一个大矩形跨栏高亮。
3. 关闭重开后高亮恢复。
4. 删除高亮后数据库和页面一致。
5. 阅读页码、缩放、display mode 能恢复。
6. 不写回 PDF 原文件。

### Phase 3：划词翻译

范围：

1. ConfigLoader。
2. TextCleaner。
3. PromptBuilder。
4. DeepSeekClient SSE。
5. TranslationService。
6. NSPanel 浮卡。
7. 右侧 Translation Inspector。
8. Translation cache。
9. 高亮和译文绑定。

允许参考：

1. macai。
2. Easydict 概念参考。
3. zotero-pdf-translate 概念参考。
4. Apple 文档。

验收标准：

1. 无 API Key 时提示明确。
2. 有 API Key 时能流式翻译选中文本。
3. 取消、新选区、关闭窗口都能停止旧请求。
4. 相同文本二次翻译命中缓存。
5. 浮卡定位不跑出屏幕。
6. Inspector 历史可跳回原文。
7. 不引入 OpenAI SDK、Alamofire、多 Provider 抽象。

### Phase 4：论文增强

范围：

1. Smart Jump v0。
2. Reference preview。
3. Figure/Table 跳转。
4. 全文问答。
5. FlowNote 联动。

允许参考：

1. Sioyek 概念参考。
2. SimplePDF 概念参考。
3. 前面所有项目。

验收标准：

1. 常见 `[12]` 引用能识别并预览 References 条目。
2. Figure/Table 能通过全文搜索定位候选页。
3. 支持返回阅读位置。
4. FlowNote 联动不影响核心阅读流程。

## 11. 测试策略

单元测试：

1. TextCleaner。
2. PromptBuilder。
3. SSEParser。
4. ConfigLoader。
5. Repository CRUD。
6. text_hash 和 file_hash。

集成测试：

1. 打开 PDF 后写入 document record。
2. 创建高亮后恢复。
3. 翻译缓存命中。
4. 配置缺失时错误路径。

手工测试 PDF 集：

1. arXiv 双栏论文。
2. 单栏长 PDF。
3. 带目录 PDF。
4. 无目录 PDF。
5. 含公式和引用编号 PDF。
6. 大文件 PDF。
7. 扫描版 PDF，确认第一版给出合理提示而不是假装可翻译。

性能观察：

1. 打开耗时。
2. 滚动是否掉帧。
3. 缩放时 UI 是否阻塞。
4. 大 PDF 内存占用。
5. 快速选择和取消翻译是否泄漏任务。

## 12. AI Coding 执行纪律

后续每个功能实现前必须：

1. 确认当前 Phase。
2. 在 `references/` 中 grep 对应实现。
3. 给出参考文件和方法。
4. 涉及 PDFKit 时给出 Apple 文档 URL。
5. 确认没有引入 `AGENTS.md` 禁止项。

Phase 1 默认只看 PageFlow 和 Apple 文档。Skim 只能在 PageFlow 和 Apple 文档无法覆盖 PDFKit 行为时，经用户允许后 grep。

写代码前必须回答：

1. 这个功能最接近 `references/` 里哪个项目的哪个模块？
2. 用 `find` 或 `grep` 在 `references/` 里找到的具体文件是什么？
3. 如果涉及 PDFKit，对应的 Apple 官方文档 URL 是什么？
4. 当前 Phase 是否允许参考这个项目？
5. 该实现是否会引入本文禁止的依赖、架构或功能？

写完代码后必须自检：

1. 参考了 `references/` 里哪个项目、哪个文件、哪个方法？
2. 这段 PDFKit API 在 Apple 官方文档里的对应类是什么？给出 URL。
3. 这段代码有没有引入本文禁止的依赖、架构或功能？

如果 grep 没找到对应 API，Apple 官方文档也没有该 API，不允许猜 Swift 方法名。

## 13. 参考项目地图

`references/` 是只读参考项目目录，不参与应用 target 编译。

当前固定参考项目：

1. `references/PageFlow`
   - 语言：Swift + SwiftUI + PDFKit。
   - 许可证：Apache 2.0。
   - 用途：SwiftUI + PDFKit 主骨架、多窗口、工具栏、搜索、单双页、注释结构。
   - Phase 1 主参考。

2. `references/skim`
   - 语言：Objective-C + AppKit + PDFKit。
   - 许可证：BSD-style。
   - 用途：PDFKit 深水区行为，包括 `PDFView` 子类、selection、annotation、outline、thumbnail、窗口协调。
   - 规则：只按需 grep，不通读整个项目，不把 Obj-C 直接翻成伪 Swift。

3. `references/PDFAnnotationEditor`
   - 语言：Swift。
   - 许可证：MIT。
   - 用途：PDFAnnotation 创建、编辑、hit testing。
   - Phase 2 注释参考。

4. `references/macai`
   - 语言：Swift + SwiftUI。
   - 许可证：Apache 2.0。
   - 用途：URLSession SSE 流式调用、错误处理、流式 UI 更新。
   - 规则：只参考网络流式部分，不引入 Provider 抽象、CoreData、iCloud Sync。

Apple 官方文档是 PDFKit API 校验最终源：

1. PDFKit: https://developer.apple.com/documentation/pdfkit
2. PDFView: https://developer.apple.com/documentation/pdfkit/pdfview
3. PDFDocument: https://developer.apple.com/documentation/pdfkit/pdfdocument
4. PDFSelection: https://developer.apple.com/documentation/pdfkit/pdfselection
5. PDFAnnotation: https://developer.apple.com/documentation/pdfkit/pdfannotation
6. NSViewRepresentable: https://developer.apple.com/documentation/swiftui/nsviewrepresentable

可选 UX 参考项目不要默认拉入 submodule。需要 Phase 3 或 Phase 4 时再临时 clone 到 `references_optional/`：

1. Easydict：划词浮卡 UX，只看概念。
2. zotero-pdf-translate：学术翻译 prompt 和 UX，只看概念。
3. SimplePDF：PDF + LLM 最小闭环、页码引用思路，只看概念。
4. Sioyek：Smart Jump、reference preview、figure/table 跳转，只看产品行为和 README。

## 14. 常用 grep 命令

Phase 1：SwiftUI 包 PDFView 主骨架。

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

Phase 2：PDFKit 文本选择和坐标转换。

```bash
grep -rn "PDFViewSelectionChanged" references/skim
grep -rn "selectionsByLine" references/skim
grep -rn "selectionForRange" references/skim
grep -rn "convertPoint:fromPage:" references/skim
grep -rn "boundsForPage:" references/skim

find references/skim -name "SKPDFView.m"
find references/skim -name "SKMainWindowController.m"
```

Phase 2：高亮、下划线、笔记。

```bash
grep -rn "PDFAnnotation(bounds:" references/PDFAnnotationEditor
grep -rn "addAnnotation" references/PDFAnnotationEditor
grep -rn "highlight" references/PDFAnnotationEditor

grep -rn "annotationAdded" references/skim
grep -rn "annotationRemoved" references/skim
```

Phase 3：DeepSeek SSE 流式调用。

```bash
grep -rn "URLSession.shared.bytes" references/macai
grep -rn "AsyncThrowingStream" references/macai
grep -rn "data:" references/macai

find references/macai -iname "*ChatGPT*"
find references/macai -iname "*APIHandler*"
find references/macai -iname "*MessageParser*"
```

Objective-C 到 Swift 对照：

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

## 15. 常见跑偏模式

| 跑偏症状 | 纠正方式 |
|---|---|
| 出现 `UIView` / `UIViewRepresentable` / `UIColor` | macOS only，改用 NSView / NSViewRepresentable / NSColor |
| 调用 `pdfView.startSelection()` 等不存在方法 | 先 grep references，再查 Apple 文档 |
| 出现 `@Model` / `ModelContext` / `NSManagedObject` | 删除，改用 GRDB |
| 出现 `startAccessingSecurityScopedResource` | 项目不开沙盒，删除 bookmark 代码 |
| Obj-C 方法翻译错 | 看本文 Objective-C 到 Swift 对照表 |
| Package.swift 加了非白名单依赖 | 删除，或先询问用户 |
| 出现 Provider 协议、多实现、Provider registry | 第一版只用 `DeepSeekClient` |
| 开始做论文库、标签、DOI、引用图谱 | 第一版只做阅读器和划词翻译 |

## 16. 待 Review 决策点

1. 配置路径是否从 `~/.config/myreader/config.json` 统一改成 `~/.config/pdflite/config.json`。
2. API Key 第一版是否继续用本地 config 文件，还是提前改成 Keychain。
3. 产品显示名用 `PDFLite`、`pdflite` 还是其他名称。
4. SQLite 路径是否使用 `~/Library/Application Support/PDFLite/reader.sqlite`。
5. `Command-0` 是 actual size 还是 fit width。
6. 第一版是否需要支持多窗口，还是先单窗口。
7. Phase 1 是否把 search 放进第一周，还是先延后到 Phase 1.5。
8. 选区跨页时第一版是禁止、只取第一页，还是完整支持。
9. 翻译 prompt 默认输出“只给译文”还是“译文 + 最多 3 条术语解释”。
10. 是否需要单独创建 `docs/PROMPTS.md` 固化翻译 prompt。
