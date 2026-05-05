# AGENTS.md

本文件是 AI coding 工具入口。PDFLite 的唯一权威设计、架构、依赖、Phase、参考项目和执行纪律都在：

[docs/SYSTEM_DESIGN.md](docs/SYSTEM_DESIGN.md)

## 必须遵守

1. 写任何代码前，先读取 `docs/SYSTEM_DESIGN.md`。
2. 后续实现以 `docs/SYSTEM_DESIGN.md` 为唯一基准。
3. `docs/archive/` 下的 Markdown 只保留历史讨论，不得作为实现依据。
4. 如发现其他文档与 `docs/SYSTEM_DESIGN.md` 冲突，以 `docs/SYSTEM_DESIGN.md` 为准。
5. 不要修改 `references/` 下代码；它们只作为只读参考项目。

## 开工前自检

每次实现功能前，先回答：

1. 当前处于 `docs/SYSTEM_DESIGN.md` 定义的哪个 Phase？
2. 该 Phase 允许参考哪些项目？
3. 已经在 `references/` 中 grep 到哪些相关文件？
4. 是否涉及 PDFKit？如果涉及，对应 Apple 官方文档 URL 是什么？
5. 是否会违反 `docs/SYSTEM_DESIGN.md` 的禁止项或依赖白名单？

