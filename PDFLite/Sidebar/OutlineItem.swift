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
