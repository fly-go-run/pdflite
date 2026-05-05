import SwiftUI

struct EmptyDocumentView: View {
    @Bindable var session: DocumentSession
    @State private var recentFiles = RecentFilesService.shared

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "doc.richtext")
                .font(.system(size: 48, weight: .light))
                .foregroundStyle(.secondary)

            Text("没有打开的 PDF")
                .font(.title2)

            Button("打开 PDF…") {
                session.presentOpenPanel()
            }
            .keyboardShortcut("o", modifiers: .command)
            .controlSize(.large)

            if !recentFiles.recentFiles.isEmpty {
                Divider()
                    .frame(maxWidth: 280)
                    .padding(.top, 8)

                Text("最近打开")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                VStack(alignment: .leading, spacing: 4) {
                    ForEach(recentFiles.recentFiles.prefix(5)) { recent in
                        Button {
                            session.openDocument(url: recent.url)
                        } label: {
                            HStack {
                                Image(systemName: "doc")
                                    .foregroundStyle(.secondary)
                                Text(recent.displayName)
                                Spacer()
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .frame(maxWidth: 280)
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
