import Foundation
import GRDB
import os.log

@MainActor
final class DocumentRepository {
    static let shared = DocumentRepository()

    private let logger = Logger(subsystem: "com.pdflite.app", category: "DocumentRepo")
    private let db = Database.shared

    /// Insert if absent, otherwise update file_url + title + page_count + last_opened_at.
    /// Returns the persisted record (with id).
    func upsert(fileHash: String, fileURL: URL, title: String?, pageCount: Int) throws -> DocumentRecord {
        let now = Date()
        return try db.writer.write { db in
            if var existing = try DocumentRecord
                .filter(Column("file_hash") == fileHash)
                .fetchOne(db)
            {
                existing.fileURL = fileURL.path
                existing.title = title
                existing.pageCount = pageCount
                existing.lastOpenedAt = now
                existing.updatedAt = now
                try existing.update(db)
                return existing
            }

            var fresh = DocumentRecord(
                id: nil,
                fileHash: fileHash,
                fileURL: fileURL.path,
                title: title,
                pageCount: pageCount,
                lastOpenedAt: now,
                lastPage: 0,
                lastZoom: nil,
                lastScrollY: nil,
                displayMode: nil,
                createdAt: now,
                updatedAt: now
            )
            try fresh.insert(db)
            return fresh
        }
    }

    func updateReadingState(documentId: Int64,
                            lastPage: Int,
                            lastZoom: Double?,
                            displayMode: Int) throws {
        try db.writer.write { db in
            try db.execute(
                sql: """
                UPDATE documents
                SET last_page = ?, last_zoom = ?, display_mode = ?, updated_at = ?
                WHERE id = ?
                """,
                arguments: [lastPage, lastZoom, displayMode, Date(), documentId]
            )
        }
    }

    func find(byHash hash: String) throws -> DocumentRecord? {
        try db.writer.read { db in
            try DocumentRecord.filter(Column("file_hash") == hash).fetchOne(db)
        }
    }
}
