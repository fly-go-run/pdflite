import PDFKit
import SwiftUI
import UniformTypeIdentifiers

struct AppCommands: Commands {
    let focusedSession: DocumentSession?
    @Bindable var recentFiles: RecentFilesService
    @Bindable var shortcuts: AppShortcuts

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            // Cmd+O is platform-standard; we keep it hard-coded so the customizable list isn't
            // crowded with defaults users won't change anyway.
            Button("Open…") {
                focusedSession?.presentOpenPanel()
            }
            .keyboardShortcut("o", modifiers: .command)
            .disabled(focusedSession == nil)

            Menu("Open Recent") {
                ForEach(recentFiles.recentFiles) { recent in
                    Button(recent.displayName) {
                        focusedSession?.openDocument(url: recent.url)
                    }
                }
                if !recentFiles.recentFiles.isEmpty {
                    Divider()
                    Button("Clear Menu") {
                        recentFiles.clear()
                    }
                }
            }
            .disabled(recentFiles.recentFiles.isEmpty)
        }

        CommandGroup(after: .pasteboard) {
            Divider()
            Button("Find…") {
                focusedSession?.toggleSearch(open: true)
            }
            .keyboardShortcut("f", modifiers: .command)
            .disabled(focusedSession?.hasDocument != true)
        }

        CommandMenu("View") {
            Button("Zoom In") { focusedSession?.zoomIn() }
                .keyboardShortcut(shortcuts.value(for: .zoomIn))
                .disabled(focusedSession?.hasDocument != true)

            Button("Zoom Out") { focusedSession?.zoomOut() }
                .keyboardShortcut(shortcuts.value(for: .zoomOut))
                .disabled(focusedSession?.hasDocument != true)

            Button("Actual Size") { focusedSession?.actualSize() }
                .keyboardShortcut(shortcuts.value(for: .actualSize))
                .disabled(focusedSession?.hasDocument != true)

            Button("Fit Width") { focusedSession?.fitWidth() }
                .keyboardShortcut(shortcuts.value(for: .fitWidth))
                .disabled(focusedSession?.hasDocument != true)

            Divider()

            Picker("Display", selection: Binding(
                get: { focusedSession?.displayMode ?? .singlePageContinuous },
                set: { focusedSession?.displayMode = $0 }
            )) {
                Text("Single Page Continuous").tag(PDFDisplayMode.singlePageContinuous)
                Text("Two Pages Continuous").tag(PDFDisplayMode.twoUpContinuous)
            }
            .pickerStyle(.inline)
            .disabled(focusedSession?.hasDocument != true)

            Divider()

            Button(focusedSession?.isSidebarVisible == true ? "Hide Sidebar" : "Show Sidebar") {
                focusedSession?.isSidebarVisible.toggle()
            }
            .keyboardShortcut(shortcuts.value(for: .toggleSidebar))
            .disabled(focusedSession?.hasDocument != true)
        }

        CommandMenu("Tools") {
            Button("Translate Selection") {
                focusedSession?.translateCurrentSelection()
            }
            .keyboardShortcut(shortcuts.value(for: .translateSelection))
            .disabled(focusedSession?.hasSelection != true)

            Button("Highlight Selection") {
                focusedSession?.highlightSelection()
            }
            .keyboardShortcut(shortcuts.value(for: .highlightSelection))
            .disabled(focusedSession?.hasSelection != true)

            Divider()

            Button(focusedSession?.isTranslationInspectorVisible == true
                   ? "Hide Translation Inspector"
                   : "Show Translation Inspector") {
                focusedSession?.isTranslationInspectorVisible.toggle()
            }
            .keyboardShortcut(shortcuts.value(for: .toggleInspector))
            .disabled(focusedSession?.hasDocument != true)
        }

        CommandMenu("Go") {
            Button("Next Page") { focusedSession?.nextPage() }
                .keyboardShortcut(shortcuts.value(for: .nextPage))
                .disabled(focusedSession?.canGoNext != true)

            Button("Previous Page") { focusedSession?.previousPage() }
                .keyboardShortcut(shortcuts.value(for: .previousPage))
                .disabled(focusedSession?.canGoPrevious != true)

            Divider()

            Button("First Page") { focusedSession?.goToFirstPage() }
                .keyboardShortcut(shortcuts.value(for: .firstPage))
                .disabled(focusedSession?.hasDocument != true)

            Button("Last Page") { focusedSession?.goToLastPage() }
                .keyboardShortcut(shortcuts.value(for: .lastPage))
                .disabled(focusedSession?.hasDocument != true)

            Divider()

            Button("Back") { focusedSession?.goBack() }
                .keyboardShortcut(shortcuts.value(for: .goBack))
                .disabled(focusedSession?.navigation.canGoBack != true)

            Button("Forward") { focusedSession?.goForward() }
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
