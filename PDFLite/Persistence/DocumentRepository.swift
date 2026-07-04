import Foundation
import GRDB
import os.log

final class DocumentRepository: Sendable {
    static let shared = DocumentRepository()

    private let logger = Logger(subsystem: "com.pdflite.app", category: "DocumentRepo")
    private let db = Database.shared

    /// Insert if absent, otherwise update file_url + title + page_count + last_opened_at.
    /// Returns the persisted record (with id).
    func upsert(fileHash: String, fileURL: URL, title: String?, pageCount: Int) async throws -> DocumentRecord {
        let now = Date()
        let path = fileURL.path
        return try await db.writer.write { db in
            if var existing = try DocumentRecord
                .filter(Column("file_hash") == fileHash)
                .fetchOne(db)
            {
                existing.fileURL = path
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
                fileURL: path,
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
                            displayMode: Int) async throws {
        try await db.writer.write { db in
            try Self.executeReadingStateUpdate(
                db,
                documentId: documentId,
                lastPage: lastPage,
                lastZoom: lastZoom,
                displayMode: displayMode
            )
        }
    }

    /// Synchronous variant reserved for window-close / app-quit flushes, where the write must
    /// land before teardown continues. Everything else goes through the async API.
    func updateReadingStateNow(documentId: Int64,
                               lastPage: Int,
                               lastZoom: Double?,
                               displayMode: Int) throws {
        try db.writer.write { db in
            try Self.executeReadingStateUpdate(
                db,
                documentId: documentId,
                lastPage: lastPage,
                lastZoom: lastZoom,
                displayMode: displayMode
            )
        }
    }

    private static func executeReadingStateUpdate(_ db: GRDB.Database,
                                                  documentId: Int64,
                                                  lastPage: Int,
                                                  lastZoom: Double?,
                                                  displayMode: Int) throws {
        try db.execute(
            sql: """
            UPDATE documents
            SET last_page = ?, last_zoom = ?, display_mode = ?, updated_at = ?
            WHERE id = ?
            """,
            arguments: [lastPage, lastZoom, displayMode, Date(), documentId]
        )
    }

    func find(byHash hash: String) async throws -> DocumentRecord? {
        try await db.writer.read { db in
            try DocumentRecord.filter(Column("file_hash") == hash).fetchOne(db)
        }
    }

    /// Fast lookup by path, used to restore reading state immediately on open — before the
    /// (potentially slow) full-file hash confirms document identity.
    func find(byURL url: URL) async throws -> DocumentRecord? {
        let path = url.path
        return try await db.writer.read { db in
            try DocumentRecord
                .filter(Column("file_url") == path)
                .order(Column("updated_at").desc)
                .fetchOne(db)
        }
    }
}
