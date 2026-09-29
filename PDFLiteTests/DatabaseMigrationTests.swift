import GRDB
import XCTest

/// The full v1 → v7 migration chain (design §4.3 rule 7: migrations are versioned, never ad-hoc
/// SQL over old databases). Every test builds its own file in the temp directory with
/// `LegacyDatabase` and finishes the upgrade through the production `Database(url:)`.
final class DatabaseMigrationTests: PersistenceTestCase {
    private typealias Rows = DatabaseInspector.Rows

    private func read<T>(_ database: Database, _ body: (GRDB.Database) throws -> T) throws -> T {
        try database.writer.read(body)
    }

    private func write<T>(_ database: Database, _ body: (GRDB.Database) throws -> T) throws -> T {
        try database.writer.write(body)
    }

    /// Builds a legacy file and returns it together with the rows it held before any upgrade.
    private func legacyDatabase(upTo identifier: String) throws -> (url: URL, before: [String: Rows]) {
        let url = databaseURL()
        try LegacyDatabase.build(at: url, upTo: identifier)
        let pool = try DatabasePool(path: url.path)
        let before = try pool.read { try DatabaseInspector.snapshot($0) }
        try pool.close()
        return (url, before)
    }

    private let goldenSchema: [String: [String]] = [
        "annotations": [
            "column annotation_type TEXT notnull=1 default=nil pk=0",
            "column bounds_json TEXT notnull=1 default=nil pk=0",
            "column color TEXT notnull=0 default=nil pk=0",
            "column created_at DATETIME notnull=1 default=nil pk=0",
            "column document_id INTEGER notnull=1 default=nil pk=0",
            "column group_id TEXT notnull=1 default='' pk=0",
            "column id TEXT notnull=0 default=nil pk=1",
            "column note_content TEXT notnull=0 default=nil pk=0",
            "column page_index INTEGER notnull=1 default=nil pk=0",
            "column selected_text TEXT notnull=0 default=nil pk=0",
            "column translation_id INTEGER notnull=0 default=nil pk=0",
            "column updated_at DATETIME notnull=1 default=nil pk=0",
            "foreignKey document_id -> documents.id onDelete=CASCADE",
            "foreignKey translation_id -> translations.id onDelete=SET NULL",
            "index idx_annotations_document_page unique=0 origin=c columns=document_id,page_index",
            "index idx_annotations_group_id unique=0 origin=c columns=group_id",
            "index sqlite_autoindex_annotations_1 unique=1 origin=pk columns=id",
        ],
        "documents": [
            "column created_at DATETIME notnull=1 default=nil pk=0",
            "column display_mode INTEGER notnull=0 default=nil pk=0",
            "column file_hash TEXT notnull=1 default=nil pk=0",
            "column file_url TEXT notnull=1 default=nil pk=0",
            "column id INTEGER notnull=0 default=nil pk=1",
            "column last_auto_scales BOOLEAN notnull=0 default=nil pk=0",
            "column last_opened_at DATETIME notnull=0 default=nil pk=0",
            "column last_page INTEGER notnull=1 default=0 pk=0",
            "column last_scroll_x DOUBLE notnull=0 default=nil pk=0",
            "column last_scroll_y DOUBLE notnull=0 default=nil pk=0",
            "column last_zoom DOUBLE notnull=0 default=nil pk=0",
            "column page_count INTEGER notnull=1 default=0 pk=0",
            "column title TEXT notnull=0 default=nil pk=0",
            "column updated_at DATETIME notnull=1 default=nil pk=0",
            "index idx_documents_file_url unique=0 origin=c columns=file_url,updated_at",
            "index sqlite_autoindex_documents_1 unique=1 origin=u columns=file_hash",
        ],
        "grdb_migrations": [
            "column identifier TEXT notnull=1 default=nil pk=1",
            "index sqlite_autoindex_grdb_migrations_1 unique=1 origin=pk columns=identifier",
        ],
        "translations": [
            "column created_at DATETIME notnull=1 default=nil pk=0",
            "column document_id INTEGER notnull=0 default=nil pk=0",
            "column id INTEGER notnull=0 default=nil pk=1",
            "column model TEXT notnull=1 default=nil pk=0",
            "column page_index INTEGER notnull=0 default=nil pk=0",
            "column provider TEXT notnull=1 default=nil pk=0",
            "column source_text TEXT notnull=1 default=nil pk=0",
            "column target_text TEXT notnull=1 default=nil pk=0",
            "column text_hash TEXT notnull=1 default=nil pk=0",
            "foreignKey document_id -> documents.id onDelete=CASCADE",
            "index idx_translations_document unique=0 origin=c columns=document_id,created_at",
            "index idx_translations_hash unique=0 origin=c columns=text_hash",
        ],
    ]

