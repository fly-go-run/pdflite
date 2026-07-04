import PDFKit
import SwiftUI

/// Reader toolbar items, attached via `.toolbar { ReaderToolbar(...) }` so they live in the
/// macOS title bar (single-row with `.windowToolbarStyle(.unified)`). Page navigation and
/// zoom live in `PDFFloatingBar` at the bottom of the document column instead — keeping
/// them in `.primaryAction` made them straddle the detail/inspector boundary when the
/// translation inspector was open.
struct ReaderToolbar: ToolbarContent {
    @Bindable var session: DocumentSession
    private let shortcuts = AppShortcuts.shared

    var body: some ToolbarContent {
        // Left side: home + back/forward. Sidebar toggle is provided automatically by
        // NavigationSplitView at the leading edge of the toolbar.
        ToolbarItemGroup(placement: .navigation) {
            Button {
                session.closeDocument()
            } label: {
                Image(systemName: "house")
            }
            .disabled(!session.hasDocument)
            .help("回到书架")

            Button {
                session.goBack()
            } label: {
                Image(systemName: "chevron.backward")
            }
            .disabled(!session.navigation.canGoBack)
            .help(shortcuts.helpText("后退", for: .goBack))

            Button {
                session.goForward()
            } label: {
                Image(systemName: "chevron.forward")
            }
            .disabled(!session.navigation.canGoForward)
            .help(shortcuts.helpText("前进", for: .goForward))
        }

        // Right side: display mode + highlight + search + translation inspector toggle.
        // Items stay mounted permanently (disabled instead of removed) so the toolbar layout
        // never jumps when a selection appears.
        ToolbarItemGroup(placement: .primaryAction) {
            Picker("", selection: $session.displayMode) {
                Image(systemName: "doc.text").tag(PDFDisplayMode.singlePageContinuous)
                Image(systemName: "rectangle.split.2x1").tag(PDFDisplayMode.twoUpContinuous)
            }
            .pickerStyle(.segmented)
            .frame(width: 84)
            .disabled(!session.hasDocument)
            .help("显示模式")

            Button {
                session.highlightSelection()
            } label: {
                Image(systemName: "highlighter")
                    .foregroundStyle(session.hasSelection ? .yellow : .secondary)
            }
            .disabled(!session.hasSelection)
            .help(shortcuts.helpText("高亮选区", for: .highlightSelection))

            Button {
                session.toggleSearch()
            } label: {
                Image(systemName: "magnifyingglass")
            }
            .disabled(!session.hasDocument)
            .help("搜索 (⌘F)")

            Button {
                session.isTranslationInspectorVisible.toggle()
            } label: {
                Image(systemName: "character.bubble")
                    .foregroundStyle(session.isTranslationInspectorVisible ? Color.accentColor : .primary)
            }
            .disabled(!session.hasDocument)
            .help(shortcuts.helpText("翻译面板", for: .toggleInspector))
        }
    }
}
