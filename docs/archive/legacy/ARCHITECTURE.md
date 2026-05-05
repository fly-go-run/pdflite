# ARCHITECTURE.md

本文件记录技术决策。AI Coding 不应该反复挑战这些决策，除非用户明确要求重构。

## 1. 总体目标

构建一个 macOS 原生学术论文 PDF 阅读器。

核心需求：

1. 打开和阅读本地 PDF，滚动流畅，占用低。
2. 支持单页连续和双页连续显示。
3. 支持按住 Command 加鼠标滚轮缩放。
4. 支持目录、缩略图、搜索、页码跳转。
5. 支持文本选择、高亮、阅读位置恢复。
6. 支持划词翻译，DeepSeek 流式输出。
7. 支持右侧翻译面板和本地翻译缓存。

第一版是论文阅读器，不扩展成文献管理器。

## 2. 整体架构

```text
SwiftUI 应用外壳
  WindowGroup
  NavigationSplitView
  Toolbar
  Inspector
  Settings
        │
        │ NSViewRepresentable
        ▼
AppKit ReaderPDFView: PDFView
  自定义 scrollWheel，实现 Command 加滚轮缩放
  监听 PDFViewSelectionChanged
  处理坐标转换和浮卡定位
  绘制和恢复 PDFAnnotation
        │
        ▼
PDFKit
  PDFDocument
  PDFPage
  PDFSelection
  PDFAnnotation
  PDFOutline
  PDFThumbnailView
```

旁置数据流：

```text
GRDB + SQLite sidecar
        │
        ▼
DocumentViewModel (@Observable)
        │
        ▼
ReaderPDFView / SwiftUI UI
```

翻译数据流：

```text
ReaderPDFView 选中文本
        │
        ▼
TextCleaner
        │
        ▼
PromptBuilder
        │
        ▼
DeepSeekClient (URLSession.bytes + AsyncThrowingStream)
        │
        ▼
TranslationPanel (NSPanel + SwiftUI)
        │
        ▼
SQLite translations cache
```

## 3. 技术选型决策

### 3.1 SwiftUI 主壳 + AppKit PDFView 子类

采用 SwiftUI 管理窗口、侧栏、工具栏、设置页和 Inspector。

采用 AppKit `PDFView` 子类承接核心阅读区，因为 SwiftUI 无法精细处理 PDFView 的滚轮事件、修饰键、选区坐标、annotation hit testing、浮窗定位。

结论：SwiftUI 负责应用结构和普通 UI，AppKit 负责 PDF 阅读核心交互。

### 3.2 PDFKit 作为第一版唯一渲染引擎

PDFKit 是 macOS 原生框架，与 Preview 和 Safari 的 PDF 体验更接近。

第一版不使用 PDFium、MuPDF、PDF.js、Poppler。

原因：

1. PDFKit 集成成本最低。
2. PDFKit 已覆盖显示、文本选择、目录、缩略图、搜索、注释。
3. PDFium 和 MuPDF 需要额外 C/C++ 封装和坐标系统维护。
4. PDF.js 会回到 Web 渲染路线，与你当前对 Chrome 卡顿的痛点不匹配。

后续只有在 PDFKit 遇到不可接受的兼容性问题时，才评估备用渲染引擎。

### 3.3 GRDB + SQLite sidecar

使用 GRDB 直接管理 SQLite。

不使用 SwiftData 和 CoreData。

原因：

1. 注释、翻译、阅读位置都是简单关系型数据。
2. SQL schema 明确，便于 AI 遵守。
3. 迁移可控。
4. 不引入 CoreData 和 SwiftData 的状态管理复杂度。

### 3.4 `@Observable` + 简单 MVVM

每个文档窗口一个 `DocumentViewModel`。

不用 TCA。

原因：

1. 单人项目不需要大型状态管理框架。
2. `@Observable`、`@Bindable` 已能覆盖窗口状态、阅读状态、翻译状态。
3. TCA 会增加学习成本和样板代码。

### 3.5 不开启 App Sandbox

当前阶段按自用项目实现，不为 Mac App Store 上架做工程。

不开沙盒后，文件访问直接使用普通 URL path。

禁止出现：

1. `startAccessingSecurityScopedResource`
2. `bookmarkData(options: .withSecurityScope)`
3. security-scoped bookmark 持久化

