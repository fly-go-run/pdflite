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
    /// Pages each highlight group touches, recorded at restore/create time so deleting a group
    /// only scans its own pages instead of every annotation in the document.
    private var groupPageIndexes: [String: Set<Int>] = [:]

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
            groupPageIndexes[record.groupId, default: []].insert(record.pageIndex)
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
            groupPageIndexes[groupId, default: []].insert(pageSelection.pageIndex)

            let boundsJSON = (try? AnnotationRectCoder.encode(pageSelection.lineRects)) ?? "[]"
            // Record's `selected_text` only carries this page's portion of the original text. The
            // full source can be reconstructed by concatenating across the group, in document
            // order — repository helpers do that for the "复制原文" context menu.
            let pageText = pageSelection.text
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

    /// Remove every PDFAnnotation belonging to `groupId` from the document. Scans only the pages
    /// recorded for the group; falls back to a full-document sweep for unknown groups.
    func removeRuntimeAnnotations(groupId: String) {
        guard let document else { return }
        let pages = groupPageIndexes.removeValue(forKey: groupId).map(Array.init)
            ?? Array(0..<document.pageCount)
        for pageIndex in pages {
            guard pageIndex >= 0, pageIndex < document.pageCount,
                  let page = document.page(at: pageIndex) else { continue }
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
