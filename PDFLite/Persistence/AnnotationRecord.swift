import Foundation
import GRDB

struct AnnotationRecord: Codable, FetchableRecord, PersistableRecord, Equatable {
    static let databaseTableName = "annotations"

    var id: String                  // UUID string
    var documentId: Int64
    var pageIndex: Int
    var annotationType: String      // "highlight" for now
    var boundsJSON: String          // [[x,y,w,h], ...] in page coordinates
    var color: String?              // "#RRGGBBAA"
    var selectedText: String?
    var noteContent: String?
    var translationId: Int64?       // bound translation row, set by auto-translate-on-highlight
    var createdAt: Date
    var updatedAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case documentId = "document_id"
        case pageIndex = "page_index"
        case annotationType = "annotation_type"
        case boundsJSON = "bounds_json"
        case color
        case selectedText = "selected_text"
        case noteContent = "note_content"
        case translationId = "translation_id"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}

/// JSON representation of one line-rect inside an annotation.
struct AnnotationRect: Codable, Equatable {
    var x: Double
    var y: Double
    var w: Double
    var h: Double

    init(_ rect: CGRect) {
        x = Double(rect.origin.x)
        y = Double(rect.origin.y)
        w = Double(rect.size.width)
        h = Double(rect.size.height)
    }

    var cgRect: CGRect {
        CGRect(x: x, y: y, width: w, height: h)
    }
}

enum AnnotationRectCoder {
    static func encode(_ rects: [CGRect]) throws -> String {
        let payload = rects.map(AnnotationRect.init)
        let data = try JSONEncoder().encode(payload)
        return String(data: data, encoding: .utf8) ?? "[]"
    }

    static func decode(_ json: String) throws -> [CGRect] {
        guard let data = json.data(using: .utf8) else { return [] }
        let payload = try JSONDecoder().decode([AnnotationRect].self, from: data)
        return payload.map(\.cgRect)
    }
}
