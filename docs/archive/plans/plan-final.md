# macOS 自用学术 PDF 阅读器：最终定案

更新时间：2026-05-05

## 一句话结论

做一个 **macOS 自用学术 PDF 阅读器**：

**SwiftUI 壳 + AppKit `PDFView` 子类 + PDFKit 渲染 + GRDB sidecar + Keychain API Key + URLSession DeepSeek 流式翻译 + NSPanel 浮卡 + 右侧双语 Inspector。**

第一版目标：4 周可用，6 周稳定，8 周加入 Smart Jump 和论文级体验。

---

## 核心判断

### 1. SwiftUI 主壳，PDFView 下沉 AppKit

最终采用：

- SwiftUI 负责窗口、三栏布局、工具栏、设置页、右侧翻译面板。
- `ReaderPDFView: PDFView` 负责核心阅读交互。
- `PDFKitRepresentable: NSViewRepresentable` 把 PDFView 嵌进 SwiftUI。

原因：

- macOS 14+ 的 `NavigationSplitView`、`.toolbar`、`.inspector` 足够支撑主壳。
- 真正需要细控的是 PDF 阅读区：滚轮、缩放、选区、右键菜单、坐标转换、浮窗定位。
- 纯 AppKit 会增加代码量，不适合 4-6 周自用项目节奏。

### 2. 第一版只做 macOS 原生

第一版不走 Qt、PDFium、PDF.js、Electron、Tauri。

原因：

- 目标只在 macOS 自用。
- PDFKit 走 Apple 原生 PDF/Quartz 路径，手势、字体、渲染和系统体验都更自然。
- 跨平台路线会把文本选择、高亮、坐标映射、触控板手势都变成额外工程量。

### 3. DeepSeek 保留轻量配置，不做完整 Provider 系统

最终采用：

```json
{
  "provider": "deepseek",
  "baseURL": "https://api.deepseek.com",
  "model": "deepseek-v4-flash",
  "targetLanguage": "zh-CN",
  "stream": true
}
```

保留 `baseURL + model + targetLanguage`，但不做完整多 Provider 设置系统。

截至 2026-05-05，DeepSeek 官方文档列出的 OpenAI 兼容模型包括：

- `deepseek-v4-flash`
- `deepseek-v4-pro`
- `deepseek-chat`，标注将在 2026-07-24 废弃
- `deepseek-reasoner`，标注将在 2026-07-24 废弃

实现前仍应重新看官方文档，因为模型名和价格属于高频变化信息。

### 4. API Key 用 Keychain

自用也不把 key 写进 `Secrets.swift`、配置文件或 git 历史。

最终做法：

- 设置页输入 DeepSeek API Key。
- Keychain 保存 API Key。
- SQLite 只保存 provider、baseURL、model、targetLanguage。

### 5. 高亮只走 sidecar

第一版不写回 PDF 原文件，不做导出为标准 PDF 注释。

原因：

- 自用不需要给别人传带注释的 PDF。
- PDFKit 写回 annotation 历史坑多。
- SQLite sidecar 更适合高亮、译文、笔记、阅读进度、跳转关系。

---

## 产品边界

第一版只围绕五件事：

1. 读论文足够流畅：打开快、滚动顺、缩放顺、内存低。
2. 划词翻译顺手：选中英文后浮卡翻译，右侧面板展示完整流式结果。
3. 高亮和阅读痕迹可靠：高亮、译文、笔记、页码、缩放、单双页模式自动恢复。
4. 界面接近 Chrome/Edge：顶部工具栏、左侧目录/缩略图、中间 PDF、右侧翻译面板。
5. 论文场景加分后置：Smart Jump、全文问答、FlowNote 联动在基础体验稳定后做。

不做清单：

- 全文翻译
- OCR
- 手写批注
- PDF 编辑
- 云同步
- 文献管理
- 多人协作
- 复杂插件系统
- App Store 沙盒、公证、自动更新
- 完整多 Provider 设置 UI
- 第一版 PDF 注释导出

---

## 推荐架构

### App 层

```text
PaperReaderApp
ReaderWindow
ReaderView
ToolbarView
SidebarView
TranslationInspector
SettingsView
```

职责：

- 管理窗口和打开文件。
- 组织左中右三栏。
- 处理菜单、快捷键、最近文件。
- 管理设置入口和右侧 Inspector。

### PDF 阅读层

```text
ReaderPDFView: PDFView
PDFKitRepresentable: NSViewRepresentable
PDFViewCoordinator
PDFSelectionController
PDFNavigationController
```

