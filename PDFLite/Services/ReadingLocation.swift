import Foundation
import PDFKit

/// A viewport anchor in PDF page coordinates, shared by history and persistence.
/// `autoScales` preserves fit-width intent independently of the last measured scale.
struct ReadingLocation: Sendable, Equatable {
    var pageIndex: Int
    var point: CGPoint? = nil
    var scale: Double? = nil
    var autoScales: Bool = true
    var displayMode: Int = 1

    init(pageIndex: Int, point: CGPoint? = nil, scale: Double? = nil,
         autoScales: Bool = true, displayMode: Int = 1) {
        self.pageIndex = pageIndex
        self.point = point
        self.scale = scale
        self.autoScales = autoScales
        self.displayMode = displayMode
    }

    init(record: DocumentRecord) {
        pageIndex = record.lastPage
        if let x = record.lastScrollX, let y = record.lastScrollY,
           x.isFinite, y.isFinite {
            point = CGPoint(x: x, y: y)
        }
        scale = record.lastZoom
        autoScales = record.lastAutoScales ?? (record.lastZoom == nil)
        displayMode = record.displayMode ?? 1
    }

    @MainActor
    static func capture(in view: PDFView) -> ReadingLocation? {
        guard let document = view.document, let page = view.currentPage else { return nil }
        let index = document.index(for: page)
        guard index != NSNotFound else { return nil }
        let topLeft = CGPoint(x: view.bounds.minX,
                              y: view.isFlipped ? view.bounds.minY : view.bounds.maxY)
        let point = view.convert(topLeft, to: page)
        guard point.x.isFinite, point.y.isFinite else { return nil }
        return ReadingLocation(pageIndex: index, point: point,
                               scale: Double(view.scaleFactor), autoScales: view.autoScales,
                               displayMode: view.displayMode.dbValue)
    }

    @MainActor
    func restore(in view: PDFView) {
        guard let document = view.document, document.pageCount > 0,
              let page = document.page(at: max(0, min(pageIndex, document.pageCount - 1))) else { return }
        view.displayMode = PDFDisplayMode.from(dbValue: displayMode)
        view.autoScales = autoScales
        if !autoScales, let scale, scale.isFinite, scale > 0 {
            view.scaleFactor = CGFloat(scale)
        }
        if let point, point.x.isFinite, point.y.isFinite {
            view.go(to: PDFDestination(page: page, at: point))
        } else {
            view.go(to: page)
        }
    }

    /// Ignore sub-point rounding drift when deduplicating history, not distinct places on a page.
    func isNear(_ other: ReadingLocation) -> Bool {
        guard pageIndex == other.pageIndex, autoScales == other.autoScales,
              displayMode == other.displayMode,
              abs((scale ?? 1) - (other.scale ?? 1)) < 0.001 else { return false }
        switch (point, other.point) {
        case let (a?, b?): return abs(a.x - b.x) < 1 && abs(a.y - b.y) < 1
        case (nil, nil): return true
        default: return false
        }
    }
}
