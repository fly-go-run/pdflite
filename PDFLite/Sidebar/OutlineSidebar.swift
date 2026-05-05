import PDFKit
import SwiftUI

struct OutlineSidebar: View {
    @Bindable var session: DocumentSession

    var body: some View {
        Group {
            if let root = session.outlineRoot, let children = root.children, !children.isEmpty {
                List {
                    OutlineItemRows(items: children, session: session, depth: 0)
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
    let depth: Int

    var body: some View {
        ForEach(items) { item in
            if let children = item.children, !children.isEmpty {
                OutlineDisclosure(item: item, children: children, session: session, depth: depth)
            } else {
                OutlineItemLabel(item: item, session: session)
            }
        }
    }
}

/// Default-expand only the first level so the outline opens to depth 2 (top-level + their
/// direct children). Deeper nodes stay collapsed until the user expands them.
private struct OutlineDisclosure: View {
    let item: OutlineItem
    let children: [OutlineItem]
    let session: DocumentSession
    let depth: Int
    @State private var isExpanded: Bool

    init(item: OutlineItem, children: [OutlineItem], session: DocumentSession, depth: Int) {
        self.item = item
        self.children = children
        self.session = session
        self.depth = depth
        self._isExpanded = State(initialValue: depth == 0)
    }

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            OutlineItemRows(items: children, session: session, depth: depth + 1)
        } label: {
            OutlineItemLabel(item: item, session: session)
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
