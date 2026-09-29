import Foundation
import PDFKit

struct OutlineItem: Identifiable {
    let id: String
    let title: String
    let pageIndex: Int?
    let destination: PDFDestination?
    let children: [OutlineItem]?

    init?(outline: PDFOutline, path: String = "root") {
        let trimmed = outline.label?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        title = trimmed.isEmpty ? "Untitled" : trimmed

        if let dest = outline.destination, let page = dest.page, let document = page.document {
            pageIndex = document.index(for: page)
            destination = dest
        } else {
            pageIndex = nil
            destination = nil
        }

        let baseID = "\(path)|\(title)|\(pageIndex ?? -1)"
        id = baseID

        let count = outline.numberOfChildren
        if count > 0 {
            var items: [OutlineItem] = []
            items.reserveCapacity(count)
            for index in 0..<count {
                guard let child = outline.child(at: index),
                      let item = OutlineItem(outline: child, path: "\(baseID)-\(index)") else { continue }
                items.append(item)
            }
            children = items.isEmpty ? nil : items
        } else {
            children = nil
        }
    }
}

/// One outline node in document order, used to resolve "which outline entry does the current
/// page belong to" without walking the tree on every page change.
struct FlatOutlineEntry {
    let id: String
    let pageIndex: Int
    let ancestorIDs: [String]
    let point: CGPoint?

    /// Entries must be sorted by page, keeping document order for equal-page targets.
    static func active(in entries: [FlatOutlineEntry], at location: ReadingLocation) -> FlatOutlineEntry? {
        var low = 0
        var high = entries.count
        while low < high {
            let mid = (low + high) / 2
            if entries[mid].pageIndex < location.pageIndex { low = mid + 1 }
            else { high = mid }
        }
        var best = low > 0 ? entries[low - 1] : nil
        var lastY: CGFloat?
        for entry in entries[low...] {
            guard entry.pageIndex == location.pageIndex else { break }
            guard let y = entry.point?.y, y.isFinite, let anchorY = location.point?.y else {
                if best?.pageIndex != location.pageIndex { best = entry }
                continue
            }
            if y >= anchorY - 1, lastY != y {
                best = entry
                lastY = y
            }
        }
        return best ?? entries.first
    }
}
