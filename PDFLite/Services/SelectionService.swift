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
    /// The selection exceeded `SelectionLimits`, so no text was assembled and no per-line rects
    /// were computed: `rawText` is empty and `pages` holds a single anchor entry (one bounding
    /// rect on one page) that exists only so the floating card can be positioned. Such a snapshot
    /// must never reach translation, highlighting or clipboard code — `DocumentSession` gates every
    /// entry point on this flag.
    let isTooLong: Bool

    init(pages: [PageSelection], rawText: String, isTooLong: Bool = false) {
        self.pages = pages
        self.rawText = rawText
        self.isTooLong = isTooLong
    }

    var pageIndex: Int { pages.first?.pageIndex ?? 0 }
    var page: PDFPage { pages.first!.page }
    var lineRects: [CGRect] { pages.first?.lineRects ?? [] }
    var spansMultiplePages: Bool { pages.count > 1 }
}

/// How large a selection may be before it is treated as "not something the user meant to
/// translate or highlight" (⌘A, or dragging across half a book). One place, because the cheap gate
/// in `SelectionService`, the auto-action, the manual commands and the UI copy all speak about
/// the same number.
enum SelectionLimits {
    /// Longest selection, in PDFKit characters (sum of the selection's text-range lengths, which
    /// includes the newline between lines), that may be translated, highlighted or auto-actioned.
    /// ~6000 is about one dense two-column paper page: room for any paragraph or a few of them,
    /// well inside one DeepSeek request, and far below "the whole book". Design §9 allows only
    /// text the user actively selected to leave the machine — a ⌘A must not qualify by accident.
    static let maxCharacters = 6000

    /// Widest page span that is examined at all. A page of ordinary paper text is 3–7k characters,
    /// so a few full pages already pass `maxCharacters`; 12 is generous even for figure-heavy
    /// stretches while keeping the probe bounded on a cold document (each probed page may make
    /// PDFKit extract that page's text). Beyond it the selection is too long without looking at
    /// any text.
    static let maxPageSpan = 12

    /// One-line refusal shown when the user asks for `action` ("翻译" / "高亮") on an oversized
    /// selection.
    static func tooLongMessage(for action: String) -> String {
        "选区过长（超过约 \(maxCharacters) 字），请缩小范围后再\(action)"
    }
}

enum SelectionSize: Equatable {
    case withinLimit
    case tooLong
}

enum SelectionService {
    /// How many times the O(lines) pass (`selectionsByLine` + per-line text/rect extraction) has
    /// run. A test seam: the size gate must return before that pass for an oversized selection,
    /// and asserting on this counter proves it without depending on wall-clock time.
    @MainActor private(set) static var linePassCount = 0

    /// Cheap size gate. Only integer arithmetic over PDFKit's per-page text ranges (Apple:
    /// https://developer.apple.com/documentation/pdfkit/pdfselection/pages,
    /// https://developer.apple.com/documentation/pdfkit/pdfselection/numberoftextranges(on:),
    /// https://developer.apple.com/documentation/pdfkit/pdfselection/range(at:on:)) — no string is
    /// assembled and no line is visited. It bails out on the page count first, then as soon as the
    /// running character total passes the limit, so its cost is bounded by
    /// `SelectionLimits.maxPageSpan` pages no matter how large the selection is.
    static func size(of selection: PDFSelection) -> SelectionSize {
        let pages = selection.pages
        if pages.count > SelectionLimits.maxPageSpan { return .tooLong }

        var total = 0
        for page in pages {
            for index in 0..<selection.numberOfTextRanges(on: page) {
                let range = selection.range(at: index, on: page)
                guard range.location != NSNotFound else { continue }
                total += range.length
                if total > SelectionLimits.maxCharacters { return .tooLong }
            }
        }
        return .withinLimit
    }

    /// Build a snapshot from PDFView's current selection. Walks `selectionsByLine()`, orders by
    /// page (keeping PDFKit's order within a page), groups per page, and assembles a
    /// paragraph-aware rawText using the line's vertical gap as the paragraph cue. A selection
    /// over `SelectionLimits` skips all of that and returns a flagged anchor-only snapshot.
    @MainActor
    static func snapshot(from pdfView: PDFView) -> SelectionSnapshot? {
        guard let selection = pdfView.currentSelection,
              !selection.pages.isEmpty else {
            return nil
        }

        if size(of: selection) == .tooLong {
            return tooLongSnapshot(for: selection, in: pdfView)
        }
        linePassCount += 1

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

    /// Flagged snapshot for an oversized selection. The floating card still needs something to
    /// hang off, so this computes exactly one rect with one `bounds(for:)` call: on the page the
    /// reader is looking at when that page is part of the selection (⌘A from the middle of a
    /// book), else on the selection's first page. Nil when neither has drawable bounds — then
    /// there is nothing to show a card next to and nothing actionable either.
    @MainActor
    private static func tooLongSnapshot(for selection: PDFSelection, in pdfView: PDFView) -> SelectionSnapshot? {
        let pages = selection.pages
        var candidates: [PDFPage] = []
        if let current = pdfView.currentPage, pages.contains(current) { candidates.append(current) }
        if let first = pages.first { candidates.append(first) }

        for page in candidates {
            guard let document = page.document else { continue }
            let rect = selection.bounds(for: page)
            guard rect.width > 0.5, rect.height > 0.5 else { continue }
            let anchor = PageSelection(pageIndex: document.index(for: page), page: page,
                                       lineRects: [rect], text: "")
            return SelectionSnapshot(pages: [anchor], rawText: "", isTooLong: true)
        }
        return nil
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
