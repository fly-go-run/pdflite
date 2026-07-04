import Foundation
import GRDB

final class TranslationRepository: Sendable {
    static let shared = TranslationRepository()

    private let db = Database.shared

    func findCache(byHash hash: String) async throws -> TranslationRecord? {
        try await db.writer.read { db in
            try TranslationRecord
                .filter(Column("text_hash") == hash)
                .order(Column("created_at").desc)
                .fetchOne(db)
        }
    }

    func findInDocument(textHash: String, documentId: Int64, pageIndex: Int?) async throws -> TranslationRecord? {
        try await db.writer.read { db in
            var request = TranslationRecord
                .filter(Column("text_hash") == textHash)
                .filter(Column("document_id") == documentId)

            if let pageIndex {
                request = request.filter(Column("page_index") == pageIndex)
            } else {
                request = request.filter(Column("page_index") == nil)
            }

            return try request
                .order(Column("created_at").desc)
                .fetchOne(db)
        }
    }

    func insert(_ record: TranslationRecord) async throws -> TranslationRecord {
        try await db.writer.write { db in
            var fresh = record
            try fresh.insert(db)
            return fresh
        }
    }
}