职责：

- 打开和切换文档。
- 单页连续、双页连续。
- Command 加滚轮缩放。
- 监听文本选区。
- 计算选区屏幕坐标。
- 创建运行时高亮 annotation。
- 页面跳转、目录跳转、搜索跳转。

关键实现：

- `ReaderPDFView.scrollWheel(with:)` 处理 Command 加滚轮缩放。
- `PDFViewSelectionChanged` + 250ms 防抖监听选区。
- `PDFSelection.bounds(for:)` 获取页内选区坐标。
- `PDFOutline` 构建左侧目录树。

### 数据层

```text
DatabaseManager
DocumentRepository
AnnotationRepository
TranslationRepository
SettingsRepository
```

建议 schema：

```sql
documents(
  id,
  file_url,
  file_hash,
  title,
  page_count,
  last_page_index,
  last_scale_factor,
  display_mode,
  last_opened_at,
  created_at
);

annotations(
  id,
  document_id,
  page_index,
  type,
  rects_json,
  color,
  source_text,
  note,
  created_at,
  updated_at
);

translations(
  id,
  document_id,
  page_index,
  source_text_hash,
  source_text,
  translated_markdown,
  provider,
  model,
  created_at
);
```

`rects_json` 存每一行 rect，不只存一个大矩形。论文双栏排版里，单个大矩形容易跨栏误伤正文。

### 翻译层

```text
TranslationService
DeepSeekClient
SSEParser
PromptBuilder
TextCleaner
TranslationCache
```

职责：

- 清洗 PDF 复制文本。
- 构造学术翻译 prompt。
- 用 `URLSession` 调 DeepSeek stream API。
- 解析 SSE。
- 流式更新浮卡和右侧面板。
- 缓存相同文本的翻译结果。

Prompt 模板：

```text
你是学术论文阅读助手。请将下面的英文论文片段翻译成中文。

要求：
1. 保留公式、变量名、引用编号和英文缩写。
2. 专业术语首次出现时给出括号解释。
3. 不要扩写原文没有的信息。
4. 先给译文，再给最多 3 条术语解释。

原文：
{{selected_text}}
```

---

## 功能设计

### Command 加鼠标缩放

逻辑：

1. 检测 `event.modifierFlags.contains(.command)`。
2. 按住 Command 时拦截滚轮。
3. 根据 `event.scrollingDeltaY` 调整 `scaleFactor`。
4. 缩放按 5% 或 10% 步进。
5. 没按 Command 时调用 `super.scrollWheel(with: event)`。

建议范围：

```text
minScaleFactor: 0.25
maxScaleFactor: 5.0
step: 0.05 或 0.1
```

触控板 pinch 交给 PDFKit，避免双重缩放。

### 单双页显示

工具栏提供：

- 单页连续：`.singlePageContinuous`
- 双页连续：`.twoUpContinuous`
- 适合宽度
- 实际大小
- 缩放百分比

### 划词翻译

交互：

1. 用户选中文本。
2. 250ms 防抖。
3. 太短只显示“复制”和“高亮”，超过 5 个英文单词显示“翻译”。
4. 选区附近弹 `NSPanel` 浮卡。
5. 点击翻译后，浮卡显示简短译文，右侧 Inspector 显示完整流式结果。
6. 翻译结果自动缓存。
7. 支持“保存为高亮笔记”。

浮卡用 `NSPanel`，不用 `NSPopover`。PDF 阅读器常见全屏、跨 Space、滚动缩放，`NSPopover` 容易有定位和焦点问题。

### 高亮

第一版：

1. 选中文本后点击高亮。
2. 在当前 `PDFPage` 上创建 `PDFAnnotation`，只做运行时显示。
3. 同时把 page index、rects、颜色、原文、译文写 SQLite。
4. 下次打开 PDF 时，从 SQLite 恢复 annotation。
5. 不自动写回 PDF 原文件。

### 右侧双语面板

右侧面板从第一版后半段开始做，因为它能显著超过 Preview/Chrome 的论文阅读体验。

结构：

- 当前选区译文
- 历史翻译列表
- 每条翻译对应页码
- 跳回原文按钮
- 保存到笔记按钮
- 复制译文按钮

浮窗适合短句，右侧面板适合段落和公式解释。

---

## 开发路线

### 第 1 周：可打开、可阅读、可缩放