后续如果上架，再单独增加沙盒和文件权限处理。

### 3.6 API Key 配置

第一版不实现 Keychain。

默认从以下文件读取：

```text
~/.config/myreader/config.json
```

该文件必须加入 gitignore，建议权限：

```bash
chmod 600 ~/.config/myreader/config.json
```

示例配置：

```json
{
  "deepseek": {
    "baseURL": "https://api.deepseek.com",
    "model": "deepseek-v4-flash",
    "apiKey": "YOUR_API_KEY"
  },
  "translation": {
    "targetLanguage": "zh-CN",
    "stream": true,
    "timeoutSeconds": 60
  }
}
```

不要把 API Key 写入 Swift 源码。

### 3.7 NSPanel 做划词翻译浮卡

划词翻译浮卡用独立 NSPanel。

不用 NSPopover。

原因：

1. NSPanel 对全屏、焦点、层级、关闭行为更可控。
2. 可以使用 `.borderless` 和 `.nonactivatingPanel`，避免抢走 PDFView 焦点。
3. 可以手动做屏幕边界 clamp。

推荐配置：

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

### 3.8 注释存 SQLite，不写回 PDF

第一版高亮、笔记、翻译绑定都存 SQLite sidecar。

不自动修改原 PDF 文件。

原因：

1. 自用场景不需要跨阅读器共享注释。
2. 写回 PDF 会引入保存、加密 PDF、权限、兼容性风险。
3. SQLite 恢复速度快，撤销和删除更容易。
4. 后续可以单独做“导出为 PDF 标准注释”。

## 4. 项目目录结构

```text
my-pdf-reader/
├── AGENTS.md
├── docs/
│   ├── ARCHITECTURE.md
│   ├── AI_REFERENCES.md
│   └── PROMPTS.md
├── references/
│   ├── PageFlow/
│   ├── skim/
│   ├── macai/
│   ├── PDFAnnotationEditor/
│   └── REFERENCE_LOCK.txt
├── App/
│   ├── MyPDFReaderApp.swift
│   └── AppDelegate.swift
├── Features/
│   ├── Reader/
│   │   ├── PDFKitView.swift
│   │   ├── ReaderPDFView.swift
│   │   └── ReaderViewModel.swift
│   ├── Outline/
│   │   └── OutlineSidebar.swift
│   ├── Thumbnails/
│   │   └── ThumbnailSidebar.swift
│   ├── Toolbar/
│   │   └── ReaderToolbar.swift
│   ├── Translation/
│   │   ├── DeepSeekClient.swift
│   │   ├── TranslationPanel.swift
│   │   ├── PromptBuilder.swift
│   │   └── TextCleaner.swift
│   └── Annotation/
│       ├── HighlightManager.swift
│       └── AnnotationStore.swift
├── Core/
│   ├── Document/
│   │   └── PDFDocumentLoader.swift
│   ├── Storage/
│   │   ├── Database.swift
│   │   └── Models/
│   │       ├── DocumentRecord.swift
│   │       ├── AnnotationRecord.swift
│   │       └── TranslationRecord.swift
│   └── Config/
│       └── ConfigLoader.swift
├── UI/
│   └── Common/
└── Tests/
```

说明：

1. `references/` 是 git submodules，只给 AI 读，不参与应用编译。
2. `docs/AI_REFERENCES.md` 记录每个功能要参考哪个项目。
3. `docs/ARCHITECTURE.md` 固化技术决策。
4. `AGENTS.md` 是 AI Coding 硬规则。
5. `ConfigLoader.swift` 只负责读取本地配置，不包含 API Key 字面量。

## 5. SQLite Schema

