import Foundation
import GRDB
import XCTest

/// Base class for persistence tests: one throw-away directory per test under the system temp
/// directory. Nothing here ever opens `~/Library/Application Support/PDFLite`.
class PersistenceTestCase: XCTestCase {
    var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdflite-persistence-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        // A test may have made a directory read-only; make everything removable again first.
        if let enumerator = FileManager.default.enumerator(atPath: directory.path) {
            for case let relative as String in enumerator {
                try? FileManager.default.setAttributes([.posixPermissions: 0o700],
                                                       ofItemAtPath: directory.appendingPathComponent(relative).path)
            }
        }
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        try FileManager.default.removeItem(at: directory)
    }

    func databaseURL(_ name: String = UUID().uuidString) -> URL {
        directory.appendingPathComponent(name + ".sqlite", isDirectory: false)
    }
}

// MARK: - Historical databases

/// Builds SQLite files exactly as an install that last ran an older PDFLite would have left them:
/// the *real* migrations are applied one at a time with `DatabaseMigrator.migrate(_:upTo:)`
/// (GRDB `Migration/DatabaseMigrator.swift`), and after each step the rows a user of that version
/// could have written are inserted with raw SQL that only mentions columns which exist at that
/// version. The tests then hand the file to `Database(url:)` — the production entry point — to
/// finish the upgrade.
enum LegacyDatabase {
    struct Stage: Sendable {
        let identifier: String
        let seed: @Sendable (GRDB.Database) throws -> Void
    }

    static let currentIdentifier = "v7_reading_location"

