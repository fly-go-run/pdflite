import PDFKit
import SwiftUI

struct ReaderView: View {
    @Bindable var session: DocumentSession

    var body: some View {
        NavigationSplitView(columnVisibility: sidebarVisibility) {
            SidebarView(session: session)
                .navigationSplitViewColumnWidth(240)
        } detail: {
            ZStack(alignment: .top) {
                PDFKitRepresentable(session: session)

                if session.isSearchVisible {
                    SearchBar(session: session)
                        .padding(.top, 12)
                }
            }
            .overlay(alignment: .bottom) {
                PDFFloatingBar(session: session)
                    .padding(.bottom, 16)
            }
        }
        .inspector(isPresented: $session.isTranslationInspectorVisible) {
            TranslationInspector(session: session)
                .inspectorColumnWidth(min: 280, ideal: 320, max: 480)
        }
        .toolbar {
            ReaderToolbar(session: session)
        }
    }

    private var sidebarVisibility: Binding<NavigationSplitViewVisibility> {
        Binding(
            get: { session.isSidebarVisible ? .all : .detailOnly },
            set: { session.isSidebarVisible = ($0 != .detailOnly) }
        )
    }
}

/// Floating capsule at the bottom of the PDF area that hosts page navigation and zoom.
/// Lives here (not in the window toolbar) so the controls visually anchor to the document
/// column and don't shift onto the inspector when it opens.
struct PDFFloatingBar: View {
    @Bindable var session: DocumentSession
    @State private var pageInputBuffer: String = ""
    @FocusState private var pageFieldFocused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Button {
                session.previousPage()
            } label: {
                Image(systemName: "chevron.left")
            }
            .buttonStyle(.borderless)
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
            .buttonStyle(.borderless)
            .disabled(!session.canGoNext)
            .help("Next Page")

            Divider().frame(height: 14)

            Button {
                session.zoomOut()
            } label: {
                Image(systemName: "minus.magnifyingglass")
            }
            .buttonStyle(.borderless)
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
            .buttonStyle(.borderless)
            .help("Zoom In")

            Button("Fit") {
                session.fitWidth()
            }
            .buttonStyle(.borderless)
            .help("Fit Width")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.2), radius: 8, y: 2)
    }

    private var zoomPercent: String {
        "\(Int((session.scaleFactor * 100).rounded()))%"
    }

    private var pageInputField: some View {
        TextField("", text: $pageInputBuffer)
            .textFieldStyle(.plain)
            .frame(width: 32)
            .multilineTextAlignment(.center)
            .monospacedDigit()
            .focused($pageFieldFocused)
            .padding(.horizontal, 4)
            .padding(.vertical, 2)
            .background(Color.secondary.opacity(0.15), in: RoundedRectangle(cornerRadius: 4))
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
