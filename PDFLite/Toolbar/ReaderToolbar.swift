import PDFKit
import SwiftUI

/// Reader toolbar items, attached via `.toolbar { ReaderToolbar(...) }` so they live in the
/// macOS title bar (single-row with `.windowToolbarStyle(.unified)`). No standalone HStack any
/// more — that used to consume an extra ~36 px under the system title bar for no reason.
struct ReaderToolbar: ToolbarContent {
    @Bindable var session: DocumentSession
    @State private var pageInputBuffer: String = ""
    @FocusState private var pageFieldFocused: Bool

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

        // Right side: page nav + zoom + display mode + highlight + search + translation.
        // System shows the document title automatically (via .navigationTitle), so we don't
        // include our own title text here.
        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                session.previousPage()
            } label: {
                Image(systemName: "chevron.left")
            }
            .disabled(!session.canGoPrevious)
            .help("Previous Page")

            pageInputField

            Text("/ \(session.pageCount)")
                .foregroundStyle(.secondary)
                .monospacedDigit()

            Button {
                session.nextPage()
            } label: {
                Image(systemName: "chevron.right")
            }
            .disabled(!session.canGoNext)
            .help("Next Page")

            Button {
                session.zoomOut()
            } label: {
                Image(systemName: "minus.magnifyingglass")
            }
            .help("Zoom Out")

            Text(zoomPercent)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .frame(minWidth: 44, alignment: .trailing)

            Button {
                session.zoomIn()
            } label: {
                Image(systemName: "plus.magnifyingglass")
            }
            .help("Zoom In")

            Button("Fit") {
                session.fitWidth()
            }
            .help("Fit Width")

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

    private var zoomPercent: String {
        "\(Int((session.scaleFactor * 100).rounded()))%"
    }

    private var pageInputField: some View {
        TextField("", text: $pageInputBuffer)
            .textFieldStyle(.roundedBorder)
            .frame(width: 48)
            .multilineTextAlignment(.center)
            .focused($pageFieldFocused)
            .onSubmit {
                commitPageInput()
            }
            .onChange(of: pageFieldFocused) { _, focused in
                if !focused { syncPageInput() }
            }
            .onAppear { syncPageInput() }
            .onChange(of: session.currentPageIndex) { _, _ in
                syncPageInput()
            }
    }

    private func syncPageInput() {
        pageInputBuffer = "\(session.currentPageIndex + 1)"
    }

    private func commitPageInput() {
        guard let n = Int(pageInputBuffer.trimmingCharacters(in: .whitespaces)) else {
            syncPageInput()
            return
        }
        let target = max(1, min(session.pageCount, n)) - 1
        session.goToPage(target)
        syncPageInput()
    }
}