```sql
CREATE TABLE documents (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    file_url TEXT NOT NULL,
    file_hash TEXT NOT NULL,
    title TEXT,
    page_count INTEGER DEFAULT 0,
    last_opened_at INTEGER NOT NULL,
    last_page INTEGER DEFAULT 0,
    last_zoom REAL DEFAULT 1.0,
    last_scroll_y REAL DEFAULT 0,
    display_mode TEXT DEFAULT 'singlePageContinuous',
    full_text TEXT,
    created_at INTEGER NOT NULL,
    updated_at INTEGER NOT NULL
);

CREATE UNIQUE INDEX idx_documents_hash ON documents(file_hash);
CREATE INDEX idx_documents_recent ON documents(last_opened_at DESC);

CREATE TABLE annotations (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    document_id INTEGER NOT NULL,
    page_index INTEGER NOT NULL,
    annotation_type TEXT NOT NULL,
    bounds_json TEXT NOT NULL,
    color TEXT NOT NULL,
    selected_text TEXT,
    note_content TEXT,
    created_at INTEGER NOT NULL,
    updated_at INTEGER NOT NULL,
    FOREIGN KEY (document_id) REFERENCES documents(id) ON DELETE CASCADE
);

CREATE INDEX idx_annotations_doc_page ON annotations(document_id, page_index);

CREATE TABLE translations (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    document_id INTEGER,
    page_index INTEGER,
    text_hash TEXT NOT NULL,
    source_text TEXT NOT NULL,
    target_text TEXT NOT NULL,
    provider TEXT NOT NULL DEFAULT 'deepseek',
    model TEXT NOT NULL,
    created_at INTEGER NOT NULL,
    FOREIGN KEY (document_id) REFERENCES documents(id) ON DELETE CASCADE
);

CREATE UNIQUE INDEX idx_translations_hash ON translations(text_hash);
```

约束：

1. `bounds_json` 存多行 rect，格式为 `[{"x":0,"y":0,"w":0,"h":0}]`。
2. 高亮不要只存一个大矩形，双栏论文会误伤。
3. `text_hash` 计算范围为 source text + target language + model。
4. `file_hash` 使用 SHA-256。

## 6. 第一版 UI 布局

```text
┌──────────────────────────────────────────────────────────────┐
│ Toolbar: sidebar | title | page | zoom | single/two | search │
├──────────────┬───────────────────────────────┬───────────────┤
│ Outline /    │                               │ Translation   │
│ Thumbnails   │            PDFView            │ Inspector     │
│              │                               │               │
└──────────────┴───────────────────────────────┴───────────────┘
```

左侧栏：目录和缩略图。

中间：PDFView，灰色背景，白色页面，支持单页连续和双页连续。

右侧：翻译 Inspector，默认隐藏，划词翻译后展开。

选区浮卡：只放“翻译”“高亮”“复制”。

## 7. 关键不变量

AI 写代码时必须遵守。

1. `PDFKitView.updateNSView` 必须守卫 `if pdfView.document !== newDocument` 或等价逻辑，避免重复设置 document。
2. 不在 SwiftUI `ScrollView` 内嵌 `PDFView`，PDFView 自己当滚动容器。
3. Command 加滚轮缩放在 `ReaderPDFView.scrollWheel(with:)` 中处理。
4. 未按 Command 时必须调用 `super.scrollWheel(with:)`。
5. 选区高亮必须按 `selectionsByLine()` 拆分多行 rect。
6. 注释第一版只存 SQLite，不写回 PDF。
7. `PDFDocument(url:)` 失败要能优雅报错。
8. 不写 `creationDateAttribute`。
9. SSE 错误响应可能不是 `data:` 前缀，先尝试 JSON 解析。
10. CJK 文本段内换行直接删除，英文换行转空格。
11. 英文连字符断行要清洗，例如 `transfor-\nmer` 转成 `transformer`。
12. 学术 PDF 公式复制乱码时，提示用户改用截图翻译或手动选择更小范围。
13. 所有 UI 更新回主线程。
14. 快速滚动、缩放、切换页时不要阻塞主线程调用 LLM。
15. `references/` 下代码只读，不参与编译。

## 8. Phase 计划

### Phase 1

交付：

1. 打开 PDF。
2. 显示 PDF。
3. 单页连续和双页连续。
4. Command 加滚轮缩放。
5. 页码显示和跳转。
6. 目录。
7. 缩略图。
8. 搜索。
9. 最近打开文件。

### Phase 2

交付：

1. 文本选择监听。
2. 高亮。
3. SQLite 保存高亮。
4. 重新打开恢复高亮。
5. 阅读位置恢复。
6. 删除高亮。

### Phase 3

交付：

1. 读取 DeepSeek 配置。
2. URLSession 流式翻译。
3. NSPanel 划词浮卡。
4. 右侧翻译面板。
5. 翻译缓存。
6. 高亮和译文绑定。

### Phase 4

交付：

1. Smart Jump。
2. Reference preview。
3. Figure/Table 跳转。
4. 全文问答。
5. FlowNote 联动。
