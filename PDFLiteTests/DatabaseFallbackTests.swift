import GRDB
import XCTest

/// What `Database(url:)` does when the file cannot be used (design §8: a broken database must not
/// block reading, but the loss of persistence has to be visible). The fallback is an in-memory
/// queue with `isPersistent == false`. The invariant under test throughout: the user's file is
/// never deleted, renamed, truncated or rewritten to make the app "work".
final class DatabaseFallbackTests: PersistenceTestCase {
    private func read<T>(_ database: Database, _ body: (GRDB.Database) throws -> T) throws -> T {
        try database.writer.read(body)
    }

    private func directoryListing(_ url: URL? = nil) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: (url ?? directory).path).sorted()
    }

    /// Rows of a database file, read through a plain pool (no migrations), for before/after comparison.
    private func snapshot(of url: URL) throws -> [String: DatabaseInspector.Rows] {
        let pool = try DatabasePool(path: url.path)
        defer { try? pool.close() }
        return try pool.read { try DatabaseInspector.snapshot($0) }
    }

    /// The app must keep working on the fallback: every repository can create and read rows, and
    /// the in-memory schema is fully migrated.
    private func assertUsableInMemory(_ database: Database, file: StaticString = #filePath, line: UInt = #line) async throws {
        XCTAssertFalse(database.isPersistent, file: file, line: line)
        XCTAssertEqual(try read(database) { try Database.migrator.appliedMigrations($0) },
                       Database.migrator.migrations, "fallback schema must be fully migrated", file: file, line: line)

        let documents = DocumentRepository(database: database)
        XCTAssertFalse(documents.isPersistent, file: file, line: line)
        let document = try await documents.upsert(fileHash: "mem-hash", fileURL: URL(fileURLWithPath: "/tmp/mem.pdf"),
                                                  title: "Mem", pageCount: 3)
        let documentId = try XCTUnwrap(document.id, file: file, line: line)
        try await documents.updateReadingState(
            documentId: documentId,
            location: ReadingLocation(pageIndex: 2, point: CGPoint(x: 1, y: 2), scale: 1.25, autoScales: false, displayMode: 3))
        let stored = try await documents.find(byHash: "mem-hash")
        XCTAssertEqual(stored?.lastPage, 2, file: file, line: line)
        let byURL = try await documents.find(byURL: URL(fileURLWithPath: "/tmp/mem.pdf"))
        XCTAssertEqual(byURL?.id, documentId, file: file, line: line)

        let annotations = AnnotationRepository(database: database)
        let now = Date()
        try await annotations.insertAll([AnnotationRecord(
            id: "mem-a", groupId: "mem-a", documentId: documentId, pageIndex: 0, annotationType: "highlight",
            boundsJSON: "[]", color: nil, selectedText: "text", noteContent: nil, translationId: nil,
            createdAt: now, updatedAt: now)])
        let listed = try await annotations.list(forDocumentId: documentId)
        XCTAssertEqual(listed.map(\.id), ["mem-a"], file: file, line: line)

        let translations = TranslationRepository(database: database)
        let saved = try await translations.insert(TranslationRecord(
            id: nil, documentId: documentId, pageIndex: 0, textHash: "mem-h", sourceText: "s", targetText: "t",
            provider: "deepseek", model: "m", createdAt: now))
        XCTAssertNotNil(saved.id, file: file, line: line)
        let cached = try await translations.findCache(byHash: "mem-h")
        XCTAssertEqual(cached?.id, saved.id, file: file, line: line)
    }

    // MARK: - (a) Unreadable file contents

    func testGarbageFileFallsBackToMemoryAndIsNeverTouched() async throws {
        let payloads: [String: Data] = [
            "garbage": Data((0..<600).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) }),
            "tiny": Data("not sqlite".utf8),
            // Right magic, nonsense afterwards: SQLite reports the file as malformed.
            "magic-then-noise": Data("SQLite format 3\0".utf8) + Data((0..<8192).map { UInt8(truncatingIfNeeded: $0 &* 13 &+ 5) }),
        ]
        for (name, bytes) in payloads {
            let url = databaseURL(name)
            try bytes.write(to: url)
            let listingBefore = try directoryListing()

            let database = Database(url: url)
            try await assertUsableInMemory(database)

            XCTAssertEqual(try Data(contentsOf: url), bytes, "\(name): original bytes must be untouched")
            XCTAssertEqual(try directoryListing(), listingBefore, "\(name): no renamed/quarantined/sidecar files appear")
        }
    }

    func testRealDatabaseWithDestroyedHeaderFallsBackWithoutModifyingIt() async throws {
        let url = databaseURL("wrecked")
        try LegacyDatabase.build(at: url, upTo: LegacyDatabase.currentIdentifier)
        var bytes = try Data(contentsOf: url)
        bytes.replaceSubrange(0..<16, with: Data(repeating: 0xAB, count: 16)) // the "SQLite format 3\0" magic
        try bytes.write(to: url)
        // Only the main file matters for this test; drop leftover sidecars so they cannot mask it.
        for suffix in ["-wal", "-shm"] { try? FileManager.default.removeItem(atPath: url.path + suffix) }
        let listingBefore = try directoryListing()

        let database = Database(url: url)
        try await assertUsableInMemory(database)
        XCTAssertEqual(try Data(contentsOf: url), bytes)
        XCTAssertEqual(try directoryListing(), listingBefore)
    }

    func testEmptyFileIsAFreshDatabaseNotACorruptOne() throws {
        // A zero-byte file is what SQLite itself creates first, so it is initialised in place and stays persistent.
        let url = databaseURL("empty")
        try Data().write(to: url)
        let database = Database(url: url)
        XCTAssertTrue(database.isPersistent)
        XCTAssertEqual(try read(database) { try Database.migrator.appliedMigrations($0) }, Database.migrator.migrations)
    }

    func testFallbackDatabasesAreIsolatedFromEachOther() async throws {
        let urlA = databaseURL("a"), urlB = databaseURL("b")
        try Data("junk A".utf8).write(to: urlA)
        try Data("junk B".utf8).write(to: urlB)
        let a = Database(url: urlA), b = Database(url: urlB)
        _ = try await DocumentRepository(database: a)
            .upsert(fileHash: "only-in-a", fileURL: URL(fileURLWithPath: "/tmp/a.pdf"), title: nil, pageCount: 1)
        let leaked = try await DocumentRepository(database: b).find(byHash: "only-in-a")
        XCTAssertNil(leaked)
    }

    // MARK: - (b) Unusable location

    func testMissingParentDirectoryFallsBackWithoutCreatingAnything() async throws {
        let url = directory.appendingPathComponent("no/such/dir/reader.sqlite")
        let database = Database(url: url)
        try await assertUsableInMemory(database)
        XCTAssertEqual(try directoryListing(), [])
    }

    func testUnwritableDirectoryFallsBackWithoutCreatingAnything() async throws {
        let locked = directory.appendingPathComponent("locked", isDirectory: true)
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: locked.path)
        try XCTSkipIf(FileManager.default.isWritableFile(atPath: locked.path), "permissions are not enforced for this user")

        let database = Database(url: locked.appendingPathComponent("reader.sqlite"))
        try await assertUsableInMemory(database)
        XCTAssertEqual(try directoryListing(locked), [])
    }

    /// A write-protected file is never modified. Depending on whether SQLite can set up the WAL
    /// side files it either falls back to memory or opens read-only (reads work, every write throws
    /// SQLITE_READONLY, which `DocumentSession` turns into its "无法保存" notice). Silent loss of a
    /// write is the one outcome that must not happen.
    func testReadOnlyDatabaseFileIsNeverModifiedAndNeverSilentlyLosesWrites() async throws {
        let url = databaseURL("readonly")
        try LegacyDatabase.build(at: url, upTo: LegacyDatabase.currentIdentifier)
        let rowsBefore = try snapshot(of: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: url.path)
        try XCTSkipIf(FileManager.default.isWritableFile(atPath: url.path), "permissions are not enforced for this user")
        let bytes = try Data(contentsOf: url)

        let database = Database(url: url)
        if database.isPersistent {
            let documents = DocumentRepository(database: database)
            let alpha = try await documents.find(byHash: "hash-alpha")
            XCTAssertEqual(alpha?.lastPage, 12, "reads keep working on a read-only file")
            do {
                _ = try await documents.upsert(fileHash: "cannot-save", fileURL: URL(fileURLWithPath: "/tmp/ro.pdf"),
                                               title: nil, pageCount: 1)
                XCTFail("a write to a read-only database must throw")
            } catch let error as DatabaseError {
                XCTAssertEqual(error.resultCode, .SQLITE_READONLY)
            }
        } else {
            try await assertUsableInMemory(database)
        }
        XCTAssertEqual(try Data(contentsOf: url), bytes, "a write-protected file cannot change")

        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        XCTAssertEqual(try snapshot(of: url), rowsBefore, "user data is intact once the file is writable again")
    }

    // MARK: - (c) Database written by a newer build

    /// Current behaviour, defined here on purpose: GRDB's migrator only runs *registered*
    /// migrations and ignores identifiers it does not know, so a database from a newer PDFLite
    /// opens as persistent and unchanged — `hasBeenSuperseded` reports it, but nothing in the app
    /// looks at that yet (see the report's proposal).
    func testDatabaseFromANewerSchemaOpensPersistentlyAndKeepsEveryRow() async throws {
        let url = databaseURL("newer")
        try LegacyDatabase.build(at: url, upTo: LegacyDatabase.currentIdentifier)
        let pool = try DatabasePool(path: url.path)
        try await pool.write { db in
            try db.execute(sql: "INSERT INTO grdb_migrations (identifier) VALUES ('v8_from_the_future')")
            try db.execute(sql: "ALTER TABLE documents ADD COLUMN future_note TEXT NOT NULL DEFAULT 'kept'")
            try db.execute(sql: "CREATE TABLE future_things (id INTEGER PRIMARY KEY, payload TEXT)")
            try db.execute(sql: "INSERT INTO future_things (payload) VALUES ('precious')")
        }
        let rowsBefore = try await pool.read { try DatabaseInspector.snapshot($0) }
        try pool.close()

        let database = Database(url: url)
        XCTAssertTrue(database.isPersistent, "unknown migration identifiers are not an error for GRDB")
        XCTAssertTrue(try read(database) { try Database.migrator.hasBeenSuperseded($0) })

        // Nothing was erased or rewritten to "fix" the mismatch (DEBUG eraseDatabaseOnSchemaChange stays off).
        XCTAssertEqual(try read(database) { try DatabaseInspector.snapshot($0) }, rowsBefore)
        XCTAssertEqual(try read(database) { try String.fetchAll($0, sql: "SELECT identifier FROM grdb_migrations ORDER BY identifier") },
                       (Database.migrator.migrations + ["v8_from_the_future"]).sorted())
        XCTAssertEqual(try read(database) { try String.fetchAll($0, sql: "SELECT payload FROM future_things") }, ["precious"])

        // The current repositories keep working on the parts of the schema they know.
        let documents = DocumentRepository(database: database)
        let alpha = try await documents.find(byHash: "hash-alpha")
        XCTAssertEqual(alpha?.lastPage, 12)
        let inserted = try await documents.upsert(fileHash: "written-by-older-build",
                                                  fileURL: URL(fileURLWithPath: "/tmp/old.pdf"), title: nil, pageCount: 1)
        XCTAssertNotNil(inserted.id)
        XCTAssertEqual(try read(database) { try String.fetchOne($0, sql: "SELECT future_note FROM documents WHERE file_hash = 'written-by-older-build'") },
                       "kept", "the newer column's default applies to rows written by the older build")
    }

    // MARK: - (d) A migration that cannot complete

    /// A failed migration rolls back completely: the file stays at the previous schema version with
    /// all rows intact, and the app falls back to memory instead of running on half a schema. (Also
    /// documents a sharp edge: one pre-existing foreign-key violation makes *every* pending
    /// migration fail, so the whole database stays unavailable until it is repaired by hand.)
    func testFailedMigrationRollsBackAndFallsBackToMemory() async throws {
        let url = databaseURL("orphan")
        try LegacyDatabase.build(at: url, upTo: "v5_annotation_group_id")
        let pool = try DatabasePool(path: url.path)
        try await pool.writeWithoutTransaction { db in
            try db.execute(sql: "PRAGMA foreign_keys = OFF")
            try db.execute(sql: """
                INSERT INTO annotations (id, group_id, document_id, page_index, annotation_type, bounds_json, created_at, updated_at)
                VALUES ('orphan', 'orphan', 999, 0, 'highlight', '[]', '2026-01-01 00:00:00.000', '2026-01-01 00:00:00.000')
                """)
            try db.execute(sql: "PRAGMA foreign_keys = ON")
        }
        try pool.close()
        let rowsBefore = try snapshot(of: url)

        let database = Database(url: url)
        try await assertUsableInMemory(database)

        XCTAssertEqual(try snapshot(of: url), rowsBefore, "no row lost or altered")
        let check = try DatabasePool(path: url.path)
        defer { try? check.close() }
        let applied = try await check.read { try Database.migrator.appliedMigrations($0) }
        XCTAssertEqual(applied, Array(Database.migrator.migrations.prefix(5)), "v6 and v7 rolled back, nothing half-applied")
        let indexes = try await check.read { try String.fetchAll($0, sql: "SELECT name FROM sqlite_master WHERE type = 'index' AND name = 'idx_documents_file_url'") }
        XCTAssertTrue(indexes.isEmpty)
    }
}
