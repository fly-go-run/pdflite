import PDFKit
import SwiftUI
import UniformTypeIdentifiers

struct AppCommands: Commands {
    let focusedSession: DocumentSession?
    @Bindable var recentFiles: RecentFilesService
    @Bindable var shortcuts: AppShortcuts

    var body: some Commands {
        // `after: .newItem` keeps the system-provided New Window (⌘N) so a second document can
        // always be opened side by side.
        CommandGroup(after: .newItem) {
            // Reader windows have tabbingMode = .preferred, so a spawned window lands as a new
            // tab in the current tab group — the platform-standard ⌘T behavior.
            Button("新建标签页") {
                DocumentOpener.spawnWindow?()
            }
            .keyboardShortcut("t", modifiers: .command)

            // Cmd+O is platform-standard; we keep it hard-coded so the customizable list isn't
            // crowded with defaults users won't change anyway. Routing goes through
            // DocumentOpener so an occupied window is never silently replaced.
            Button("打开…") {
                DocumentOpener.presentOpenPanel(preferring: focusedSession)
            }
            .keyboardShortcut("o", modifiers: .command)

            Menu("最近打开") {
                ForEach(recentFiles.recentFiles) { recent in
                    Button(recent.displayName) {
                        DocumentOpener.requestOpen(url: recent.url)
                    }
                }
                if !recentFiles.recentFiles.isEmpty {
                    Divider()
                    Button("清除菜单") {
                        recentFiles.clear()
                    }
                }
            }
            .disabled(recentFiles.recentFiles.isEmpty)
        }

        CommandGroup(replacing: .printItem) {
            Button("打印…") {
                focusedSession?.printDocument()
            }
            .keyboardShortcut("p", modifiers: .command)
            .disabled(focusedSession?.hasDocument != true)
        }

        CommandGroup(after: .pasteboard) {
            Divider()
            Button("查找…") {
                focusedSession?.toggleSearch(open: true)
            }
            .keyboardShortcut("f", modifiers: .command)
            .disabled(focusedSession?.hasDocument != true)

            Button("查找下一个") {
                focusedSession?.search.next()
            }
            .keyboardShortcut("g", modifiers: .command)
            .disabled(focusedSession?.search.hasResults != true)

            Button("查找上一个") {
                focusedSession?.search.previous()
            }
            .keyboardShortcut("g", modifiers: [.command, .shift])
            .disabled(focusedSession?.search.hasResults != true)
        }

        // Injected into the system View menu (labeled 显示 under zh-Hans) instead of a
        // CommandMenu, which would create a second menu with the same name.
        CommandGroup(after: .sidebar) {
            Divider()

            Button("放大") { focusedSession?.zoomIn() }
                .keyboardShortcut(shortcuts.value(for: .zoomIn))
                .disabled(focusedSession?.hasDocument != true)

            Button("缩小") { focusedSession?.zoomOut() }
                .keyboardShortcut(shortcuts.value(for: .zoomOut))
                .disabled(focusedSession?.hasDocument != true)

            Button("实际大小") { focusedSession?.actualSize() }
                .keyboardShortcut(shortcuts.value(for: .actualSize))
                .disabled(focusedSession?.hasDocument != true)

            Button("适合宽度") { focusedSession?.fitWidth() }
                .keyboardShortcut(shortcuts.value(for: .fitWidth))
                .disabled(focusedSession?.hasDocument != true)

            Divider()

            Picker("页面布局", selection: Binding(
                get: { focusedSession?.displayMode ?? .singlePageContinuous },
                set: { focusedSession?.displayMode = $0 }
            )) {
                Text("单页连续").tag(PDFDisplayMode.singlePageContinuous)
                Text("双页连续").tag(PDFDisplayMode.twoUpContinuous)
            }
            .pickerStyle(.inline)
            .disabled(focusedSession?.hasDocument != true)

            Divider()

            Button(focusedSession?.isSidebarVisible == true ? "隐藏侧栏" : "显示侧栏") {
                focusedSession?.isSidebarVisible.toggle()
            }
            .keyboardShortcut(shortcuts.value(for: .toggleSidebar))
            .disabled(focusedSession?.hasDocument != true)
        }

        CommandMenu("工具") {
            Button("翻译选区") {
                focusedSession?.translateCurrentSelection()
            }
            .keyboardShortcut(shortcuts.value(for: .translateSelection))
            .disabled(focusedSession?.hasSelection != true)

            Button("高亮选区") {
                focusedSession?.highlightSelection()
            }
            .keyboardShortcut(shortcuts.value(for: .highlightSelection))
            .disabled(focusedSession?.hasSelection != true)

            Divider()

            Button(focusedSession?.isTranslationInspectorVisible == true
                   ? "隐藏翻译面板"
                   : "显示翻译面板") {
                focusedSession?.isTranslationInspectorVisible.toggle()
            }
            .keyboardShortcut(shortcuts.value(for: .toggleInspector))
            .disabled(focusedSession?.hasDocument != true)
        }

        CommandMenu("前往") {
            Button("下一页") { focusedSession?.nextPage() }
                .keyboardShortcut(shortcuts.value(for: .nextPage))
                .disabled(focusedSession?.canGoNext != true)

            Button("上一页") { focusedSession?.previousPage() }
                .keyboardShortcut(shortcuts.value(for: .previousPage))
                .disabled(focusedSession?.canGoPrevious != true)

            Divider()

            Button("第一页") { focusedSession?.goToFirstPage() }
                .keyboardShortcut(shortcuts.value(for: .firstPage))
                .disabled(focusedSession?.hasDocument != true)

            Button("最后一页") { focusedSession?.goToLastPage() }
                .keyboardShortcut(shortcuts.value(for: .lastPage))
                .disabled(focusedSession?.hasDocument != true)

            Divider()

            Button("后退") { focusedSession?.goBack() }
                .keyboardShortcut(shortcuts.value(for: .goBack))
                .disabled(focusedSession?.navigation.canGoBack != true)

            Button("前进") { focusedSession?.goForward() }
                .keyboardShortcut(shortcuts.value(for: .goForward))
                .disabled(focusedSession?.navigation.canGoForward != true)
        }
    }
}

private struct DocumentSessionFocusedKey: FocusedValueKey {
    typealias Value = DocumentSession
}

extension FocusedValues {
    var documentSession: DocumentSession? {
        get { self[DocumentSessionFocusedKey.self] }
        set { self[DocumentSessionFocusedKey.self] = newValue }
    }
}
