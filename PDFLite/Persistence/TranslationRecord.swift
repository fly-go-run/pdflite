import Foundation
import GRDB

struct TranslationRecord: Codable, FetchableRecord, MutablePersistableRecord, Equatable {
    static let databaseTableName = "translations"

    var id: Int64?
    var documentId: Int64?
    var pageIndex: Int?
    var textHash: String
    var sourceText: String
    var targetText: String
    var provider: String
    var model: String
    var createdAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case documentId = "document_id"
        case pageIndex = "page_index"
        case textHash = "text_hash"
        case sourceText = "source_text"
        case targetText = "target_text"
        case provider
        case model
        case createdAt = "created_at"
    }

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}