    // MARK: - Registry and schema

    func testMigrationIdentifiersAreFrozen() {
        // Renaming or reordering an identifier would make GRDB re-run the migration on every
        // existing install (or skip it), so the list is pinned on purpose.
        XCTAssertEqual(Database.migrator.migrations, [
            "v1_documents_and_annotations",
            "v2_translations",
            "v3_translation_history_per_document",
            "v4_annotation_translation_binding",
            "v5_annotation_group_id",
            "v6_documents_file_url_index",
            "v7_reading_location",
        ])
        XCTAssertEqual(LegacyDatabase.stages.map(\.identifier), Database.migrator.migrations)
    }

    func testFreshDatabaseHasTheDocumentedSchema() throws {
        let database = Database(url: databaseURL())
        XCTAssertTrue(database.isPersistent)
        XCTAssertEqual(try read(database) { try DatabaseInspector.schema($0) }, goldenSchema)
        let applied = try read(database) { try Database.migrator.appliedMigrations($0) }
        XCTAssertEqual(applied, Database.migrator.migrations)
    }

    // MARK: - Every historical starting point

    func testUpgradeFromEveryHistoricalVersionKeepsAllRowsAndEndsAtTheSameSchema() throws {
        for stage in LegacyDatabase.stages {
            let (url, before) = try legacyDatabase(upTo: stage.identifier)
            XCTAssertFalse(before.isEmpty, stage.identifier)

            let database = Database(url: url)
            XCTAssertTrue(database.isPersistent, "upgrade from \(stage.identifier) fell back to memory")

            let after = try read(database) { try DatabaseInspector.snapshot($0) }
            assertUpgradePreservesRows(before: before, after: after, from: stage.identifier)

            XCTAssertEqual(try read(database) { try DatabaseInspector.schema($0) }, goldenSchema,
                           "schema after upgrading from \(stage.identifier)")
            XCTAssertEqual(try read(database) { try Database.migrator.appliedMigrations($0) },
                           Database.migrator.migrations, stage.identifier)
            XCTAssertEqual(try read(database) { try DatabaseInspector.integrityCheck($0) }, ["ok"], stage.identifier)
            XCTAssertTrue(try read(database) { try DatabaseInspector.foreignKeyViolations($0) }.isEmpty, stage.identifier)
        }
    }

    /// Every value that existed before the upgrade is unchanged; columns that did not exist get
    /// exactly what their migration promises.
    private func assertUpgradePreservesRows(before: [String: Rows], after: [String: Rows], from: String,
                                            file: StaticString = #filePath, line: UInt = #line) {
        for (table, oldRows) in before {
            let newRows = after[table] ?? []
            XCTAssertEqual(newRows.count, oldRows.count, "\(table) row count after \(from)", file: file, line: line)
            for (old, new) in zip(oldRows, newRows) {
                for (column, value) in old {
                    XCTAssertEqual(new[column], value, "\(table).\(column) changed by upgrade from \(from)",
                                   file: file, line: line)
                }
            }
        }
        for (old, new) in zip(before["annotations"] ?? [], after["annotations"] ?? []) {
            if old["translation_id"] == nil {
                XCTAssertEqual(new["translation_id"], DatabaseValue.null, "legacy annotation has no bound translation",
                               file: file, line: line)
            }
            if old["group_id"] == nil {
                XCTAssertEqual(new["group_id"], old["id"], "legacy annotation is its own group",
                               file: file, line: line)
            }
        }
        for new in after["documents"] ?? [] where before["documents"]?.first?["last_scroll_x"] == nil {
            XCTAssertEqual(new["last_scroll_x"], DatabaseValue.null, file: file, line: line)
            XCTAssertEqual(new["last_auto_scales"], DatabaseValue.null, file: file, line: line)
        }
    }

