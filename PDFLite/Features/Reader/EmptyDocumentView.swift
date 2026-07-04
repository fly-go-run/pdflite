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
    }

    private var hero: some View {
        VStack(spacing: 14) {
            Image(systemName: "doc.richtext")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(.secondary)
            Text("没有打开的 PDF")
                .font(.title2)
            Button("打开 PDF…") {
                session.presentOpenPanel()
            }
            .keyboardShortcut("o", modifiers: .command)
            .controlSize(.large)
            Text("或将 PDF 拖到此处")
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
                        openAction: { session.openDocument(url: recent.url) },
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
            provider.loadDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier) { data, _ in
                guard let data,
                      let url = URL(dataRepresentation: data, relativeTo: nil),
                      url.pathExtension.lowercased() == "pdf"
                else { return }
                DispatchQueue.main.async {
                    if session.canAcceptOpen {
                        session.openDocument(url: url)
                    } else {
                        DocumentOpener.requestOpen(url: url)
                    }
                }
            }
        }
        return true
    }
}
