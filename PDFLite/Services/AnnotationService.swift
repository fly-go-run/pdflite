import AppKit
import Foundation
import PDFKit

/// Owns runtime PDFAnnotation ↔ persisted record mapping for a single open document.
/// One AnnotationService instance per DocumentSession.
@MainActor
final class AnnotationService {
    /// Default highlight tint — kept here so future settings can override it without touching call sites.
    static let defaultHighlightColor = NSColor.systemYellow.withAlphaComponent(0.35)
    static let defaultHighlightHex = "#FFFF0059"
    private static let userNamePrefix = "pdflite:"

    private weak var document: PDFDocument?

    init(document: PDFDocument) {
        self.document = document
    }

    /// Recreate PDFAnnotations from persisted records and add them to their pages. Records of the
    /// same logical highlight share `groupId` so a single click on any of them resolves back to
    /// the group.
    func restore(records: [AnnotationRecord]) {
        guard let document else { return }

        for record in records {
            guard record.pageIndex >= 0, record.pageIndex < document.pageCount,
                  let page = document.page(at: record.pageIndex) else { continue }

            let rects: [CGRect]
            do { rects = try AnnotationRectCoder.decode(record.boundsJSON) } catch { continue }

            for rect in rects {
                let annotation = makeHighlight(bounds: rect, hex: record.color, groupId: record.groupId)
                page.addAnnotation(annotation)
            }
        }
    }

    /// Create runtime PDFAnnotations and the matching persistence records for `snapshot` — one
    /// AnnotationRecord per page touched, all sharing a fresh groupId. Caller is responsible for
    /// inserting all records via the repository.
    func createHighlight(snapshot: SelectionSnapshot, documentId: Int64) -> [AnnotationRecord] {
        let groupId = UUID().uuidString
        let now = Date()
        var records: [AnnotationRecord] = []

        for pageSelection in snapshot.pages {
            // Add per-line annotations to the page; each carries `userName` keyed by groupId so a
            // click on any of them resolves to the same logical highlight.
            for rect in pageSelection.lineRects {
                let annotation = makeHighlight(
                    bounds: rect,
                    hex: Self.defaultHighlightHex,
                    groupId: groupId
                )
                pageSelection.page.addAnnotation(annotation)
            }

            let boundsJSON = (try? AnnotationRectCoder.encode(pageSelection.lineRects)) ?? "[]"
            // Record's `selected_text` only carries this page's portion of the original text. The
            // full source can be reconstructed by concatenating across the group, in document
            // order — repository helpers do that for the "复制原文" context menu.
            let pageText = excerpt(forPage: pageSelection, in: snapshot)
            records.append(AnnotationRecord(
                id: UUID().uuidString,
                groupId: groupId,
                documentId: documentId,
                pageIndex: pageSelection.pageIndex,
                annotationType: "highlight",
                boundsJSON: boundsJSON,
                color: Self.defaultHighlightHex,
                selectedText: pageText,
                noteContent: nil,
                translationId: nil,
                createdAt: now,
                updatedAt: now
            ))
        }

        return records
    }

    /// Remove every PDFAnnotation belonging to `groupId` from the document.
    func removeRuntimeAnnotations(groupId: String) {
        guard let document else { return }
        for pageIndex in 0..<document.pageCount {
            guard let page = document.page(at: pageIndex) else { continue }
            for annotation in page.annotations where Self.groupId(from: annotation) == groupId {
                page.removeAnnotation(annotation)
            }
        }
    }

    /// Resolve a runtime annotation back to the group it belongs to, when it's one of ours.
    func groupId(for annotation: PDFAnnotation) -> String? {
        Self.groupId(from: annotation)
    }

    static func groupId(from annotation: PDFAnnotation) -> String? {
        guard let userName = annotation.userName,
              userName.hasPrefix(userNamePrefix) else { return nil }
        let id = String(userName.dropFirst(userNamePrefix.count))
        return id.isEmpty ? nil : id
    }

    // MARK: - Helpers

    private func makeHighlight(bounds: CGRect, hex: String?, groupId: String) -> PDFAnnotation {
        let annotation = PDFAnnotation(bounds: bounds, forType: .highlight, withProperties: nil)
        annotation.color = Self.color(fromHex: hex) ?? Self.defaultHighlightColor
        annotation.userName = Self.userName(for: groupId)
        return annotation
    }

    /// Slice the snapshot's rawText down to the portion belonging to `pageSelection`. v0
    /// approximates by splitting the rawText into paragraph blocks proportional to per-page line
    /// counts — works well enough for "copy original" context menus without a full per-line text
    /// map.
    private func excerpt(forPage pageSelection: PageSelection, in snapshot: SelectionSnapshot) -> String {
        // For a single-page snapshot just return the whole rawText.
        if !snapshot.spansMultiplePages { return snapshot.rawText }

        // Cheap approximation: distribute rawText across pages by line-count weight. Over- or
        // under-sliced edges are tolerable since this only feeds the right-click "复制原文" menu;
        // translation uses snapshot.rawText directly.
        let totalLines = snapshot.pages.reduce(0) { $0 + $1.lineRects.count }
        guard totalLines > 0 else { return snapshot.rawText }

        let chars = Array(snapshot.rawText)
        let totalChars = chars.count

        var startLines = 0
        for p in snapshot.pages {
            if p.pageIndex == pageSelection.pageIndex { break }
            startLines += p.lineRects.count
        }
        let endLines = startLines + pageSelection.lineRects.count

        let startChar = totalChars * startLines / totalLines
        let endChar = totalChars * endLines / totalLines
        guard startChar < endChar else { return "" }
        return String(chars[startChar..<endChar])
    }

    private static func userName(for groupId: String) -> String {
        "\(userNamePrefix)\(groupId)"
    }

    static func hex(from color: NSColor) -> String {
        guard let rgb = color.usingColorSpace(.sRGB) else { return defaultHighlightHex }
        let r = Int(round(rgb.redComponent * 255))
        let g = Int(round(rgb.greenComponent * 255))
        let b = Int(round(rgb.blueComponent * 255))
        let a = Int(round(rgb.alphaComponent * 255))
        return String(format: "#%02X%02X%02X%02X", r, g, b, a)
    }

    static func color(fromHex hex: String?) -> NSColor? {
        guard let hex, hex.hasPrefix("#") else { return nil }
        let chars = hex.dropFirst()
        guard chars.count == 8 || chars.count == 6,
              let value = UInt32(chars, radix: 16) else { return nil }
        let hasAlpha = chars.count == 8
        let r = CGFloat((value >> (hasAlpha ? 24 : 16)) & 0xFF) / 255
        let g = CGFloat((value >> (hasAlpha ? 16 : 8)) & 0xFF) / 255
        let b = CGFloat((value >> (hasAlpha ? 8 : 0)) & 0xFF) / 255
        let a = hasAlpha ? CGFloat(value & 0xFF) / 255 : 1
        return NSColor(srgbRed: r, green: g, blue: b, alpha: a)
    }
}
