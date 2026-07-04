import Foundation
import PDFKit

/// Locate the caption page for a `Figure N` / `Table N` reference using PDFKit's full-doc
/// search. Caption-shaped hits ("Figure 3:" / "Figure 3.") win over inline mentions; the source
/// page is excluded so the user always advances to the actual caption, not where they clicked.
@MainActor
enum FigureJumpService {
    static func locate(
        _ reference: FigureReference,
        in document: PDFDocument,
        excluding sourcePage: Int?
    ) -> PDFSelection? {
        // Prefer caption-style hits across every spelling ("Figure 3:", "Fig. 3.", "Fig 3 |")
        // before falling back to bare labels. The "|" trailing covers Nature-style captions.
        for label in reference.searchLabels {
            for trailing in [":", ".", " |"] {
                let needle = label + trailing
                let matches = document.findString(needle, withOptions: [.caseInsensitive])
                if let hit = pickTarget(from: matches, sourcePage: sourcePage, in: document) {
                    return hit
                }
            }
        }

        // Fallback to bare labels — typically inline mentions, but better than nothing.
        for label in reference.searchLabels {
            let bare = document.findString(label, withOptions: [.caseInsensitive])
            if let hit = pickTarget(from: bare, sourcePage: sourcePage, in: document) {
                return hit
            }
        }
        return nil
    }

    private static func pickTarget(
        from matches: [PDFSelection],
        sourcePage: Int?,
        in document: PDFDocument
    ) -> PDFSelection? {
        // First try to find a hit that's NOT on the user's source page. This is what the user
        // actually wants — they're trying to navigate away.
        for selection in matches {
            guard let page = selection.pages.first else { continue }
            let pageIndex = document.index(for: page)
            if let sourcePage, pageIndex == sourcePage { continue }
            return selection
        }
        // No off-source hit; if the only matches are on the source page (or there's no source),
        // fall back to the first one so the user at least gets feedback.
        return matches.first
    }
}
