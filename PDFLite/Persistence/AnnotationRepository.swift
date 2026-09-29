import Foundation
import GRDB

final class AnnotationRepository: Sendable {
    static let shared = AnnotationRepository()

    private let db: Database

    init(database: Database = .shared) {
        db = database
    }

    func list(forDocumentId documentId: Int64) async throws -> [AnnotationRecord] {
        try await db.writer.read { db in
            try AnnotationRecord
                .filter(Column("document_id") == documentId)
                .order(Column("page_index"), Column("created_at"))
                .fetchAll(db)
        }
    }

    /// Insert one or more rows that share a `groupId`. Multi-page highlights call this with one
    /// record per page; single-page highlights call it with a one-element array.
    func insertAll(_ records: [AnnotationRecord]) async throws {
        try await db.writer.write { db in
            for record in records {
                try record.insert(db)
            }
        }
    }

    /// Delete every row with the given `groupId`. Matches the runtime behavior of
    /// `AnnotationService.removeRuntimeAnnotations(groupId:)` so the DB and PDFView stay in sync.
    func delete(groupId: String) async throws {
        _ = try await db.writer.write { db in
            try AnnotationRecord.filter(Column("group_id") == groupId).deleteAll(db)
        }
    }

    /// Set `translation_id` on every record in a group. Auto-translate-on-highlight calls this
    /// after the translation lands so any per-page row in the group can resolve its bound
    /// translation later.
    func updateTranslationId(groupId: String, translationId: Int64?) async throws {
        _ = try await db.writer.write { db in
            try AnnotationRecord
                .filter(Column("group_id") == groupId)
                .updateAll(
                    db,
                    Column("translation_id").set(to: translationId),
                    Column("updated_at").set(to: Date())
                )
        }
    }

    /// Concatenated `selected_text` for every row in a group, in document order. Used by the
    /// right-click "复制原文" menu.
    func concatenatedSelectedText(groupId: String) async throws -> String {
        try await db.writer.read { db in
            let rows = try AnnotationRecord
                .filter(Column("group_id") == groupId)
                .order(Column("page_index"), Column("created_at"))
                .fetchAll(db)
            return rows.compactMap { $0.selectedText }.joined(separator: "\n\n")
        }
    }
}
