import Foundation
import GRDB
import os.log

/// Single shared GRDB writer. Owns schema migrations.
/// Not main-actor-bound: GRDB serializes writes internally, and repositories call it through
/// the async API so SQLite I/O never blocks the main thread. The on-disk store is a
/// DatabasePool (WAL mode): reads run concurrently with each other *and* with writes, so a
/// debounced reading-state write can't stall an annotation/translation lookup.
final class Database: Sendable {
    static let shared = Database()

    private let logger = Logger(subsystem: "com.pdflite.app", category: "Database")
    let writer: any DatabaseWriter

    private init() {
        let url = AppPaths.sqliteURL
        var config = Configuration()
        config.label = "pdflite.reader"

        let candidate: any DatabaseWriter
        do {
            let pool = try DatabasePool(path: url.path, configuration: config)
            try Self.migrator.migrate(pool)
            candidate = pool
        } catch {
            // Per §8: a broken DB shouldn't block reading — but we still need *some* writer.
            // Fall back to an in-memory queue so the app can run (DatabasePool requires a file);
            // persistence operations will surface their own errors back to the user.
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

        m.registerMigration("v2_translations") { db in
            try db.create(table: "translations") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("document_id", .integer)
                    .references("documents", onDelete: .cascade)
                t.column("page_index", .integer)
                t.column("text_hash", .text).notNull()
                t.column("source_text", .text).notNull()
                t.column("target_text", .text).notNull()
                t.column("provider", .text).notNull()
                t.column("model", .text).notNull()
                t.column("created_at", .datetime).notNull()
            }

            try db.create(index: "idx_translations_hash",
                          on: "translations",
                          columns: ["text_hash"])
            try db.create(index: "idx_translations_document",
                          on: "translations",
                          columns: ["document_id", "created_at"])
        }

        m.registerMigration("v3_translation_history_per_document") { db in
            try db.create(table: "translations_v3") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("document_id", .integer)
                    .references("documents", onDelete: .cascade)
                t.column("page_index", .integer)
                t.column("text_hash", .text).notNull()
                t.column("source_text", .text).notNull()
                t.column("target_text", .text).notNull()
                t.column("provider", .text).notNull()
                t.column("model", .text).notNull()
                t.column("created_at", .datetime).notNull()
            }

            try db.execute(sql: """
                INSERT INTO translations_v3
                    (id, document_id, page_index, text_hash, source_text, target_text, provider, model, created_at)
                SELECT id, document_id, page_index, text_hash, source_text, target_text, provider, model, created_at
                FROM translations
                """)
            try db.drop(table: "translations")
            try db.rename(table: "translations_v3", to: "translations")
            try db.create(index: "idx_translations_hash",
                          on: "translations",
                          columns: ["text_hash"])
            try db.create(index: "idx_translations_document",
                          on: "translations",
                          columns: ["document_id", "created_at"])
        }

        m.registerMigration("v4_annotation_translation_binding") { db in
            // Auto-translate-on-highlight: each highlight may carry a pointer to the translation
            // it was created with. ON DELETE SET NULL so deleting a translation row doesn't
            // cascade-delete the highlight.
            try db.alter(table: "annotations") { t in
                t.add(column: "translation_id", .integer)
                    .references("translations", onDelete: .setNull)
            }
        }

        m.registerMigration("v5_annotation_group_id") { db in
            // Multi-page highlights store one row per page sharing a group_id, so deleting /
            // listing / context-menu actions can operate on the whole highlight without joining.
            // Existing single-page rows back-fill group_id = id so they remain self-grouped.
            try db.alter(table: "annotations") { t in
                t.add(column: "group_id", .text).notNull().defaults(to: "")
            }
            try db.execute(sql: "UPDATE annotations SET group_id = id WHERE group_id = ''")
            try db.create(index: "idx_annotations_group_id",
                          on: "annotations",
                          columns: ["group_id"])
        }

        m.registerMigration("v6_documents_file_url_index") { db in
            // find(byURL:) runs on every document open (fast-path reading-state restore) and
            // filters by file_url + orders by updated_at — give it an index instead of a
            // full-table scan.
            try db.create(index: "idx_documents_file_url",
                          on: "documents",
                          columns: ["file_url", "updated_at"])
        }

        return m
    }
}