    /// One entry per registered migration, in registration order. `identifier` is the migration
    /// that has just been applied when `seed` runs.
    static let stages: [Stage] = [
        Stage(identifier: "v1_documents_and_annotations") { db in
            try db.execute(sql: """
                INSERT INTO documents (id, file_hash, file_url, title, page_count, last_opened_at,
                                       last_page, last_zoom, last_scroll_y, display_mode, created_at, updated_at)
                VALUES
                 (1, 'hash-alpha', '/Users/test/Papers/Attention Is All You Need.pdf', 'Attention', 15,
                  '2026-03-01 10:00:00.000', 12, 1.5, 300.5, 3, '2026-01-01 08:00:00.000', '2026-03-01 10:00:00.000'),
                 (2, 'hash-beta', '/Users/test/论文/beta.pdf', NULL, 0,
                  NULL, 0, NULL, NULL, NULL, '2026-02-01 08:00:00.000', '2026-02-01 08:00:00.000'),
                 (3, 'hash-gamma', '/tmp/gamma.pdf', 'Gamma', 30,
                  '2026-03-02 09:00:00.000', 7, 0.75, NULL, 1, '2026-02-15 08:00:00.000', '2026-03-02 09:00:00.000')
                """)
            try db.execute(sql: """
                INSERT INTO annotations (id, document_id, page_index, annotation_type, bounds_json, color,
                                         selected_text, note_content, created_at, updated_at)
                VALUES
                 ('ann-a1', 1, 0, 'highlight',
                  '[{"x":72.5,"y":700.25,"w":300.125,"h":12.5},{"x":72.5,"y":686.0,"w":280.75,"h":12.5},{"x":72.5,"y":671.5,"w":90.0,"h":12.5}]',
                  '#FFEB3B80', 'first line second line third line', NULL,
                  '2026-03-01 10:01:00.000', '2026-03-01 10:01:00.000'),
                 ('ann-a2', 1, 3, 'highlight', '[{"x":10.0,"y":20.0,"w":30.0,"h":40.0}]',
                  '#FFEB3B80', 'single', NULL, '2026-03-01 10:02:00.000', '2026-03-01 10:02:00.000'),
                 ('ann-b1', 2, 1, 'highlight', '[{"x":1.5,"y":2.5,"w":3.5,"h":4.5}]',
                  NULL, NULL, 'my note', '2026-02-02 08:00:00.000', '2026-02-02 08:30:00.000')
                """)
        },
        Stage(identifier: "v2_translations") { db in
            // Same hash in two documents, a cross-document (NULL document) cache row, and an exact
            // duplicate of row 1 — v2 has no uniqueness beyond the primary key.
            try db.execute(sql: """
                INSERT INTO translations (id, document_id, page_index, text_hash, source_text, target_text,
                                          provider, model, created_at)
                VALUES
                 (1, 1, 0, 'h-shared', 'Attention is all you need.', '注意力就是你所需要的一切。', 'deepseek', 'deepseek-chat', '2026-03-01 10:05:00.000'),
                 (2, 2, 1, 'h-shared', 'Attention is all you need.', '注意力就是全部。', 'deepseek', 'deepseek-chat', '2026-03-02 10:05:00.000'),
                 (3, NULL, NULL, 'h-global', 'Global source', '全局译文', 'deepseek', 'deepseek-chat', '2026-03-03 10:05:00.000'),
                 (4, 1, 0, 'h-shared', 'Attention is all you need.', '重复的历史行', 'deepseek', 'deepseek-chat', '2026-03-04 10:05:00.000')
                """)
        },
        Stage(identifier: "v3_translation_history_per_document") { db in
            try db.execute(sql: """
                INSERT INTO translations (id, document_id, page_index, text_hash, source_text, target_text,
                                          provider, model, created_at)
                VALUES (5, 3, 2, 'h-gamma', 'Gamma source', 'Gamma 译文', 'deepseek', 'deepseek-chat', '2026-03-05 10:05:00.000')
                """)
        },
        Stage(identifier: "v4_annotation_translation_binding") { db in
            try db.execute(sql: """
                INSERT INTO annotations (id, document_id, page_index, annotation_type, bounds_json, color,
                                         selected_text, note_content, translation_id, created_at, updated_at)
                VALUES
                 ('ann-a3', 1, 5, 'highlight', '[{"x":5.25,"y":6.25,"w":7.25,"h":8.25}]', '#A5D6A780',
                  'bound text', NULL, 1, '2026-03-06 10:00:00.000', '2026-03-06 10:00:00.000')
                """)
        },
        Stage(identifier: "v5_annotation_group_id") { db in
            // A two-page highlight (one row per page sharing group_id) plus a self-grouped row.
            try db.execute(sql: """
                INSERT INTO annotations (id, group_id, document_id, page_index, annotation_type, bounds_json, color,
                                         selected_text, note_content, translation_id, created_at, updated_at)
                VALUES
                 ('ann-g1', 'grp-multi', 3, 1, 'highlight', '[{"x":50.0,"y":40.0,"w":100.0,"h":10.0}]', '#FFEB3B80',
                  'page one part', NULL, 5, '2026-03-07 10:00:00.000', '2026-03-07 10:00:00.000'),
                 ('ann-g2', 'grp-multi', 3, 2, 'highlight', '[{"x":50.0,"y":700.0,"w":100.0,"h":10.0}]', '#FFEB3B80',
                  'page two part', NULL, 5, '2026-03-07 10:00:01.000', '2026-03-07 10:00:01.000')
                """)
        },
        Stage(identifier: "v6_documents_file_url_index") { db in
            // Same path, different content: the file was replaced, so it is a new document (§4.3 rule 2).
            try db.execute(sql: """
                INSERT INTO documents (id, file_hash, file_url, title, page_count, last_opened_at,
                                       last_page, last_zoom, last_scroll_y, display_mode, created_at, updated_at)
                VALUES (4, 'hash-gamma-v2', '/tmp/gamma.pdf', 'Gamma v2', 31,
                        '2026-03-08 09:00:00.000', 1, NULL, 12.75, 0, '2026-03-08 09:00:00.000', '2026-03-08 09:00:00.000')
                """)
        },
        Stage(identifier: "v7_reading_location") { db in
            try db.execute(sql: """
                INSERT INTO documents (id, file_hash, file_url, title, page_count, last_opened_at,
                                       last_page, last_zoom, last_scroll_x, last_scroll_y, last_auto_scales,
                                       display_mode, created_at, updated_at)
                VALUES (5, 'hash-delta', '/Users/test/delta.pdf', 'Delta', 9,
                        '2026-03-09 09:00:00.000', 4, 1.25, 33.5, 480.25, 0, 3,
                        '2026-03-09 09:00:00.000', '2026-03-09 09:00:00.000')
                """)
        },
    ]

