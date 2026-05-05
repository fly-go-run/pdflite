import PDFKit
import SwiftUI

struct OutlineSidebar: View {
    @Bindable var session: DocumentSession

    var body: some View {
        Group {
            if let root = session.outlineRoot, let children = root.children, !children.isEmpty {
                List {
                    OutlineItemRows(items: children, session: session)
                }
                .listStyle(.sidebar)
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "list.bullet.indent")
                        .font(.title2)
                        .foregroundStyle(.tertiary)
                    Text("此 PDF 没有目录")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding()
            }
        }
    }
}

private struct OutlineItemRows: View {
    let items: [OutlineItem]
    let session: DocumentSession

    var body: some View {
        ForEach(items) { item in
            if let children = item.children, !children.isEmpty {
                DisclosureGroup {
                    OutlineItemRows(items: children, session: session)
                } label: {
                    OutlineItemLabel(item: item, session: session)
                }
            } else {
                OutlineItemLabel(item: item, session: session)
            }
        }
    }
}

private struct OutlineItemLabel: View {
    let item: OutlineItem
    let session: DocumentSession

    var body: some View {
        Button {
            if let dest = item.destination {
                session.goToDestination(dest)
            } else if let pageIndex = item.pageIndex {
                session.goToPage(pageIndex)
            }
        } label: {
            HStack {
                Text(item.title)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer()
                if let pageIndex = item.pageIndex {
                    Text("\(pageIndex + 1)")
                        .foregroundStyle(.secondary)
                        .font(.caption)
                        .monospacedDigit()
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
