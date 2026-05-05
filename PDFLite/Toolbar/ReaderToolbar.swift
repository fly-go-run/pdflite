import PDFKit
import SwiftUI

/// Reader toolbar items, attached via `.toolbar { ReaderToolbar(...) }` so they live in the
/// macOS title bar (single-row with `.windowToolbarStyle(.unified)`). Page navigation and
/// zoom live in `PDFFloatingBar` at the bottom of the document column instead — keeping
/// them in `.primaryAction` made them straddle the detail/inspector boundary when the
/// translation inspector was open.
struct ReaderToolbar: ToolbarContent {
    @Bindable var session: DocumentSession

    var body: some ToolbarContent {
        // Left side: back/forward. Sidebar toggle is provided automatically by
        // NavigationSplitView at the leading edge of the toolbar.
        ToolbarItemGroup(placement: .navigation) {
            Button {
                session.goBack()
            } label: {
                Image(systemName: "chevron.backward")
            }
            .disabled(!session.navigation.canGoBack)
            .help("Back (⌘[)")

            Button {
                session.goForward()
            } label: {
                Image(systemName: "chevron.forward")
            }
            .disabled(!session.navigation.canGoForward)
            .help("Forward (⌘])")
        }

        // Right side: display mode + highlight + search + translation inspector toggle.
        ToolbarItemGroup(placement: .primaryAction) {
            Picker("", selection: $session.displayMode) {
                Image(systemName: "doc.text").tag(PDFDisplayMode.singlePageContinuous)
                Image(systemName: "rectangle.split.2x1").tag(PDFDisplayMode.twoUpContinuous)
            }
            .pickerStyle(.segmented)
            .frame(width: 84)
            .help("Display Mode")

            if session.hasSelection {
                Button {
                    session.highlightSelection()
                } label: {
                    Image(systemName: "highlighter")
                        .foregroundStyle(.yellow)
                }
                .help("Highlight Selection (⌃⌘H)")
            }

            Button {
                session.toggleSearch()
            } label: {
                Image(systemName: "magnifyingglass")
            }
            .help("Search")

            Button {
                session.isTranslationInspectorVisible.toggle()
            } label: {
                Image(systemName: "character.bubble")
                    .foregroundStyle(session.isTranslationInspectorVisible ? Color.accentColor : .primary)
            }
            .help("Toggle Translation Inspector (⌥⌘I)")
        }
    }
}
