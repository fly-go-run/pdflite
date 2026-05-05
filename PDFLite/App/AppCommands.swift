import PDFKit
import SwiftUI
import UniformTypeIdentifiers

struct AppCommands: Commands {
    let focusedSession: DocumentSession?
    @Bindable var recentFiles: RecentFilesService

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
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
                .keyboardShortcut("+", modifiers: .command)
                .disabled(focusedSession?.hasDocument != true)

            Button("Zoom Out") { focusedSession?.zoomOut() }
                .keyboardShortcut("-", modifiers: .command)
                .disabled(focusedSession?.hasDocument != true)

            Button("Actual Size") { focusedSession?.actualSize() }
                .keyboardShortcut("1", modifiers: [.command, .option])
                .disabled(focusedSession?.hasDocument != true)

            Button("Fit Width") { focusedSession?.fitWidth() }
                .keyboardShortcut("0", modifiers: .command)
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
            .keyboardShortcut("s", modifiers: [.command, .option])
            .disabled(focusedSession?.hasDocument != true)
        }

        CommandMenu("Tools") {
            Button("Translate Selection") {
                focusedSession?.translateCurrentSelection()
            }
            .keyboardShortcut("t", modifiers: [.command, .control])
            .disabled(focusedSession?.hasSelection != true)

            Button("Highlight Selection") {
                focusedSession?.highlightSelection()
            }
            .keyboardShortcut("h", modifiers: [.command, .control])
            .disabled(focusedSession?.hasSelection != true)

            Divider()

            Button(focusedSession?.isTranslationInspectorVisible == true
                   ? "Hide Translation Inspector"
                   : "Show Translation Inspector") {
                focusedSession?.isTranslationInspectorVisible.toggle()
            }
            .keyboardShortcut("i", modifiers: [.command, .option])
            .disabled(focusedSession?.hasDocument != true)
        }

        CommandMenu("Go") {
            Button("Next Page") { focusedSession?.nextPage() }
                .keyboardShortcut(.rightArrow, modifiers: .command)
                .disabled(focusedSession?.canGoNext != true)

            Button("Previous Page") { focusedSession?.previousPage() }
                .keyboardShortcut(.leftArrow, modifiers: .command)
                .disabled(focusedSession?.canGoPrevious != true)

            Divider()

            Button("First Page") { focusedSession?.goToFirstPage() }
                .keyboardShortcut(.upArrow, modifiers: [.command, .option])
                .disabled(focusedSession?.hasDocument != true)

            Button("Last Page") { focusedSession?.goToLastPage() }
                .keyboardShortcut(.downArrow, modifiers: [.command, .option])
                .disabled(focusedSession?.hasDocument != true)

            Divider()

            Button("Back") { focusedSession?.goBack() }
                .keyboardShortcut("[", modifiers: .command)
                .disabled(focusedSession?.navigation.canGoBack != true)

            Button("Forward") { focusedSession?.goForward() }
                .keyboardShortcut("]", modifiers: .command)
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