    // MARK: - v3: translations rebuilt for per-document history

    func testV3RebuildKeepsEveryTranslationRowIdAndConstraint() async throws {
        let (url, before) = try legacyDatabase(upTo: "v2_translations")
        XCTAssertEqual(before["translations"]?.count, 4)

        let database = Database(url: url)
        XCTAssertTrue(database.isPersistent)
        let rows = try await database.writer.read { db in
            try TranslationRecord.order(Column("id")).fetchAll(db)
        }
        XCTAssertEqual(rows.map(\.id), [1, 2, 3, 4], "no row lost, ids preserved")
        XCTAssertEqual(rows.map(\.documentId), [1, 2, nil, 1])
        XCTAssertEqual(rows.map(\.pageIndex), [0, 1, nil, 0])
        XCTAssertEqual(rows.map(\.textHash), ["h-shared", "h-shared", "h-global", "h-shared"])
        XCTAssertEqual(rows.map(\.targetText), ["注意力就是你所需要的一切。", "注意力就是全部。", "全局译文", "重复的历史行"])

        // Per-document history: the same hash lives in several documents and can repeat inside
        // one, so the table must not have grown a uniqueness constraint on the hash.
        let repository = TranslationRepository(database: database)
        let inDocument1 = try await repository.findInDocument(textHash: "h-shared", documentId: 1, pageIndex: 0)
        XCTAssertEqual(inDocument1?.id, 4, "newest row of the (document, page, hash) history wins")
        let inDocument2 = try await repository.findInDocument(textHash: "h-shared", documentId: 2, pageIndex: 1)
        XCTAssertEqual(inDocument2?.id, 2)
        let cache = try await repository.findCache(byHash: "h-shared")
        XCTAssertEqual(cache?.id, 4, "newest across documents")
        let global = try await repository.findCache(byHash: "h-global")
        XCTAssertNil(global?.documentId)

        let schema = try read(database) { try DatabaseInspector.schema($0) }
        XCTAssertEqual(schema["translations"]?.filter { $0.hasPrefix("index") }, [
            "index idx_translations_document unique=0 origin=c columns=document_id,created_at",
            "index idx_translations_hash unique=0 origin=c columns=text_hash",
        ])
        XCTAssertNil(schema["translations_v3"], "temporary rebuild table must be gone")

        // The rebuilt table must still cascade with its document and keep handing out fresh ids.
        let next = try await repository.insert(TranslationRecord(
            id: nil, documentId: 2, pageIndex: 1, textHash: "h-new", sourceText: "s", targetText: "t",
            provider: "deepseek", model: "m", createdAt: Date()
        ))
        XCTAssertGreaterThan(try XCTUnwrap(next.id), 4)

        try await database.writer.write { db in
            try db.execute(sql: "DELETE FROM documents WHERE id = 1")
        }
        let remaining = try await database.writer.read { db in
            try Int64.fetchAll(db, sql: "SELECT id FROM translations ORDER BY id")
        }
        XCTAssertEqual(remaining, [2, 3, try XCTUnwrap(next.id)], "translations 1 and 4 belonged to document 1")
    }

    // MARK: - v4: annotation → translation binding

    func testV4BindingColumnStartsEmptyAndDeletingATranslationOnlyClearsTheLink() async throws {
        let (url, before) = try legacyDatabase(upTo: "v3_translation_history_per_document")
        XCTAssertNil(before["annotations"]?.first?["translation_id"], "column does not exist yet")

        let database = Database(url: url)
        let annotations = AnnotationRepository(database: database)
        let legacy = try await annotations.list(forDocumentId: 1)
        XCTAssertEqual(legacy.map(\.id), ["ann-a1", "ann-a2"])
        XCTAssertEqual(legacy.map(\.translationId), [nil, nil])

        // Bind the highlight, then delete the translation: the highlight survives (SET NULL).
        try await annotations.updateTranslationId(groupId: "ann-a1", translationId: 1)
        let bound = try await annotations.list(forDocumentId: 1)
        XCTAssertEqual(bound.first?.translationId, 1)

        try await database.writer.write { db in
            try db.execute(sql: "DELETE FROM translations WHERE id = 1")
        }
        let afterDelete = try await annotations.list(forDocumentId: 1)
        XCTAssertEqual(afterDelete.map(\.id), ["ann-a1", "ann-a2"], "deleting a translation must not delete highlights")
        XCTAssertNil(afterDelete.first?.translationId)

        // A binding to a translation that does not exist is rejected.
        do {
            try await annotations.updateTranslationId(groupId: "ann-a2", translationId: 9_999)
            XCTFail("dangling translation_id should violate the foreign key")
        } catch let error as DatabaseError {
            XCTAssertEqual(error.resultCode, .SQLITE_CONSTRAINT)
        }
    }

