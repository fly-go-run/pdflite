import AppKit
import PDFKit

/// Snapshot of the user's current selection — page-coordinate rects per visual line, the cleaned
/// text, and a screen-space rect for placing floating UI on top of it.
struct SelectionSnapshot {
    let pageIndex: Int
    let page: PDFPage
    /// Page-coordinate rects, one per visual line. Avoid one big rect that crosses columns.
    let lineRects: [CGRect]
    /// Verbatim text from PDFSelection — cleaning happens in TextCleaner (Phase 3).
    let rawText: String
}

enum SelectionService {
    /// Build a snapshot from the PDFView's current selection. Returns nil for empty/no-page
    /// selections. If a selection spans multiple pages we collapse to its first page — Phase 1+2
    /// only support same-page highlights; cross-page highlight is a Phase 4 concern (§5.3).
    @MainActor
    static func snapshot(from pdfView: PDFView) -> SelectionSnapshot? {
        guard let selection = pdfView.currentSelection,
              let page = selection.pages.first,
              let document = page.document else {
            return nil
        }
        guard selection.pages.count == 1 else { return nil }

        let pageIndex = document.index(for: page)
        let rawText = selection.string ?? ""
        guard !rawText.isEmpty else { return nil }

        // selectionsByLine() splits multi-line / multi-column selections into one PDFSelection
        // per visual line. Each line's bounds(for:) gives a tight rect, so a two-column layout
        // produces two rects per row instead of one big rect spanning the gutter.
        let lineSelections = selection.selectionsByLine()
        var rects: [CGRect] = []
        if lineSelections.isEmpty {
            rects.append(selection.bounds(for: page))
        } else {
            for line in lineSelections {
                guard line.pages.first === page else { continue }
                let r = line.bounds(for: page)
                guard r.width > 0.5, r.height > 0.5 else { continue }
                rects.append(r)
            }
        }
        guard !rects.isEmpty else { return nil }

        return SelectionSnapshot(
            pageIndex: pageIndex,
            page: page,
            lineRects: rects,
            rawText: rawText
        )
    }
}