    /// Creates the file at `url` at the schema of `identifier`, with every stage's rows up to and
    /// including that version, and closes it (WAL checkpointed) so it looks like an app that quit.
    static func build(at url: URL, upTo identifier: String) throws {
        let migrator = Database.migrator
        precondition(stages.map(\.identifier) == migrator.migrations,
                     "LegacyDatabase.stages must mirror Database.migrator one to one")
        let pool = try DatabasePool(path: url.path)
        for stage in stages {
            try migrator.migrate(pool, upTo: stage.identifier)
            try pool.write { db in try stage.seed(db) }
            if stage.identifier == identifier { break }
        }
        try pool.close()
    }
}

// MARK: - Inspection helpers

enum DatabaseInspector {
    typealias Rows = [[String: DatabaseValue]]

    /// Every row of every user table, keyed by table, ordered by rowid.
    static func snapshot(_ db: GRDB.Database) throws -> [String: Rows] {
        var result: [String: Rows] = [:]
        for table in ["documents", "annotations", "translations"] where try db.tableExists(table) {
            let rows = try Row.fetchAll(db, sql: "SELECT * FROM \(table) ORDER BY rowid")
            result[table] = rows.map { row in
                var values: [String: DatabaseValue] = [:]
                for name in row.columnNames {
                    let value: DatabaseValue = row[name]
                    values[name] = value
                }
                return values
            }
        }
        return result
    }

    /// Column / index / foreign-key description of every user table, stable across SQLite's
    /// `ALTER TABLE` rewriting of the stored `CREATE` text (so it compares structure, not spelling).
    static func schema(_ db: GRDB.Database) throws -> [String: [String]] {
        var result: [String: [String]] = [:]
        let tables = try String.fetchAll(db, sql: """
            SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%' ORDER BY name
            """)
        for table in tables {
            var lines: [String] = []
            for column in try Row.fetchAll(db, sql: "PRAGMA table_info(\(table))") {
                let name: String = column["name"]
                let type: String = column["type"]
                let notNull: Int = column["notnull"]
                let defaultValue: String? = column["dflt_value"]
                let pk: Int = column["pk"]
                lines.append("column \(name) \(type) notnull=\(notNull) default=\(defaultValue ?? "nil") pk=\(pk)")
            }
            for index in try Row.fetchAll(db, sql: "PRAGMA index_list(\(table))") {
                let name: String = index["name"]
                let unique: Int = index["unique"]
                let origin: String = index["origin"]
                let columns = try Row.fetchAll(db, sql: "PRAGMA index_info(\(name))")
                    .map { (row: Row) -> String in row["name"] }
                lines.append("index \(name) unique=\(unique) origin=\(origin) columns=\(columns.joined(separator: ","))")
            }
            for fk in try Row.fetchAll(db, sql: "PRAGMA foreign_key_list(\(table))") {
                let target: String = fk["table"]
                let from: String = fk["from"]
                let to: String = fk["to"]
                let onDelete: String = fk["on_delete"]
                lines.append("foreignKey \(from) -> \(target).\(to) onDelete=\(onDelete)")
            }
            result[table] = lines.sorted()
        }
        return result
    }

    static func integrityCheck(_ db: GRDB.Database) throws -> [String] {
        try String.fetchAll(db, sql: "PRAGMA integrity_check")
    }

    static func foreignKeyViolations(_ db: GRDB.Database) throws -> [Row] {
        try Row.fetchAll(db, sql: "PRAGMA foreign_key_check")
    }
}