- 新建 macOS app。
- SwiftUI 三栏布局。
- `PDFKitRepresentable` 嵌入 `ReaderPDFView`。
- 打开本地 PDF。
- 单页连续显示。
- 页码显示。
- Command 加滚轮缩放。
- 记录最近打开文件。

### 第 2 周：工具栏、目录、单双页、搜索

- 顶部工具栏仿 Chrome/Edge。
- 左侧目录。
- 左侧缩略图。
- 单页和双页连续切换。
- 适合宽度、实际大小、缩放百分比。
- `Command-F` 搜索。
- 记住上次页码、缩放、单双页模式。

### 第 3 周：划词翻译

- 监听 PDF 选区变化。
- 选区文本清洗。
- NSPanel 浮卡。
- DeepSeek 设置页。
- Keychain 保存 API Key。
- URLSession 流式调用。
- SSE 解析。
- 翻译结果展示和缓存。

### 第 4 周：高亮和旁置笔记

- 选区高亮。
- SQLite 保存 annotation。
- 重新打开 PDF 自动恢复高亮。
- 翻译结果绑定高亮。
- 右侧翻译历史。
- 删除高亮。
- 跳回原文位置。

### 第 5 周：稳定性和论文体验

- 大 PDF 打开性能优化。
- 快速滚动时减少 UI 更新。
- 多栏 PDF 选区修正。
- 数学公式复制异常提示。
- DeepSeek 失败、超时、非 SSE 错误 JSON 处理。
- 暗色背景和页面阴影。
- 全屏体验。

### 第 6 周：Smart Jump v0

- 检测 `[12]`、`[3, 5]`、`Figure 2`、`Table 1`。
- 解析 References 段。
- 鼠标悬停或点击弹引用预览。
- 点击跳转到引用页。
- 支持返回阅读位置。

---

## 优先级

第一优先级：

- 流畅阅读
- 单双页
- Command 加滚轮缩放
- 目录
- 搜索
- 阅读进度

第二优先级：

- 划词翻译
- DeepSeek 流式输出
- 右侧双语面板
- 翻译缓存

第三优先级：

- 高亮
- 笔记
- 译文绑定原文
- 跳回原文

第四优先级：

- Smart Jump
- 引用预览
- Figure/Table 跳转

第五优先级：

- 全文问答
- FlowNote 联动
- 论文库
- 元数据
- DOI

---

## 性能 checklist

1. 只渲染可视区域附近页面。
2. 缩放时先缩放已有 bitmap，用户停下后再重渲染清晰版本。
3. 页面缓存按 page、scale、display mode、screen scale 建 key。
4. 设置内存上限，超过后 LRU 淘汰。
5. 目录、文本层、缩略图懒加载。
6. 快速滚动时取消旧渲染任务。
7. Command 加滚轮缩放节流，缩放百分比按 5% 或 10% 步进。
8. 高亮时只更新对应页 overlay，避免整页重绘。
9. 翻译请求异步流式返回，不能阻塞 PDFView 主线程。
10. 打开大 PDF 时先显示第一页，目录和缩略图后台生成。

---

## 开源项目参考顺序

1. [PageFlow](https://github.com/pinchen147/PageFlow)：优先看 SwiftUI + PDFKit 桥接、多窗口、toolbar、annotations、recent files。
2. [Skim](https://skim-app.sourceforge.io/)：学习论文阅读、高亮、目录、notes、snapshots、visual history。
3. [Sioyek](https://sioyek.info/)：学习 Smart Jump、references、figures、equations 预览和跳转。
4. [SimplePDF](https://github.com/Yiiipu/SimplePDF)：学习 PDFKit + LLM 最小形态和页码引用。
5. [GRDB.swift](https://github.com/groue/GRDB.swift)：SQLite 持久化。

许可证注意：

- PageFlow 是 Apache 2.0，复用空间较大。
- Sioyek 和 SimplePDF 是 GPL v3，只参考产品逻辑，不直接复制进闭源或分发版本。
- MuPDF 是 AGPL v3，第一版不作为主引擎。

---

## 官方资料

- Apple PDFView: https://developer.apple.com/documentation/pdfkit/pdfview
- Apple PDFSelection: https://developer.apple.com/documentation/pdfkit/pdfselection
- Apple Keychain: https://developer.apple.com/documentation/security/storing-keys-in-the-keychain
- DeepSeek API: https://api-docs.deepseek.com/
- DeepSeek Models & Pricing: https://api-docs.deepseek.com/quick_start/pricing
- DeepSeek Change Log: https://api-docs.deepseek.com/updates