    // MARK: - v5: group_id back-fill

    func testV5BackfillGivesEveryLegacyHighlightItsOwnGroupAndKeepsMultiLineBounds() async throws {
        let (url, before) = try legacyDatabase(upTo: "v4_annotation_translation_binding")
        XCTAssertEqual(before["annotations"]?.count, 4)

        let database = Database(url: url)
        let repository = AnnotationRepository(database: database)
        let rows = try await database.writer.read { db in
            try AnnotationRecord.order(Column("id")).fetchAll(db)
        }
        XCTAssertEqual(rows.map(\.id), ["ann-a1", "ann-a2", "ann-a3", "ann-b1"])
        // The promise: every pre-existing single-page row becomes its own one-row group. Nothing
        // is merged (distinct groups) and nothing is left in the '' default.
        XCTAssertEqual(rows.map(\.groupId), rows.map(\.id))
        let (empty, distinct, total) = try await database.writer.read { db in
            (try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM annotations WHERE group_id = ''") ?? -1,
             try Int.fetchOne(db, sql: "SELECT COUNT(DISTINCT group_id) FROM annotations") ?? -1,
             try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM annotations") ?? -1)
        }
        XCTAssertEqual(empty, 0)
        XCTAssertEqual(distinct, total)

        // A legacy multi-line highlight is still ONE row holding all its line rects, byte for byte.
        let multiLine = try XCTUnwrap(rows.first { $0.id == "ann-a1" })
        let legacyBounds = before["annotations"]?.first?["bounds_json"].flatMap { String.fromDatabaseValue($0) }
        XCTAssertEqual(multiLine.boundsJSON, legacyBounds)
        let rects = try AnnotationRectCoder.decode(multiLine.boundsJSON)
        XCTAssertEqual(rects, [CGRect(x: 72.5, y: 700.25, width: 300.125, height: 12.5),
                               CGRect(x: 72.5, y: 686.0, width: 280.75, height: 12.5),
                               CGRect(x: 72.5, y: 671.5, width: 90.0, height: 12.5)])
        XCTAssertEqual(multiLine.selectedText, "first line second line third line")
        XCTAssertEqual(rows.first { $0.id == "ann-a3" }?.translationId, 1, "v4 binding survives the v5 ALTER")

        // The group-level API works on legacy rows...
        let joined = try await repository.concatenatedSelectedText(groupId: "ann-a1")
        XCTAssertEqual(joined, "first line second line third line")
        let index = try await database.writer.read { db in
            try Row.fetchAll(db, sql: "EXPLAIN QUERY PLAN SELECT * FROM annotations WHERE group_id = ?",
                             arguments: ["ann-a1"]).map { (row: Row) -> String in row["detail"] }
        }
        XCTAssertTrue(index.contains { $0.contains("idx_annotations_group_id") }, "\(index)")

        // ...and deleting one legacy group removes exactly that row.
        try await repository.delete(groupId: "ann-a1")
        let left = try await repository.list(forDocumentId: 1)
        XCTAssertEqual(left.map(\.id), ["ann-a2", "ann-a3"])
    }

    // MARK: - v6: file_url index

    func testV6IndexServesFindByURLWithoutASort() async throws {
        let (url, _) = try legacyDatabase(upTo: "v5_annotation_group_id")
        let database = Database(url: url)
        let schema = try read(database) { try DatabaseInspector.schema($0) }
        XCTAssertTrue(schema["documents"]?.contains(
            "index idx_documents_file_url unique=0 origin=c columns=file_url,updated_at") == true)

        let plan = try await database.writer.read { db in
            try Row.fetchAll(db, sql: """
                EXPLAIN QUERY PLAN
                SELECT * FROM "documents" WHERE "file_url" = ? ORDER BY "updated_at" DESC LIMIT 1
                """, arguments: ["/tmp/gamma.pdf"]).map { (row: Row) -> String in row["detail"] }
        }
        XCTAssertTrue(plan.contains { $0.contains("idx_documents_file_url") }, "\(plan)")
        XCTAssertFalse(plan.contains { $0.contains("TEMP B-TREE") }, "index order should satisfy ORDER BY: \(plan)")

        let found = try await DocumentRepository(database: database)
            .find(byURL: URL(fileURLWithPath: "/tmp/gamma.pdf"))
        XCTAssertEqual(found?.id, 3)
    }

    // MARK: - v7: reading location columns

    func testV7LegacyRowsKeepTheirReadingIntentAndNewColumnsAreNullable() async throws {
        let (url, before) = try legacyDatabase(upTo: "v6_documents_file_url_index")
        XCTAssertEqual(before["documents"]?.count, 4)
        XCTAssertNil(before["documents"]?.first?["last_scroll_x"], "column does not exist yet")

        let database = Database(url: url)
        let repository = DocumentRepository(database: database)
        func location(_ hash: String) async throws -> (DocumentRecord, ReadingLocation) {
            let found = try await repository.find(byHash: hash)
            let record = try XCTUnwrap(found, hash)
            return (record, ReadingLocation(record: record))
        }

        // A 1.5 zoom recorded without an auto-scale flag → it was a manual zoom, not fit-to-width.
        let (alpha, alphaLocation) = try await location("hash-alpha")
        XCTAssertNil(alpha.lastScrollX)
        XCTAssertNil(alpha.lastAutoScales)
        XCTAssertEqual(alpha.lastScrollY, 300.5, "old scroll_y is kept even though x is unknown")
        XCTAssertEqual(alphaLocation, ReadingLocation(pageIndex: 12, point: nil, scale: 1.5, autoScales: false, displayMode: 3),
                       "a y without an x is not a usable page point")

        // Nothing recorded at all → fit-width, page mode default, top of the document.
        let (beta, betaLocation) = try await location("hash-beta")
        XCTAssertNil(beta.lastZoom)
        XCTAssertEqual(betaLocation, ReadingLocation(pageIndex: 0, point: nil, scale: nil, autoScales: true, displayMode: 1))

        // No zoom but a scroll_y and an explicit display mode 0 → still fit-width, single page.
        let (gammaV2, gammaLocation) = try await location("hash-gamma-v2")
        XCTAssertEqual(gammaV2.lastScrollY, 12.75)
        XCTAssertEqual(gammaLocation, ReadingLocation(pageIndex: 1, point: nil, scale: nil, autoScales: true, displayMode: 0))

        // Everything is nullable: the new columns hold NULL (not 0 / false) for legacy rows.
        let nulls = try await database.writer.read { db in
            try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM documents WHERE last_scroll_x IS NULL AND last_auto_scales IS NULL
                """)
        }
        XCTAssertEqual(nulls, 4)

        // Writing a location to one document stores 0 (not NULL) for "auto-scale off" and leaves
        // the others' legacy values alone.
        let saved = ReadingLocation(pageIndex: 3, point: CGPoint(x: 12.5, y: 640.25), scale: 2.0, autoScales: false, displayMode: 2)
        try await repository.updateReadingState(documentId: try XCTUnwrap(alpha.id), location: saved)
        let (updated, updatedLocation) = try await location("hash-alpha")
        XCTAssertEqual(updated.lastAutoScales, false)
        XCTAssertEqual(updatedLocation, saved)
        let (betaAgain, _) = try await location("hash-beta")
        XCTAssertNil(betaAgain.lastAutoScales)
        XCTAssertNil(betaAgain.lastScrollX)

        // Clearing the point writes NULLs again.
        try await repository.updateReadingState(
            documentId: try XCTUnwrap(alpha.id),
            location: ReadingLocation(pageIndex: 3, point: nil, scale: nil, autoScales: true, displayMode: 1))
        let (cleared, _) = try await location("hash-alpha")
        XCTAssertNil(cleared.lastScrollX)
        XCTAssertNil(cleared.lastScrollY)
        XCTAssertEqual(cleared.lastAutoScales, true)
    }

    // MARK: - Already current / repeated

    func testMigratingACurrentDatabaseIsANoOpEvenWhenRepeated() throws {
        let (url, before) = try legacyDatabase(upTo: LegacyDatabase.currentIdentifier)
        let baseline = Database(url: url)
        let (schemaVersion, applied) = try read(baseline) {
            (try Int.fetchOne($0, sql: "PRAGMA schema_version"), try Database.migrator.appliedMigrations($0))
        }
        XCTAssertEqual(applied, Database.migrator.migrations)

        for _ in 0..<3 {
            let again = Database(url: url)
            XCTAssertTrue(again.isPersistent)
            let (version, after, complete, superseded) = try read(again) { db in
                (try Int.fetchOne(db, sql: "PRAGMA schema_version"),
                 try DatabaseInspector.snapshot(db),
                 try Database.migrator.hasCompletedMigrations(db),
                 try Database.migrator.hasBeenSuperseded(db))
            }
            XCTAssertEqual(version, schemaVersion, "no DDL may run on an up-to-date database")
            XCTAssertEqual(after, before)
            XCTAssertTrue(complete)
            XCTAssertFalse(superseded)
        }

        // Driving the migrator directly a second time is also harmless.
        let pool = try DatabasePool(path: url.path)
        try Database.migrator.migrate(pool)
        try Database.migrator.migrate(pool)
        XCTAssertEqual(try pool.read { try DatabaseInspector.snapshot($0) }, before)
    }

    // MARK: - Health of the upgraded database

    func testUpgradedDatabaseIsHealthyWithForeignKeysOnForEveryConnection() async throws {
        let (url, _) = try legacyDatabase(upTo: "v1_documents_and_annotations")
        let database = Database(url: url)
        XCTAssertTrue(database.isPersistent)

        XCTAssertEqual(try read(database) { try DatabaseInspector.integrityCheck($0) }, ["ok"])
        XCTAssertTrue(try read(database) { try DatabaseInspector.foreignKeyViolations($0) }.isEmpty)

        // `read` runs on a pooled reader connection, `write` on the writer connection.
        let readerForeignKeys = try read(database) { try Int.fetchOne($0, sql: "PRAGMA foreign_keys") }
        let writerForeignKeys = try write(database) { try Int.fetchOne($0, sql: "PRAGMA foreign_keys") }
        XCTAssertEqual(readerForeignKeys, 1)
        XCTAssertEqual(writerForeignKeys, 1)
        XCTAssertEqual(try read(database) { try String.fetchOne($0, sql: "PRAGMA journal_mode") }, "wal")

        // Enforcement is real: an annotation for a missing document is rejected.
        let orphan = AnnotationRecord(id: "orphan", groupId: "orphan", documentId: 9_999, pageIndex: 0,
                                      annotationType: "highlight", boundsJSON: "[]", color: nil,
                                      selectedText: nil, noteContent: nil, translationId: nil,
                                      createdAt: Date(), updatedAt: Date())
        do {
            try await AnnotationRepository(database: database).insertAll([orphan])
            XCTFail("orphan annotation must violate the foreign key")
        } catch let error as DatabaseError {
            XCTAssertEqual(error.resultCode, .SQLITE_CONSTRAINT)
        }

        // Deleting a document cascades through the upgraded schema (v1 rows only here).
        try await database.writer.write { db in try db.execute(sql: "DELETE FROM documents WHERE id = 1") }
        let annotationDocuments = try await database.writer.read { db in
            try Int64.fetchAll(db, sql: "SELECT DISTINCT document_id FROM annotations ORDER BY 1")
        }
        XCTAssertEqual(annotationDocuments, [2])
    }

    func testUpgradedIdsKeepIncreasingForNewRows() async throws {
        let (url, _) = try legacyDatabase(upTo: LegacyDatabase.currentIdentifier)
        let repository = DocumentRepository(database: Database(url: url))
        let fresh = try await repository.upsert(fileHash: "brand-new", fileURL: URL(fileURLWithPath: "/tmp/new.pdf"),
                                                title: "New", pageCount: 2)
        XCTAssertEqual(fresh.id, 6, "AUTOINCREMENT continues after the highest legacy id (5)")
    }
}
