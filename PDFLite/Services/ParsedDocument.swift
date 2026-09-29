import Foundation
import PDFKit

/// Result of parsing a PDF off the main thread: the document plus its pre-built outline tree.
/// @unchecked Sendable is sound here: the worker thread that builds it hands over ownership and
/// never touches the document again — it only ever crosses to the main actor once.
struct ParsedDocument: @unchecked Sendable {
    let document: PDFDocument
    let outline: OutlineItem?
    /// No extractable text in the sampled pages — likely a scanned PDF. Selection, translation
    /// and search won't work; the reader shows a hint instead of failing silently.
    let isLikelyScanned: Bool

    static func parse(url: URL) -> ParsedDocument? {
        guard let doc = PDFDocument(url: url) else { return nil }
        let outline = doc.outlineRoot.flatMap { OutlineItem(outline: $0) }
        var hasText = false
        for index in 0..<min(5, doc.pageCount) where !hasText {
            if let text = doc.page(at: index)?.string,
               !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                hasText = true
            }
        }
        return ParsedDocument(
            document: doc,
            outline: outline,
            isLikelyScanned: doc.pageCount > 0 && !hasText
        )
    }
}
