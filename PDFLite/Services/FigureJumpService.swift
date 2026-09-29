import Foundation
import PDFKit

/// Locate the caption for a `Figure N` / `Table N` reference. The scan reads each page's text
/// layer off the main actor and classifies lines with the reference's regexes; the main actor only
/// turns the winning character range into a `PDFSelection` (one page, cheap).
///
/// Why not `PDFDocument.findString`: a substring hit for "Figure 3." can't tell the caption
/// ("Figure 3. Overview of…", at the start of its line) from an earlier sentence ending "…as shown
/// in Figure 3." — the old code jumped to whichever came first in the document — and it blocked
/// the main thread for up to a dozen full-document scans when nothing matched. `beginFindString`
/// isn't a drop-in either: its match notifications are delivered to every observer of the
/// document, so a jump would leak into the search bar's results (and vice versa).
///
/// Preference order (the source page is where the user clicked, so it loses ties):
/// 1. a caption line on another page, 2. a caption line on the source page, 3. an inline mention
/// on another page, 4. any mention. Within a tier, document order.
@MainActor
enum FigureJumpService {
    /// A match in one page's `string`: UTF-16 range, the coordinates `PDFPage.selection(for:)`
    /// takes (Skim feeds `page.string` ranges to `selectionForRange:` the same way).
    struct Hit: Equatable, Sendable {
        let pageIndex: Int
        let range: NSRange
    }

    /// nil when the document has no usable hit or the surrounding task was cancelled — a
    /// superseded jump must not navigate. Text extraction hops off the main actor
    /// (`page.string` is only read, as in `ReferenceIndex`).
    static func locate(
        _ reference: FigureReference,
        in document: PDFDocument,
        excluding sourcePage: Int?
    ) async -> PDFSelection? {
        let box = DocumentBox(document: document)
        guard let hit = await scan(box: box, reference: reference, sourcePage: sourcePage),
              !Task.isCancelled,
              let page = document.page(at: hit.pageIndex) else { return nil }
        // https://developer.apple.com/documentation/pdfkit/pdfpage/selection(for:)-20y9d
        // (nil for an empty range; fall back to the whole page so the jump still lands there).
        return page.selection(for: hit.range) ?? page.selection(for: page.bounds(for: .cropBox))
    }

    /// Keeps the live document crossing to the background scan, which only reads it.
    private struct DocumentBox: @unchecked Sendable {
        let document: PDFDocument
    }

    private nonisolated static func scan(
        box: DocumentBox,
        reference: FigureReference,
        sourcePage: Int?
    ) async -> Hit? {
        let document = box.document
        var finder = HitFinder(reference: reference, sourcePage: sourcePage)
        for index in 0..<document.pageCount {
            if Task.isCancelled { return nil }
            guard let text = document.page(at: index)?.string, !text.isEmpty else { continue }
            finder.consume(pageIndex: index, text: text)
            if finder.isDecided { break }
        }
        return finder.best
    }

    /// Pure core of the search, over already-extracted page texts — the part the tests drive
    /// with plain strings.
    nonisolated static func bestHit(
        forPageTexts texts: [String],
        reference: FigureReference,
        sourcePage: Int?
    ) -> Hit? {
        var finder = HitFinder(reference: reference, sourcePage: sourcePage)
        for (index, text) in texts.enumerated() {
            finder.consume(pageIndex: index, text: text)
            if finder.isDecided { break }
        }
        return finder.best
    }

    /// First hit per tier, fed page by page in document order.
    private struct HitFinder {
        let sourcePage: Int?
        private let caption: NSRegularExpression
        private let mention: NSRegularExpression
        private var captionElsewhere: Hit?
        private var captionOnSource: Hit?
        private var mentionElsewhere: Hit?
        private var mentionOnSource: Hit?

        init(reference: FigureReference, sourcePage: Int?) {
            self.sourcePage = sourcePage
            caption = reference.captionRegex
            mention = reference.mentionRegex
        }

        /// A caption on another page is the best answer there is: nothing later can beat it.
        var isDecided: Bool { captionElsewhere != nil }

        var best: Hit? { captionElsewhere ?? captionOnSource ?? mentionElsewhere ?? mentionOnSource }

        mutating func consume(pageIndex: Int, text: String) {
            let range = NSRange(location: 0, length: (text as NSString).length)
            let isSource = pageIndex == sourcePage
            if let match = caption.firstMatch(in: text, range: range) {
                let hit = Hit(pageIndex: pageIndex, range: match.range)
                if isSource { captionOnSource = captionOnSource ?? hit } else { captionElsewhere = hit }
                return
            }
            // A mention only matters while no caption has been seen anywhere; the page-level
            // early `return` above is fine because that page already holds the caption.
            if captionOnSource == nil, isSource ? mentionOnSource == nil : mentionElsewhere == nil,
               let match = mention.firstMatch(in: text, range: range) {
                let hit = Hit(pageIndex: pageIndex, range: match.range)
                if isSource { mentionOnSource = hit } else { mentionElsewhere = hit }
            }
        }
    }
}
