import Foundation
import GRDB
import os.log

/// Single shared GRDB DatabaseQueue. Owns schema migrations.
@MainActor
final class Database {
    static let shared = Database()

    private let logger = Logger(subsystem: "com.pdflite.app", category: "Database")
    let writer: DatabaseQueue

    private init() {
        let url = AppPaths.sqliteURL
        var config = Configuration()
        config.label = "pdflite.reader"

        let candidate: DatabaseQueue
        do {
            let queue = try DatabaseQueue(path: url.path, configuration: config)
            try Self.migrator.migrate(queue)
            candidate = queue
        } catch {
            // Per §8: a broken DB shouldn't block reading — but we still need *some* writer.
            // Fall back to an in-memory queue so the app can run; persistence operations will
            // surface their own errors back to the user where appropriate.
            Logger(subsystem: "com.pdflite.app", category: "Database")
                .error("Failed to open SQLite at \(url.path, privacy: .public): \(error.localizedDescription, privacy: .public). Falling back to in-memory.")
            // swiftlint:disable:next force_try
            let fallback = try! DatabaseQueue()
            try? Self.migrator.migrate(fallback)
            candidate = fallback
        }
        self.writer = candidate
    }

    private static var migrator: DatabaseMigrator {
        var m = DatabaseMigrator()
        #if DEBUG
        m.eraseDatabaseOnSchemaChange = false
        #endif

        m.registerMigration("v1_documents_and_annotations") { db in
            try db.create(table: "documents") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("file_hash", .text).notNull().unique()
                t.column("file_url", .text).notNull()
                t.column("title", .text)
                t.column("page_count", .integer).notNull().defaults(to: 0)
                t.column("last_opened_at", .datetime)
                t.column("last_page", .integer).notNull().defaults(to: 0)
                t.column("last_zoom", .double)
                t.column("last_scroll_y", .double)
                t.column("display_mode", .integer)
                t.column("created_at", .datetime).notNull()
                t.column("updated_at", .datetime).notNull()
            }

            try db.create(table: "annotations") { t in
                t.column("id", .text).primaryKey()
                t.column("document_id", .integer)
                    .notNull()
                    .references("documents", onDelete: .cascade)
                t.column("page_index", .integer).notNull()
                t.column("annotation_type", .text).notNull()
                t.column("bounds_json", .text).notNull()
                t.column("color", .text)
                t.column("selected_text", .text)
                t.column("note_content", .text)
                t.column("created_at", .datetime).notNull()
                t.column("updated_at", .datetime).notNull()
            }

            try db.create(index: "idx_annotations_document_page",
                          on: "annotations",
                          columns: ["document_id", "page_index"])
        }

        return m
    }
}
