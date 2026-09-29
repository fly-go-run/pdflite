import SwiftUI
import UniformTypeIdentifiers

struct EmptyDocumentView: View {
    @Bindable var session: DocumentSession
    @State private var recentFiles = RecentFilesService.shared
    @State private var isDropTargeted = false

    var body: some View {
        ScrollView {
            VStack(spacing: 28) {
                hero
                if !recentFiles.recentFiles.isEmpty {
                    bookshelf
                }
            }
            .padding(.horizontal, 40)
            .padding(.vertical, 36)
            .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            NSColorBackground(color: .windowBackgroundColor)
                .ignoresSafeArea()
        }
        .onDrop(of: [.fileURL, .url], isTargeted: $isDropTargeted) { providers in
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
    }

    private var hero: some View {
        VStack(spacing: 14) {
            Image(systemName: "doc.richtext")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(.secondary)
            Text("没有打开的 PDF")
                .font(.title2)
            HStack(spacing: 12) {
                Button("打开 PDF…") {
                    session.presentOpenPanel()
                }
                .keyboardShortcut("o", modifiers: .command)
                .controlSize(.large)
                Button("从 URL 打开…") {
                    RemoteOpenPanelController.shared.show()
                }
                .controlSize(.large)
            }
            Text("或将 PDF 文件 / arXiv 链接拖到此处")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(.top, 12)
    }

    private var bookshelf: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("最近打开")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 130, maximum: 160), spacing: 24, alignment: .top)],
                alignment: .leading,
                spacing: 24
            ) {
                ForEach(recentFiles.recentFiles) { recent in
                    BookshelfCard(
                        recent: recent,
                        openAction: { DocumentOpener.requestOpen(url: recent.url, preferring: session) },
                        removeAction: { recentFiles.remove(recent) }
                    )
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 8)
    }

    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        guard !providers.isEmpty else { return false }
        // Multi-file drop: the first PDF fills this (empty) window, the rest open in their own
        // windows via DocumentOpener.
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                provider.loadDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier) { data, _ in
                    guard let data,
                          let url = URL(dataRepresentation: data, relativeTo: nil),
                          url.pathExtension.lowercased() == "pdf"
                    else { return }
                    DispatchQueue.main.async {
                        DocumentOpener.requestOpen(url: url, preferring: session)
                    }
                }
            } else if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
                // A link dragged out of a browser. Dropping it is an explicit "open this", so
                // the URL panel comes up already downloading.
                provider.loadDataRepresentation(forTypeIdentifier: UTType.url.identifier) { data, _ in
                    guard let data,
                          let url = URL(dataRepresentation: data, relativeTo: nil),
                          let scheme = url.scheme?.lowercased(),
                          scheme == "http" || scheme == "https"
                    else { return }
                    DispatchQueue.main.async {
                        RemoteOpenPanelController.shared.show(
                            prefill: url.absoluteString,
                            autoStart: true
                        )
                    }
                }
            }
        }
        return true
    }
}
