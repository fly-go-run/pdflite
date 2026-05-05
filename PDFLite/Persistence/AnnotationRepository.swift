import Foundation
import GRDB

@MainActor
final class AnnotationRepository {
    static let shared = AnnotationRepository()

    private let db = Database.shared

    func list(forDocumentId documentId: Int64) throws -> [AnnotationRecord] {
        try db.writer.read { db in
            try AnnotationRecord
                .filter(Column("document_id") == documentId)
                .order(Column("page_index"), Column("created_at"))
                .fetchAll(db)
        }
    }

    func insert(_ record: AnnotationRecord) throws {
        try db.writer.write { db in
            try record.insert(db)
        }
    }

    func delete(id: String) throws {
        _ = try db.writer.write { db in
            try AnnotationRecord.filter(Column("id") == id).deleteAll(db)
        }
    }
}
