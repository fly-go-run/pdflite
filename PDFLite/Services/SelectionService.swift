import AppKit
import PDFKit

/// One page's contribution to a selection: the page itself plus per-line rects (no big rect that
/// crosses columns).
struct PageSelection {
    let pageIndex: Int
    let page: PDFPage
    let lineRects: [CGRect]
    let text: String
}

/// Snapshot of the user's current selection. May span multiple pages — `pages` is ordered by
/// document order. Convenience accessors (`pageIndex`, `page`, `lineRects`) point at the first
/// page so panel positioning, single-page persistence and existing callers keep working.
struct SelectionSnapshot {
    let pages: [PageSelection]
    /// Verbatim text from PDFSelection, joined across lines/pages with `\n` between visual lines
    /// inside a paragraph and `\n\n` between paragraphs (large vertical gaps + page breaks).
    /// TextCleaner reads this and preserves the paragraph structure for the LLM.
    let rawText: String

    var pageIndex: Int { pages.first?.pageIndex ?? 0 }
    var page: PDFPage { pages.first!.page }
    var lineRects: [CGRect] { pages.first?.lineRects ?? [] }
    var spansMultiplePages: Bool { pages.count > 1 }
}

enum SelectionService {
    /// Build a snapshot from PDFView's current selection. Walks `selectionsByLine()`, orders by
    /// page (keeping PDFKit's order within a page), groups per page, and assembles a
    /// paragraph-aware rawText using the line's vertical gap as the paragraph cue.
    @MainActor
    static func snapshot(from pdfView: PDFView) -> SelectionSnapshot? {
        guard let selection = pdfView.currentSelection,
              !selection.pages.isEmpty else {
            return nil
        }

        struct LineEntry {
            let pageIndex: Int
            let page: PDFPage
            let rect: CGRect
            let text: String
        }

        // Build per-line entries. Each line is its own PDFSelection in selectionsByLine, so its
        // bounds(for:) gives a tight rect that doesn't span across columns.
        let lineSelections = selection.selectionsByLine()
        var entries: [LineEntry] = []

        if lineSelections.isEmpty {
            // Fallback for selections PDFKit doesn't split (rare). Just use the bounds on each
            // page touched.
            for page in selection.pages {
                guard let document = page.document else { continue }
                let rect = selection.bounds(for: page)
                guard rect.width > 0.5, rect.height > 0.5 else { continue }
                entries.append(LineEntry(
                    pageIndex: document.index(for: page),
                    page: page,
                    rect: rect,
                    text: text(in: selection, on: page)
                ))
            }
        } else {
            for line in lineSelections {
                guard let page = line.pages.first, let document = page.document else { continue }
                let rect = line.bounds(for: page)
                guard rect.width > 0.5, rect.height > 0.5 else { continue }
                entries.append(LineEntry(
                    pageIndex: document.index(for: page),
                    page: page,
                    rect: rect,
                    text: (line.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                ))
            }
        }

        guard !entries.isEmpty else { return nil }

        // Document order: page asc, and *within* a page exactly the order PDFKit returned. A
        // geometric top-first sort would put column 2 ahead of column 1 (its lines sit higher on
        // the page) and break a paragraph that runs from the bottom of one column into the next.
        entries = inDocumentOrder(entries) { $0.pageIndex }

        // Median line height drives the paragraph-break threshold so the heuristic adapts to font
        // size automatically. 0.6× the line height tends to catch real paragraph gaps without
        // tripping on regular leading.
        let heights = entries.map { $0.rect.height }.sorted()
        let medianHeight = heights[heights.count / 2]
        let paragraphGapThreshold = max(medianHeight * 0.6, 4)

        // Assemble rawText with paragraph awareness; collect per-page rects as we go.
        // Rects accumulate in-place per page — rebuilding an ever-growing array per line would
        // make a full-page selection quadratic in its line count.
        var rawTextLines: [String] = []
        var pageRects: [Int: [CGRect]] = [:]
        var pageText: [Int: String] = [:]
        var pageForIndex: [Int: PDFPage] = [:]
        var pageOrder: [Int] = []
        var prev: LineEntry?

        for entry in entries {
            if let prev {
                let isParagraphBreak: Bool
                if entry.pageIndex != prev.pageIndex {
                    // Page break is always a paragraph break.
                    isParagraphBreak = true
                } else {
                    let gap = prev.rect.minY - entry.rect.maxY
                    isParagraphBreak = gap > paragraphGapThreshold
                }
                let separator = isParagraphBreak ? "\n\n" : "\n"
                rawTextLines.append(separator)
                if entry.pageIndex == prev.pageIndex {
                    pageText[entry.pageIndex, default: ""].append(separator)
                }
            }
            if !entry.text.isEmpty {
                rawTextLines.append(entry.text)
                pageText[entry.pageIndex, default: ""].append(entry.text)
            }

            // Track per-page rects.
            if pageRects[entry.pageIndex] == nil {
                pageOrder.append(entry.pageIndex)
                pageForIndex[entry.pageIndex] = entry.page
            }
            pageRects[entry.pageIndex, default: []].append(entry.rect)

            prev = entry
        }

        let rawText = rawTextLines.joined().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawText.isEmpty else { return nil }

        let pages: [PageSelection] = pageOrder.compactMap { index in
            guard let page = pageForIndex[index], let rects = pageRects[index] else { return nil }
            return PageSelection(pageIndex: index, page: page, lineRects: rects,
                                 text: (pageText[index] ?? "").trimmingCharacters(in: .whitespacesAndNewlines))
        }
        guard !pages.isEmpty else { return nil }

        return SelectionSnapshot(pages: pages, rawText: rawText)
    }

    /// Orders `items` by page index only. The sort is stable, so items on the same page keep
    /// PDFKit's own reading order (which follows columns; a y-based sort would not). Pure and
    /// independent of PDFKit so the ordering rule can be unit-tested directly.
    static func inDocumentOrder<T>(_ items: [T], pageIndex: (T) -> Int) -> [T] {
        items.enumerated()
            .sorted { a, b in
                let (pa, pb) = (pageIndex(a.element), pageIndex(b.element))
                return pa != pb ? pa < pb : a.offset < b.offset
            }
            .map(\.element)
    }

    /// Use PDFKit's character ranges when line splitting is unavailable. A multi-page
    /// selection's `string` includes all pages and must never be assigned to each page.
    private static func text(in selection: PDFSelection, on page: PDFPage) -> String {
        guard let source = page.string as NSString? else { return "" }
        return (0..<selection.numberOfTextRanges(on: page)).compactMap { index in
            let range = selection.range(at: index, on: page)
            guard range.location != NSNotFound, range.location <= source.length,
                  range.length <= source.length - range.location else { return nil }
            return source.substring(with: range)
        }.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
