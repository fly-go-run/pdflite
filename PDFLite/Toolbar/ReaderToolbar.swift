import PDFKit
import SwiftUI

struct ReaderToolbar: View {
    @Bindable var session: DocumentSession
    @State private var pageInputBuffer: String = ""
    @FocusState private var pageFieldFocused: Bool

    var body: some View {
        HStack(spacing: 12) {
            Button {
                session.isSidebarVisible.toggle()
            } label: {
                Image(systemName: "sidebar.left")
            }
            .help("Toggle Sidebar")

            Divider().frame(height: 18)

            Text(session.title)
                .font(.headline)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer()

            HStack(spacing: 4) {
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
            }

            Divider().frame(height: 18)

            HStack(spacing: 4) {
                Button {
                    session.zoomOut()
                } label: {
                    Image(systemName: "minus.magnifyingglass")
                }
                .help("Zoom Out")

                Text(zoomPercent)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .frame(minWidth: 48, alignment: .trailing)

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

                Button("100%") {
                    session.actualSize()
                }
                .help("Actual Size")
            }

            Divider().frame(height: 18)

            Picker("", selection: $session.displayMode) {
                Image(systemName: "doc.text").tag(PDFDisplayMode.singlePageContinuous)
                Image(systemName: "rectangle.split.2x1").tag(PDFDisplayMode.twoUpContinuous)
            }
            .pickerStyle(.segmented)
            .frame(width: 96)
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
        }
        .buttonStyle(.borderless)
        .controlSize(.regular)
        .onChange(of: session.currentPageIndex) { _, _ in
            syncPageInput()
        }
        .onAppear { syncPageInput() }
    }

    private var zoomPercent: String {
        "\(Int((session.scaleFactor * 100).rounded()))%"
    }

    private var pageInputField: some View {
        TextField("", text: $pageInputBuffer)
            .textFieldStyle(.roundedBorder)
            .frame(width: 56)
            .multilineTextAlignment(.center)
            .focused($pageFieldFocused)
            .onSubmit {
                commitPageInput()
            }
            .onChange(of: pageFieldFocused) { _, focused in
                if !focused { syncPageInput() }
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
