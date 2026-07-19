import PDFKit
import SwiftUI

struct OutlineSidebar: View {
    @Bindable var session: DocumentSession

    var body: some View {
        Group {
            if let root = session.outlineRoot, let children = root.children, !children.isEmpty {
                ScrollViewReader { proxy in
                    List {
                        OutlineItemRows(items: children, session: session, depth: 0)
                    }
                    .listStyle(.sidebar)
                    .onChange(of: session.activeOutlineItemID) { _, id in
                        guard let id else { return }
                        withAnimation(.easeInOut(duration: 0.15)) {
                            proxy.scrollTo(id)
                        }
                    }
                    .onAppear {
                        if let id = session.activeOutlineItemID {
                            proxy.scrollTo(id)
                        }
                    }
                }
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
/// direct children). Deeper nodes stay collapsed until the user expands them — or until the
/// reading position moves inside them, which auto-expands the ancestor chain.
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
        .onChange(of: session.activeOutlineAncestorIDs) { _, ids in
            if ids.contains(item.id) {
                isExpanded = true
            }
        }
        .onAppear {
            if session.activeOutlineAncestorIDs.contains(item.id) {
                isExpanded = true
            }
        }
    }
}

/// Thin observing wrapper: its body re-runs for every visible row whenever the active outline
/// entry changes (all rows read `activeOutlineItemID`), but it only does one comparison and
/// hands off to the Equatable core — so the HStack/background/Button tree is rebuilt for just
/// the two rows whose active state actually flipped, not the whole sidebar on every page turn.
private struct OutlineItemLabel: View {
    let item: OutlineItem
    let session: DocumentSession

    var body: some View {
        OutlineItemLabelCore(
            item: item,
            isActive: session.activeOutlineItemID == item.id,
            session: session
        )
    }
}

private struct OutlineItemLabelCore: View, Equatable {
    let item: OutlineItem
    let isActive: Bool
    let session: DocumentSession

    // session is deliberately ignored: it's the same object for the window's lifetime and only
    // serves the tap action.
    nonisolated static func == (lhs: OutlineItemLabelCore, rhs: OutlineItemLabelCore) -> Bool {
        lhs.item.id == rhs.item.id && lhs.isActive == rhs.isActive
    }

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
                    .fontWeight(isActive ? .semibold : .regular)
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
        .padding(.horizontal, 4)
        .padding(.vertical, 2)
        .background(
            isActive ? Color.accentColor.opacity(0.16) : Color.clear,
            in: RoundedRectangle(cornerRadius: 4)
        )
        .id(item.id)
    }
}
