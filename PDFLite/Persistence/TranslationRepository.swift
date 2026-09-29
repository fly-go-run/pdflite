import Foundation
import GRDB

final class TranslationRepository: Sendable {
    static let shared = TranslationRepository()

    private let db: Database

    init(database: Database = .shared) {
        db = database
    }

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

    /// Commit the result of a re-run that deliberately skipped the cache (the "重试" path).
    /// Rows for the same (document, page, text_hash) are updated in place instead of adding a
    /// second copy: the row id stays, so a highlight bound through `annotations.translation_id`
    /// follows the corrected text, and `findCache(byHash:)` (newest first) serves it because
    /// `created_at` is refreshed. With no matching row this is a plain insert.
    func replaceOrInsert(_ record: TranslationRecord) async throws -> TranslationRecord {
        try await db.writer.write { db in
            let matching = TranslationRecord
                .filter(Column("text_hash") == record.textHash)
                .filter(Column("document_id") == record.documentId)
                .filter(Column("page_index") == record.pageIndex)

            if try matching.fetchCount(db) == 0 {
                var fresh = record
                try fresh.insert(db)
                return fresh
            }

            try matching.updateAll(
                db,
                Column("source_text").set(to: record.sourceText),
                Column("target_text").set(to: record.targetText),
                Column("provider").set(to: record.provider),
                Column("model").set(to: record.model),
                Column("created_at").set(to: record.createdAt)
            )
            // Pre-existing duplicates (if any) were all refreshed; report the newest id.
            return try matching
                .order(Column("id").desc)
                .fetchOne(db) ?? record
        }
    }
}
