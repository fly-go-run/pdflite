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
    /// True when the underlying selection spanned multiple PDF pages and we collapsed it to the
    /// first page (per §5.3). UI surfaces a hint so the user knows only the first page's content
    /// is being translated/highlighted.
    let wasTruncatedToFirstPage: Bool
}

enum SelectionService {
    /// Build a snapshot from the PDFView's current selection. Returns nil for empty/no-page
    /// selections. Per §5.3, cross-page selections are truncated to the first page (rects, text)
    /// rather than dropped — that way the user still sees the action buttons and can translate /
    /// highlight / copy what's on the first page; the snapshot carries a flag so the UI can hint.
    @MainActor
    static func snapshot(from pdfView: PDFView) -> SelectionSnapshot? {
        guard let selection = pdfView.currentSelection,
              let page = selection.pages.first,
              let document = page.document else {
            return nil
        }

        let wasTruncated = selection.pages.count > 1
        let pageIndex = document.index(for: page)

        // selectionsByLine() splits multi-line / multi-column selections into one PDFSelection
        // per visual line. Each line's bounds(for:) gives a tight rect, so a two-column layout
        // produces two rects per row instead of one big rect spanning the gutter. Filtering by
        // `line.pages.first === page` naturally drops lines that belong to other pages.
        let lineSelections = selection.selectionsByLine()
        var rects: [CGRect] = []
        var firstPageStrings: [String] = []
        if lineSelections.isEmpty {
            rects.append(selection.bounds(for: page))
        } else {
            for line in lineSelections {
                guard line.pages.first === page else { continue }
                let r = line.bounds(for: page)
                guard r.width > 0.5, r.height > 0.5 else { continue }
                rects.append(r)
                if let s = line.string, !s.isEmpty {
                    firstPageStrings.append(s)
                }
            }
        }
        guard !rects.isEmpty else { return nil }

        // Use the per-line strings when the selection crossed pages so we keep first-page text
        // only. For single-page selections selectionsByLine sometimes splits hyphenated words
        // unhelpfully, so fall back to the full selection string in that case.
        let rawText: String
        if wasTruncated, !firstPageStrings.isEmpty {
            rawText = firstPageStrings.joined(separator: " ")
        } else {
            rawText = selection.string ?? ""
        }
        guard !rawText.isEmpty else { return nil }

        return SelectionSnapshot(
            pageIndex: pageIndex,
            page: page,
            lineRects: rects,
            rawText: rawText,
            wasTruncatedToFirstPage: wasTruncated
        )
    }
}
