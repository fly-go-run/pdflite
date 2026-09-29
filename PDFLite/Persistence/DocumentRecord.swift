import Foundation
import GRDB
import PDFKit

struct DocumentRecord: Codable, FetchableRecord, MutablePersistableRecord, Equatable {
    static let databaseTableName = "documents"

    var id: Int64?
    var fileHash: String
    var fileURL: String
    var title: String?
    var pageCount: Int
    var lastOpenedAt: Date?
    var lastPage: Int
    var lastZoom: Double?
    var lastScrollY: Double?
    var displayMode: Int?
    var lastScrollX: Double? = nil
    var lastAutoScales: Bool? = nil
    var createdAt: Date
    var updatedAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case fileHash = "file_hash"
        case fileURL = "file_url"
        case title
        case pageCount = "page_count"
        case lastOpenedAt = "last_opened_at"
        case lastPage = "last_page"
        case lastZoom = "last_zoom"
        case lastScrollY = "last_scroll_y"
        case displayMode = "display_mode"
        case lastScrollX = "last_scroll_x"
        case lastAutoScales = "last_auto_scales"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

extension PDFDisplayMode {
    var dbValue: Int {
        switch self {
        case .singlePage: return 0
        case .singlePageContinuous: return 1
        case .twoUp: return 2
        case .twoUpContinuous: return 3
        @unknown default: return 1
        }
    }

    static func from(dbValue: Int?) -> PDFDisplayMode {
        switch dbValue {
        case 0: return .singlePage
        case 1: return .singlePageContinuous
        case 2: return .twoUp
        case 3: return .twoUpContinuous
        default: return .singlePageContinuous
        }
    }
}
