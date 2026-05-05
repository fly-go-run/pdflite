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
    /// id ↔ live PDFAnnotation. PDFAnnotation isn't Hashable so we use a dictionary keyed by id.
    private var liveByID: [String: PDFAnnotation] = [:]
    /// Reverse lookup so a runtime click on an annotation can find its persisted id.
    /// Annotations also carry their id in `userName`, so this dict is mostly a fast path.
    private var idByAnnotation: [ObjectIdentifier: String] = [:]

    init(document: PDFDocument) {
        self.document = document
    }

    /// Recreate PDFAnnotations from persisted records and add them to their pages.
    /// Must run after the PDFView has the document loaded.
    func restore(records: [AnnotationRecord]) {
        guard let document else { return }
        liveByID.removeAll(keepingCapacity: true)
        idByAnnotation.removeAll(keepingCapacity: true)

        for record in records {
            guard record.pageIndex >= 0, record.pageIndex < document.pageCount,
                  let page = document.page(at: record.pageIndex) else { continue }

            let rects: [CGRect]
            do { rects = try AnnotationRectCoder.decode(record.boundsJSON) } catch { continue }

            for rect in rects {
                let annotation = makeHighlight(bounds: rect, hex: record.color, id: record.id)
                page.addAnnotation(annotation)
            }
            // Track only the *first* runtime annotation per record id; reverse map lets a click
            // on any of them resolve to the same record.
            // (We store all of them via per-rect annotations sharing one userName id.)
        }
    }

    /// Create a multi-rect highlight, add it to the page, return the AnnotationRecord ready for
    /// persistence. Caller is responsible for inserting into the repository.
    func createHighlight(snapshot: SelectionSnapshot, documentId: Int64) -> AnnotationRecord? {
        guard let document, let page = document.page(at: snapshot.pageIndex) else { return nil }
        let id = UUID().uuidString

        for rect in snapshot.lineRects {
            let annotation = makeHighlight(bounds: rect, hex: Self.defaultHighlightHex, id: id)
            page.addAnnotation(annotation)
        }

        let now = Date()
        let boundsJSON = (try? AnnotationRectCoder.encode(snapshot.lineRects)) ?? "[]"
        return AnnotationRecord(
            id: id,
            documentId: documentId,
            pageIndex: snapshot.pageIndex,
            annotationType: "highlight",
            boundsJSON: boundsJSON,
            color: Self.defaultHighlightHex,
            selectedText: snapshot.rawText,
            noteContent: nil,
            createdAt: now,
            updatedAt: now
        )
    }

    /// Remove every PDFAnnotation that belongs to `id` from its page.
    func removeRuntimeAnnotations(id: String) {
        guard let document else { return }
        for pageIndex in 0..<document.pageCount {
            guard let page = document.page(at: pageIndex) else { continue }
            // Iterate a snapshot — removeAnnotation mutates the array.
            for annotation in page.annotations where self.id(for: annotation) == id {
                page.removeAnnotation(annotation)
            }
        }
        liveByID.removeValue(forKey: id)
    }

    /// Return the persisted id for a runtime annotation, if it's one of ours.
    func id(for annotation: PDFAnnotation) -> String? {
        if let id = Self.persistedID(from: annotation) {
            return id
        }
        return idByAnnotation[ObjectIdentifier(annotation)]
    }

    static func persistedID(from annotation: PDFAnnotation) -> String? {
        guard let userName = annotation.userName,
              userName.hasPrefix(userNamePrefix) else { return nil }
        let id = String(userName.dropFirst(userNamePrefix.count))
        return id.isEmpty ? nil : id
    }

    // MARK: - Helpers

    private func makeHighlight(bounds: CGRect, hex: String?, id: String) -> PDFAnnotation {
        let annotation = PDFAnnotation(bounds: bounds, forType: .highlight, withProperties: nil)
        annotation.color = Self.color(fromHex: hex) ?? Self.defaultHighlightColor
        annotation.userName = Self.userName(for: id)
        liveByID[id] = annotation
        idByAnnotation[ObjectIdentifier(annotation)] = id
        return annotation
    }

    private static func userName(for id: String) -> String {
        "\(userNamePrefix)\(id)"
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
