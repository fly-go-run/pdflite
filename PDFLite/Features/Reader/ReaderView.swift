import PDFKit
import SwiftUI
import UniformTypeIdentifiers

/// Detail-column content for a loaded document. Lives inside the persistent
/// `NavigationSplitView` owned by `ReaderWindowView`, so the window's toolbar /
/// sidebar configuration doesn't churn when toggling between empty and loaded states.
struct ReaderView: View {
    @Bindable var session: DocumentSession
    @State private var isDropTargeted = false

    var body: some View {
        HStack(spacing: 0) {
            ZStack(alignment: .top) {
                PDFKitRepresentable(session: session)
                    .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
                        handleDrop(providers: providers)
                    }
                    .overlay {
                        if isDropTargeted {
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .strokeBorder(
                                    Color.accentColor,
                                    style: StrokeStyle(lineWidth: 2, dash: [6])
                                )
                                .padding(12)
                                .allowsHitTesting(false)
                        }
                    }

                VStack(spacing: 8) {
                    if session.isSearchVisible {
                        SearchBar(session: session)
                    }
                    if session.isLikelyScanned && !session.scannedHintDismissed {
                        scannedHintBanner
                    }
                }
                .padding(.top, 12)
            }
            .overlay(alignment: .bottom) {
                PDFFloatingBar(session: session)
                    .padding(.bottom, 16)
            }

            if session.isTranslationInspectorVisible {
                Divider()
                TranslationInspector(session: session)
                    .frame(width: 320)
                    .background {
                        NSColorBackground(color: .windowBackgroundColor)
                            .ignoresSafeArea(edges: .bottom)
                    }
            }
        }
    }

    /// Dropping PDFs onto an open document never replaces it — every file routes through
    /// DocumentOpener (focus if already open, otherwise a new window).
    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        guard !providers.isEmpty else { return false }
        for provider in providers {
            provider.loadDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier) { data, _ in
                guard let data,
                      let url = URL(dataRepresentation: data, relativeTo: nil),
                      url.pathExtension.lowercased() == "pdf"
                else { return }
                DispatchQueue.main.async {
                    DocumentOpener.requestOpen(url: url)
                }
            }
        }
        return true
    }

    private var scannedHintBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(.orange)
            Text("此 PDF 没有文本层（可能是扫描版），无法选词、翻译和搜索")
                .font(.system(size: 12))
            Button {
                session.scannedHintDismissed = true
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10))
            }
            .buttonStyle(.borderless)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Color.orange.opacity(0.3)))
        .shadow(radius: 4, y: 2)
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
            .help("上一页")

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
            .help("下一页")

            Divider().frame(height: 14)

            Button {
                session.zoomOut()
            } label: {
                Image(systemName: "minus.magnifyingglass")
            }
            .buttonStyle(.borderless)
            .help("缩小")

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
            .help("放大")

            Button("适宽") {
                session.fitWidth()
            }
            .buttonStyle(.borderless)
            .help("适合宽度")
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
