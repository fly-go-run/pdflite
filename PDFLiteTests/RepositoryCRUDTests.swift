import GRDB
import PDFKit
import XCTest

/// Repository CRUD (design §11 unit tests, §4.3 consistency rules) against an isolated on-disk
/// `Database` in the temp directory — never the user's `reader.sqlite`.
class RepositoryTestCase: PersistenceTestCase {
    var database: Database!
    var documents: DocumentRepository!
    var annotations: AnnotationRepository!
    var translations: TranslationRepository!

    /// Whole-second base so `Date` survives GRDB's millisecond text format bit for bit.
    static let epoch: TimeInterval = 1_700_000_000

    override func setUpWithError() throws {
        try super.setUpWithError()
        database = Database(url: databaseURL("repo"))
        XCTAssertTrue(database.isPersistent)
        documents = DocumentRepository(database: database)
        annotations = AnnotationRepository(database: database)
        translations = TranslationRepository(database: database)
    }

    func at(_ seconds: TimeInterval) -> Date { Self.date(seconds) }

    static func date(_ seconds: TimeInterval) -> Date { Date(timeIntervalSince1970: epoch + seconds) }

    func pdfURL(_ name: String) -> URL { URL(fileURLWithPath: "/tmp/pdflite-tests/\(name).pdf") }

    func count(_ table: String) async throws -> Int {
        try await database.writer.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(table)") ?? 0
        }
    }

    func makeDocument(_ name: String = "paper", hash: String? = nil) async throws -> DocumentRecord {
        try await documents.upsert(fileHash: hash ?? "hash-\(name)", fileURL: pdfURL(name), title: name, pageCount: 10)
    }

    func makeDocumentId(_ name: String = "paper") async throws -> Int64 {
        let record = try await makeDocument(name)
        return try XCTUnwrap(record.id)
    }

    func annotation(_ id: String, group: String? = nil, document: Int64, page: Int = 0, text: String? = "text",
                    at seconds: TimeInterval = 0, translation: Int64? = nil) -> AnnotationRecord {
        Self.makeAnnotation(id, group: group, document: document, page: page, text: text, at: seconds, translation: translation)
    }

    func translation(hash: String = "hash", document: Int64? = nil, page: Int? = 0, source: String = "source",
                     target: String = "target", model: String = "model", at seconds: TimeInterval = 0) -> TranslationRecord {
        Self.makeTranslation(hash: hash, document: document, page: page, source: source, target: target, model: model, at: seconds)
    }

    // Static twins so concurrent tasks can build records without capturing the (non-Sendable) test case.
    static func makeAnnotation(_ id: String, group: String? = nil, document: Int64, page: Int = 0, text: String? = "text",
                               at seconds: TimeInterval = 0, translation: Int64? = nil) -> AnnotationRecord {
        AnnotationRecord(id: id, groupId: group ?? id, documentId: document, pageIndex: page,
                         annotationType: "highlight", boundsJSON: "[]", color: "#FFEB3B80",
                         selectedText: text, noteContent: nil, translationId: translation,
                         createdAt: date(seconds), updatedAt: date(seconds))
    }

    static func makeTranslation(hash: String = "hash", document: Int64? = nil, page: Int? = 0, source: String = "source",
                                target: String = "target", model: String = "model", at seconds: TimeInterval = 0) -> TranslationRecord {
        TranslationRecord(id: nil, documentId: document, pageIndex: page, textHash: hash, sourceText: source,
                          targetText: target, provider: "deepseek", model: model, createdAt: date(seconds))
    }
}

final class DocumentRepositoryTests: RepositoryTestCase {
    func testUpsertCreatesARecordWithDefaults() async throws {
        let record = try await documents.upsert(fileHash: "h1", fileURL: pdfURL("a"), title: "A", pageCount: 12)
        XCTAssertNotNil(record.id)
        XCTAssertEqual(record.fileHash, "h1")
        XCTAssertEqual(record.fileURL, pdfURL("a").path)
        XCTAssertEqual(record.title, "A")
        XCTAssertEqual(record.pageCount, 12)
        XCTAssertEqual(record.lastPage, 0)
        XCTAssertNil(record.lastZoom)
        XCTAssertNil(record.lastScrollX)
        XCTAssertNil(record.lastScrollY)
        XCTAssertNil(record.lastAutoScales)
        XCTAssertNil(record.displayMode)
        XCTAssertEqual(record.createdAt, record.updatedAt)
        XCTAssertEqual(record.lastOpenedAt, record.createdAt)
        XCTAssertTrue(documents.isPersistent)

        let stored = try await documents.find(byHash: "h1")
        XCTAssertEqual(stored?.id, record.id)
        XCTAssertEqual(stored?.title, "A")
    }

    func testFindReturnsNilWhenNothingMatches() async throws {
        _ = try await makeDocument("present")
        let byHash = try await documents.find(byHash: "absent")
        let byURL = try await documents.find(byURL: pdfURL("absent"))
        XCTAssertNil(byHash)
        XCTAssertNil(byURL)
    }

    func testUpsertOfTheSameHashUpdatesInPlaceAndKeepsReadingState() async throws {
        let first = try await documents.upsert(fileHash: "same", fileURL: pdfURL("a"), title: "Old title", pageCount: 5)
        let id = try XCTUnwrap(first.id)
        let location = ReadingLocation(pageIndex: 3, point: CGPoint(x: 10, y: 20), scale: 1.5, autoScales: false, displayMode: 2)
        try await documents.updateReadingState(documentId: id, location: location)
        let before = try await documents.find(byHash: "same")

        try await Task.sleep(for: .milliseconds(20))
        let second = try await documents.upsert(fileHash: "same", fileURL: pdfURL("a"), title: "New title", pageCount: 6)

        XCTAssertEqual(second.id, id)
        let rows = try await count("documents")
        XCTAssertEqual(rows, 1)
        let afterFound = try await documents.find(byHash: "same")
        let after = try XCTUnwrap(afterFound)
        XCTAssertEqual(after.title, "New title")
        XCTAssertEqual(after.pageCount, 6)
        XCTAssertEqual(after.createdAt, before?.createdAt, "created_at is set once")
        XCTAssertGreaterThan(after.updatedAt, try XCTUnwrap(before).updatedAt)
        XCTAssertGreaterThan(try XCTUnwrap(after.lastOpenedAt), try XCTUnwrap(before?.lastOpenedAt))
        XCTAssertEqual(ReadingLocation(record: after), location, "re-opening must not reset the saved position")
    }

    /// §4.3 rule 1: the content hash is the identity, so a moved/renamed file is the same document.
    func testSameHashAtANewPathKeepsTheIdAndFollowsTheFile() async throws {
        let old = try await documents.upsert(fileHash: "moved", fileURL: pdfURL("old-name"), title: "T", pageCount: 4)
        let id = try XCTUnwrap(old.id)
        try await annotations.insertAll([annotation("a1", document: id)])
        try await documents.updateReadingState(documentId: id, location: ReadingLocation(pageIndex: 2))

        let moved = try await documents.upsert(fileHash: "moved", fileURL: pdfURL("new-name"), title: "T", pageCount: 4)

        XCTAssertEqual(moved.id, id)
        XCTAssertEqual(moved.fileURL, pdfURL("new-name").path)
        let atOld = try await documents.find(byURL: pdfURL("old-name"))
        let atNew = try await documents.find(byURL: pdfURL("new-name"))
        XCTAssertNil(atOld)
        XCTAssertEqual(atNew?.id, id)
        XCTAssertEqual(atNew?.lastPage, 2)
        let kept = try await annotations.list(forDocumentId: id)
        XCTAssertEqual(kept.map(\.id), ["a1"], "annotations stay attached to the document")
        let rows = try await count("documents")
        XCTAssertEqual(rows, 1)
    }

    /// §4.3 rule 2: same path, changed content → a new document; the old one and its data remain.
    func testSameURLWithADifferentHashCreatesANewDocument() async throws {
        let v1 = try await documents.upsert(fileHash: "v1", fileURL: pdfURL("paper"), title: "Paper", pageCount: 8)
        let id1 = try XCTUnwrap(v1.id)
        try await annotations.insertAll([annotation("note-on-v1", document: id1)])

        try await Task.sleep(for: .milliseconds(20))
        let v2 = try await documents.upsert(fileHash: "v2", fileURL: pdfURL("paper"), title: "Paper", pageCount: 9)
        let id2 = try XCTUnwrap(v2.id)

        XCTAssertNotEqual(id1, id2)
        let rows = try await count("documents")
        XCTAssertEqual(rows, 2)
        let byV1 = try await documents.find(byHash: "v1")
        let byV2 = try await documents.find(byHash: "v2")
        XCTAssertEqual(byV1?.id, id1)
        XCTAssertEqual(byV2?.id, id2)
        XCTAssertEqual(byV1?.fileURL, byV2?.fileURL)
        let latest = try await documents.find(byURL: pdfURL("paper"))
        XCTAssertEqual(latest?.id, id2, "the path resolves to the most recently used document")
        let onV1 = try await annotations.list(forDocumentId: id1)
        let onV2 = try await annotations.list(forDocumentId: id2)
        XCTAssertEqual(onV1.count, 1)
        XCTAssertTrue(onV2.isEmpty, "highlights are not carried over to different content")

        // Putting the old content back finds the old document again and makes it the path's newest.
        try await Task.sleep(for: .milliseconds(20))
        let back = try await documents.upsert(fileHash: "v1", fileURL: pdfURL("paper"), title: "Paper", pageCount: 8)
        XCTAssertEqual(back.id, id1)
        let newest = try await documents.find(byURL: pdfURL("paper"))
        XCTAssertEqual(newest?.id, id1)
        let stillTwo = try await count("documents")
        XCTAssertEqual(stillTwo, 2)
    }

    func testPathsWithSpacesUnicodeAndPunctuationRoundTrip() async throws {
        let odd = URL(fileURLWithPath: "/tmp/pdflite-tests/论文 100% #1 (final) é.pdf")
        let record = try await documents.upsert(fileHash: "odd", fileURL: odd, title: nil, pageCount: 1)
        XCTAssertEqual(record.fileURL, odd.path)
        let found = try await documents.find(byURL: odd)
        XCTAssertEqual(found?.id, record.id)
        XCTAssertNil(found?.title)
    }

    func testFileHashIsUniqueInTheSchema() async throws {
        _ = try await makeDocument("dup", hash: "unique-hash")
        do {
            try await database.writer.write { db in
                var duplicate = DocumentRecord(id: nil, fileHash: "unique-hash", fileURL: "/tmp/other.pdf", title: nil,
                                               pageCount: 1, lastOpenedAt: nil, lastPage: 0, lastZoom: nil,
                                               lastScrollY: nil, displayMode: nil, createdAt: Date(), updatedAt: Date())
                try duplicate.insert(db)
            }
            XCTFail("duplicate file_hash must violate the UNIQUE constraint")
        } catch let error as DatabaseError {
            XCTAssertEqual(error.resultCode, .SQLITE_CONSTRAINT)
        }
    }

    func testReadingStateRoundTripsWithFullDoublePrecision() async throws {
        let id = try await makeDocumentId()
        let location = ReadingLocation(pageIndex: 41, point: CGPoint(x: 12.345678901234567, y: 1.0 / 3.0),
                                       scale: 1.2345678901234567, autoScales: false, displayMode: 3)
        try await documents.updateReadingState(documentId: id, location: location)
        let storedFound = try await documents.find(byHash: "hash-paper")
        let stored = try XCTUnwrap(storedFound)
        XCTAssertEqual(stored.lastPage, 41)
        XCTAssertEqual(stored.lastScrollX, 12.345678901234567)
        XCTAssertEqual(stored.lastScrollY, 1.0 / 3.0)
        XCTAssertEqual(stored.lastZoom, 1.2345678901234567)
        XCTAssertEqual(stored.lastAutoScales, false)
        XCTAssertEqual(stored.displayMode, 3)
        XCTAssertEqual(ReadingLocation(record: stored), location)
        // Identity and descriptive fields are not touched by a position update.
        XCTAssertEqual(stored.fileHash, "hash-paper")
        XCTAssertEqual(stored.fileURL, pdfURL("paper").path)
        XCTAssertEqual(stored.title, "paper")
        XCTAssertEqual(stored.pageCount, 10)
    }

    func testSynchronousFlushWritesTheSameColumnsAsTheAsyncPath() async throws {
        let id = try await makeDocumentId()
        let location = ReadingLocation(pageIndex: 7, point: CGPoint(x: 1.5, y: 2.5), scale: 0.75, autoScales: true, displayMode: 0)
        try documents.updateReadingStateNow(documentId: id, location: location)
        let storedFound = try await documents.find(byHash: "hash-paper")
        let stored = try XCTUnwrap(storedFound)
        XCTAssertEqual(ReadingLocation(record: stored), location)
        XCTAssertEqual(stored.lastAutoScales, true)
    }

    func testReadingStateUpdateForAnUnknownDocumentChangesNothing() async throws {
        let id = try await makeDocumentId()
        let before = try await documents.find(byHash: "hash-paper")
        try await documents.updateReadingState(documentId: id + 100, location: ReadingLocation(pageIndex: 9))
        try documents.updateReadingStateNow(documentId: id + 100, location: ReadingLocation(pageIndex: 9))
        let after = try await documents.find(byHash: "hash-paper")
        XCTAssertEqual(after, before)
        let rows = try await count("documents")
        XCTAssertEqual(rows, 1)
    }

    func testReadingStateUpdateOnlyAffectsItsOwnDocument() async throws {
        let a = try await makeDocumentId("a")
        _ = try await makeDocument("b")
        let bBefore = try await documents.find(byHash: "hash-b")
        try await documents.updateReadingState(documentId: a, location: ReadingLocation(pageIndex: 5, point: CGPoint(x: 1, y: 2)))
        let bAfter = try await documents.find(byHash: "hash-b")
        XCTAssertEqual(bAfter, bBefore)
    }

    func testDisplayModeMappingRoundTripsAndFallsBackToContinuous() {
        for mode in [PDFDisplayMode.singlePage, .singlePageContinuous, .twoUp, .twoUpContinuous] {
            XCTAssertEqual(PDFDisplayMode.from(dbValue: mode.dbValue), mode)
        }
        XCTAssertEqual(PDFDisplayMode.from(dbValue: nil), .singlePageContinuous)
        XCTAssertEqual(PDFDisplayMode.from(dbValue: 99), .singlePageContinuous)
    }
}

final class AnnotationRepositoryTests: RepositoryTestCase {
    func testInsertAndListRoundTripEveryField() async throws {
        let document = try await makeDocumentId()
        let rects = [CGRect(x: 72.5, y: 700.25, width: 300.125, height: 12.5),
                     CGRect(x: 72.5, y: 686.0, width: 280.75, height: 12.5)]
        let record = AnnotationRecord(id: UUID().uuidString, groupId: "group-1", documentId: document, pageIndex: 4,
                                      annotationType: "highlight", boundsJSON: try AnnotationRectCoder.encode(rects),
                                      color: "#FFEB3B80", selectedText: "多行\n选中的文本", noteContent: "笔记",
                                      translationId: nil, createdAt: at(10), updatedAt: at(20))
        try await annotations.insertAll([record])

        let listed = try await annotations.list(forDocumentId: document)
        XCTAssertEqual(listed, [record])
        XCTAssertEqual(try AnnotationRectCoder.decode(try XCTUnwrap(listed.first).boundsJSON), rects)
    }

    func testOptionalFieldsMayBeNil() async throws {
        let document = try await makeDocumentId()
        var record = annotation("bare", document: document, text: nil)
        record.color = nil
        try await annotations.insertAll([record])
        let listed = try await annotations.list(forDocumentId: document)
        XCTAssertEqual(listed, [record])
    }

    func testListIsScopedToTheDocumentAndOrderedByPageThenCreationTime() async throws {
        let a = try await makeDocumentId("a")
        let b = try await makeDocumentId("b")
        try await annotations.insertAll([
            annotation("p5", document: a, page: 5, at: 2),
            annotation("p0-late", document: a, page: 0, at: 3),
            annotation("other-doc", document: b, page: 0, at: 1),
            annotation("p0-early", document: a, page: 0, at: 1),
            annotation("p2", document: a, page: 2, at: 9),
        ])
        let listedA = try await annotations.list(forDocumentId: a)
        let listedB = try await annotations.list(forDocumentId: b)
        let none = try await annotations.list(forDocumentId: b + 100)
        XCTAssertEqual(listedA.map(\.id), ["p0-early", "p0-late", "p2", "p5"])
        XCTAssertEqual(listedB.map(\.id), ["other-doc"])
        XCTAssertTrue(none.isEmpty)
    }

    func testMillisecondCreationTimesOrderWithinAPage() async throws {
        let document = try await makeDocumentId()
        try await annotations.insertAll([
            annotation("c", document: document, at: 0.003),
            annotation("a", document: document, at: 0.001),
            annotation("b", document: document, at: 0.002),
        ])
        let listed = try await annotations.list(forDocumentId: document)
        XCTAssertEqual(listed.map(\.id), ["a", "b", "c"])
    }

    func testDeleteByGroupRemovesEveryPageOfThatHighlightOnly() async throws {
        let document = try await makeDocumentId()
        try await annotations.insertAll([
            annotation("m1", group: "multi", document: document, page: 1),
            annotation("m2", group: "multi", document: document, page: 2),
            annotation("m3", group: "multi", document: document, page: 3),
            annotation("keep", group: "single", document: document, page: 2),
        ])
        try await annotations.delete(groupId: "multi")
        let remaining = try await annotations.list(forDocumentId: document)
        XCTAssertEqual(remaining.map(\.id), ["keep"])
    }

    func testDeletingAnUnknownOrAlreadyDeletedGroupIsANoOp() async throws {
        let document = try await makeDocumentId()
        try await annotations.insertAll([annotation("keep", document: document)])
        try await annotations.delete(groupId: "never-existed")
        try await annotations.delete(groupId: "keep")
        try await annotations.delete(groupId: "keep")
        let remaining = try await annotations.list(forDocumentId: document)
        XCTAssertTrue(remaining.isEmpty)
        try await annotations.delete(groupId: "")
    }

    func testInsertAllIsAllOrNothing() async throws {
        let document = try await makeDocumentId()
        try await annotations.insertAll([annotation("existing", document: document)])
        do {
            // Second row of a two-page highlight collides with an existing primary key.
            try await annotations.insertAll([
                annotation("page-1", group: "g", document: document, page: 1),
                annotation("existing", group: "g", document: document, page: 2),
            ])
            XCTFail("duplicate id must be rejected")
        } catch let error as DatabaseError {
            XCTAssertEqual(error.resultCode, .SQLITE_CONSTRAINT)
        }
        let listed = try await annotations.list(forDocumentId: document)
        XCTAssertEqual(listed.map(\.id), ["existing"], "a half-inserted multi-page highlight must not remain")
    }

    func testAnnotationForAMissingDocumentIsRejected() async throws {
        do {
            try await annotations.insertAll([annotation("orphan", document: 4242)])
            XCTFail("foreign key must be enforced")
        } catch let error as DatabaseError {
            XCTAssertEqual(error.resultCode, .SQLITE_CONSTRAINT)
        }
        let rows = try await count("annotations")
        XCTAssertEqual(rows, 0)
    }

    func testInsertingNothingIsHarmless() async throws {
        try await annotations.insertAll([])
        let rows = try await count("annotations")
        XCTAssertEqual(rows, 0)
    }

    func testBoundsJSONRoundTripKeepsFullDoublePrecision() async throws {
        let rects = [
            CGRect(x: 0.1, y: 1.0 / 3.0, width: 72.123456789012345, height: -0.0000001),
            CGRect(x: 123456789.987654321, y: 1e-9, width: 5e-324, height: 1.7976931348623157e308),
            CGRect(x: -612.0, y: 0, width: 0.30000000000000004, height: 792),
        ]
        let json = try AnnotationRectCoder.encode(rects)
        XCTAssertEqual(try AnnotationRectCoder.decode(json), rects, "exact equality, not approximate")

        let document = try await makeDocumentId()
        var record = annotation("precise", document: document)
        record.boundsJSON = json
        try await annotations.insertAll([record])
        let listed = try await annotations.list(forDocumentId: document)
        XCTAssertEqual(try AnnotationRectCoder.decode(try XCTUnwrap(listed.first).boundsJSON), rects)
    }

    func testBoundsJSONContractAndEdgeCases() throws {
        // The on-disk format is part of the data contract: keys are x/y/w/h in page coordinates.
        XCTAssertEqual(try AnnotationRectCoder.decode(#"[{"x":1,"y":2,"w":3,"h":4}]"#),
                       [CGRect(x: 1, y: 2, width: 3, height: 4)])
        XCTAssertEqual(try AnnotationRectCoder.encode([]), "[]")
        XCTAssertEqual(try AnnotationRectCoder.decode("[]"), [])
        XCTAssertThrowsError(try AnnotationRectCoder.decode("not json"))
        XCTAssertThrowsError(try AnnotationRectCoder.decode(#"[{"x":1}]"#), "missing keys are an error, not zeros")
        // JSON cannot carry NaN/∞, so a degenerate rect fails to encode instead of storing garbage.
        XCTAssertThrowsError(try AnnotationRectCoder.encode([CGRect(x: CGFloat.nan, y: 0, width: 1, height: 1)]))
        XCTAssertThrowsError(try AnnotationRectCoder.encode([CGRect(x: 0, y: 0, width: CGFloat.infinity, height: 1)]))
    }

    func testUpdateTranslationIdBindsTheWholeGroupAndCanClearIt() async throws {
        let document = try await makeDocumentId()
        let saved = try await translations.insert(translation(document: document))
        let translationId = try XCTUnwrap(saved.id)
        try await annotations.insertAll([
            annotation("m1", group: "multi", document: document, page: 1),
            annotation("m2", group: "multi", document: document, page: 2),
            annotation("other", document: document, page: 1),
        ])

        try await annotations.updateTranslationId(groupId: "multi", translationId: translationId)
        var listed = try await annotations.list(forDocumentId: document)
        let bound = Dictionary(uniqueKeysWithValues: listed.map { ($0.id, $0.translationId) })
        XCTAssertEqual(bound["m1"] ?? nil, translationId)
        XCTAssertEqual(bound["m2"] ?? nil, translationId)
        XCTAssertNil(bound["other"] ?? nil)
        XCTAssertTrue(listed.filter { $0.groupId == "multi" }.allSatisfy { $0.updatedAt > $0.createdAt },
                      "updated_at moves when the binding changes")

        try await annotations.updateTranslationId(groupId: "multi", translationId: nil)
        listed = try await annotations.list(forDocumentId: document)
        XCTAssertTrue(listed.allSatisfy { $0.translationId == nil })

        try await annotations.updateTranslationId(groupId: "no-such-group", translationId: translationId)
        listed = try await annotations.list(forDocumentId: document)
        XCTAssertTrue(listed.allSatisfy { $0.translationId == nil }, "unknown group changes nothing")
    }

    func testConcatenatedSelectedTextFollowsDocumentOrderAndSkipsMissingText() async throws {
        let document = try await makeDocumentId()
        try await annotations.insertAll([
            annotation("p3", group: "g", document: document, page: 3, text: "third"),
            annotation("p1", group: "g", document: document, page: 1, text: "first"),
            annotation("p2", group: "g", document: document, page: 2, text: nil),
            annotation("elsewhere", group: "h", document: document, page: 1, text: "not this group"),
        ])
        let joined = try await annotations.concatenatedSelectedText(groupId: "g")
        XCTAssertEqual(joined, "first\n\nthird")
        let unknown = try await annotations.concatenatedSelectedText(groupId: "missing")
        XCTAssertEqual(unknown, "")
    }
}

final class TranslationRepositoryTests: RepositoryTestCase {
    func testInsertAssignsIdsAndRoundTripsEveryField() async throws {
        let document = try await makeDocumentId()
        let first = try await translations.insert(translation(hash: "h1", document: document, page: 3,
                                                               source: "Hello\nworld", target: "你好，世界", at: 5))
        let second = try await translations.insert(translation(hash: "h2", document: document, page: 4, at: 6))
        XCTAssertNotNil(first.id)
        XCTAssertGreaterThan(try XCTUnwrap(second.id), try XCTUnwrap(first.id))

        let found = try await translations.findCache(byHash: "h1")
        XCTAssertEqual(found, first)
        XCTAssertEqual(found?.sourceText, "Hello\nworld")
        XCTAssertEqual(found?.targetText, "你好，世界")
        XCTAssertEqual(found?.provider, "deepseek")
        XCTAssertEqual(found?.createdAt, at(5))
    }

    func testFindCacheMissReturnsNil() async throws {
        _ = try await translations.insert(translation(hash: "present"))
        let miss = try await translations.findCache(byHash: "absent")
        XCTAssertNil(miss)
    }

    func testHistoryIsKeptPerDocumentAndFindCacheReturnsTheNewestAcrossDocuments() async throws {
        let a = try await makeDocumentId("a")
        let b = try await makeDocumentId("b")
        _ = try await translations.insert(translation(hash: "shared", document: a, target: "A", at: 1))
        let inB = try await translations.insert(translation(hash: "shared", document: b, target: "B", at: 3))
        _ = try await translations.insert(translation(hash: "shared", document: a, target: "A2", at: 2))
        let global = try await translations.insert(translation(hash: "shared", document: nil, page: nil, target: "G", at: 4))
        let rows = try await count("translations")
        XCTAssertEqual(rows, 4, "no uniqueness on the hash: every insert is a history row")

        let newest = try await translations.findCache(byHash: "shared")
        XCTAssertEqual(newest?.id, global.id, "a document-less cache row participates like any other")
        try await database.writer.write { db in
            try db.execute(sql: "DELETE FROM translations WHERE id = ?", arguments: [global.id])
        }
        let afterDelete = try await translations.findCache(byHash: "shared")
        XCTAssertEqual(afterDelete?.id, inB.id, "newest by created_at, not by id")
    }

    func testFindInDocumentScopesByDocumentPageAndHash() async throws {
        let a = try await makeDocumentId("a")
        let b = try await makeDocumentId("b")
        let a0 = try await translations.insert(translation(hash: "h", document: a, page: 0, target: "a0", at: 1))
        let a0Newer = try await translations.insert(translation(hash: "h", document: a, page: 0, target: "a0-newer", at: 2))
        let a1 = try await translations.insert(translation(hash: "h", document: a, page: 1, at: 3))
        let aNoPage = try await translations.insert(translation(hash: "h", document: a, page: nil, at: 4))
        let b0 = try await translations.insert(translation(hash: "h", document: b, page: 0, at: 5))
        _ = try await translations.insert(translation(hash: "other-hash", document: a, page: 0, at: 6))

        let hitA0 = try await translations.findInDocument(textHash: "h", documentId: a, pageIndex: 0)
        let hitA1 = try await translations.findInDocument(textHash: "h", documentId: a, pageIndex: 1)
        let hitNoPage = try await translations.findInDocument(textHash: "h", documentId: a, pageIndex: nil)
        let hitB0 = try await translations.findInDocument(textHash: "h", documentId: b, pageIndex: 0)
        let wrongPage = try await translations.findInDocument(textHash: "h", documentId: b, pageIndex: 7)
        let wrongDocument = try await translations.findInDocument(textHash: "h", documentId: b + 100, pageIndex: 0)
        XCTAssertEqual(hitA0?.id, a0Newer.id, "duplicates in one (document, page): newest wins")
        XCTAssertNotEqual(hitA0?.id, a0.id)
        XCTAssertEqual(hitA1?.id, a1.id)
        XCTAssertEqual(hitNoPage?.id, aNoPage.id, "nil page matches only NULL-page rows")
        XCTAssertEqual(hitB0?.id, b0.id)
        XCTAssertNil(wrongPage)
        XCTAssertNil(wrongDocument)
    }

    func testInsertForAMissingDocumentIsRejectedButDocumentlessRowsAreAllowed() async throws {
        do {
            _ = try await translations.insert(translation(document: 777))
            XCTFail("foreign key must be enforced")
        } catch let error as DatabaseError {
            XCTAssertEqual(error.resultCode, .SQLITE_CONSTRAINT)
        }
        let saved = try await translations.insert(translation(hash: "global", document: nil, page: nil))
        XCTAssertNotNil(saved.id)
        XCTAssertNil(saved.documentId)
    }

    // MARK: replaceOrInsert (the "重试" path)

    func testReplaceOrInsertWithoutAMatchInsertsARow() async throws {
        let document = try await makeDocumentId()
        let saved = try await translations.replaceOrInsert(translation(hash: "fresh", document: document, target: "first", at: 1))
        XCTAssertNotNil(saved.id)
        let rows = try await count("translations")
        XCTAssertEqual(rows, 1)
        let found = try await translations.findCache(byHash: "fresh")
        XCTAssertEqual(found, saved)
    }

    func testReplaceOrInsertUpdatesInPlaceAndKeepsTheRowIdThatHighlightsPointAt() async throws {
        let document = try await makeDocumentId()
        let original = try await translations.insert(
            translation(hash: "retry", document: document, page: 2, source: "src", target: "truncated", model: "old-model", at: 1))
        let id = try XCTUnwrap(original.id)
        try await annotations.insertAll([annotation("bound", document: document, translation: id)])

        let corrected = translation(hash: "retry", document: document, page: 2, source: "src (cleaned)",
                                    target: "complete translation", model: "new-model", at: 50)
        let replaced = try await translations.replaceOrInsert(corrected)

        XCTAssertEqual(replaced.id, id, "the row id survives a retry")
        XCTAssertEqual(replaced.targetText, "complete translation")
        let rows = try await count("translations")
        XCTAssertEqual(rows, 1, "replaced in place, not duplicated")
        let storedFound = try await translations.findCache(byHash: "retry")
        let stored = try XCTUnwrap(storedFound)
        XCTAssertEqual(stored.id, id)
        XCTAssertEqual(stored.sourceText, "src (cleaned)")
        XCTAssertEqual(stored.targetText, "complete translation")
        XCTAssertEqual(stored.provider, "deepseek")
        XCTAssertEqual(stored.model, "new-model")
        XCTAssertEqual(stored.createdAt, at(50), "created_at is refreshed so the retry is the newest")

        // The highlight bound to the row now resolves to the corrected text.
        let boundText = try await database.writer.read { db in
            try String.fetchOne(db, sql: """
                SELECT t.target_text FROM annotations a JOIN translations t ON t.id = a.translation_id WHERE a.id = 'bound'
                """)
        }
        XCTAssertEqual(boundText, "complete translation")
    }

    func testReplaceOrInsertLeavesOtherDocumentsPagesAndHashesAlone() async throws {
        let a = try await makeDocumentId("a")
        let b = try await makeDocumentId("b")
        let target = try await translations.insert(translation(hash: "h", document: a, page: 1, target: "old", at: 1))
        let otherDocument = try await translations.insert(translation(hash: "h", document: b, page: 1, target: "b-old", at: 2))
        let otherPage = try await translations.insert(translation(hash: "h", document: a, page: 2, target: "p2-old", at: 3))
        let otherHash = try await translations.insert(translation(hash: "h2", document: a, page: 1, target: "h2-old", at: 4))
        let global = try await translations.insert(translation(hash: "h", document: nil, page: nil, target: "g-old", at: 5))
        let untouched = [otherDocument, otherPage, otherHash, global]

        let replaced = try await translations.replaceOrInsert(translation(hash: "h", document: a, page: 1, target: "new", at: 9))
        XCTAssertEqual(replaced.id, target.id)

        let all = try await database.writer.read { db in try TranslationRecord.order(Column("id")).fetchAll(db) }
        XCTAssertEqual(all.count, 5)
        XCTAssertEqual(all.first { $0.id == target.id }?.targetText, "new")
        for row in untouched {
            XCTAssertEqual(all.first { $0.id == row.id }, row, "row \(String(describing: row.id)) must be unchanged")
        }
    }

    func testReplaceOrInsertMatchesRowsWithoutADocumentOrPage() async throws {
        let first = try await translations.insert(translation(hash: "global", document: nil, page: nil, target: "v1", at: 1))
        let replaced = try await translations.replaceOrInsert(translation(hash: "global", document: nil, page: nil, target: "v2", at: 2))
        XCTAssertEqual(replaced.id, first.id)
        XCTAssertEqual(replaced.targetText, "v2")
        let rows = try await count("translations")
        XCTAssertEqual(rows, 1)
    }

    func testReplaceOrInsertRefreshesPreexistingDuplicatesAndReportsTheNewestId() async throws {
        let document = try await makeDocumentId()
        let older = try await translations.insert(translation(hash: "dup", document: document, target: "old-1", at: 1))
        let newer = try await translations.insert(translation(hash: "dup", document: document, target: "old-2", at: 2))
        let replaced = try await translations.replaceOrInsert(translation(hash: "dup", document: document, target: "fixed", at: 9))

        XCTAssertEqual(replaced.id, newer.id)
        let rows = try await database.writer.read { db in try TranslationRecord.order(Column("id")).fetchAll(db) }
        XCTAssertEqual(rows.map(\.id), [older.id, newer.id])
        XCTAssertEqual(rows.map(\.targetText), ["fixed", "fixed"], "no stale copy is left behind to be served from cache")
    }

    func testReplacedRowBecomesTheNewestCacheEntry() async throws {
        let a = try await makeDocumentId("a")
        let b = try await makeDocumentId("b")
        let inA = try await translations.insert(translation(hash: "h", document: a, target: "A-old", at: 100))
        _ = try await translations.insert(translation(hash: "h", document: b, target: "B", at: 200))
        let served = try await translations.findCache(byHash: "h")
        XCTAssertEqual(served?.targetText, "B")

        _ = try await translations.replaceOrInsert(translation(hash: "h", document: a, target: "A-fixed", at: 300))
        let afterRetry = try await translations.findCache(byHash: "h")
        XCTAssertEqual(afterRetry?.id, inA.id)
        XCTAssertEqual(afterRetry?.targetText, "A-fixed")
    }
}

// MARK: - Relationships on a fresh schema

final class RepositoryRelationshipTests: RepositoryTestCase {
    func testDeletingADocumentCascadesToItsAnnotationsAndTranslationsOnly() async throws {
        let a = try await makeDocumentId("a")
        let b = try await makeDocumentId("b")
        let tA = try await translations.insert(translation(hash: "ha", document: a))
        let tB = try await translations.insert(translation(hash: "hb", document: b))
        try await annotations.insertAll([
            annotation("a1", document: a, translation: tA.id),
            annotation("a2", group: "g", document: a, page: 1),
            annotation("b1", document: b, translation: tB.id),
        ])

        try await database.writer.write { db in try db.execute(sql: "DELETE FROM documents WHERE id = ?", arguments: [a]) }

        let listedA = try await annotations.list(forDocumentId: a)
        let listedB = try await annotations.list(forDocumentId: b)
        let cachedA = try await translations.findCache(byHash: "ha")
        let cachedB = try await translations.findCache(byHash: "hb")
        XCTAssertTrue(listedA.isEmpty)
        XCTAssertEqual(listedB.map(\.id), ["b1"])
        XCTAssertEqual(listedB.first?.translationId, tB.id)
        XCTAssertNil(cachedA)
        XCTAssertEqual(cachedB?.id, tB.id)
    }

    func testDeletingATranslationKeepsTheHighlightAndClearsItsBinding() async throws {
        let document = try await makeDocumentId()
        let saved = try await translations.insert(translation(document: document))
        try await annotations.insertAll([annotation("h", document: document, translation: saved.id)])

        try await database.writer.write { db in try db.execute(sql: "DELETE FROM translations WHERE id = ?", arguments: [saved.id]) }

        let listed = try await annotations.list(forDocumentId: document)
        XCTAssertEqual(listed.map(\.id), ["h"])
        XCTAssertNil(listed.first?.translationId)
    }

    func testCleanFreshDatabasePassesIntegrityAndForeignKeyChecksAfterMixedWrites() async throws {
        let document = try await makeDocumentId()
        let saved = try await translations.insert(translation(document: document))
        try await annotations.insertAll([annotation("a", document: document, translation: saved.id)])
        try await annotations.delete(groupId: "a")
        _ = try await translations.replaceOrInsert(translation(document: document, target: "again", at: 3))
        let (integrity, violations) = try await database.writer.read { db in
            (try DatabaseInspector.integrityCheck(db), try DatabaseInspector.foreignKeyViolations(db).count)
        }
        XCTAssertEqual(integrity, ["ok"])
        XCTAssertEqual(violations, 0)
    }
}

// MARK: - text_hash determinism

/// `text_hash` is `TranslationService.cacheKey`: SHA-256 over cleaned text, target language and
/// provider/model (design §4.3 rule 6). It is persisted, so its exact value is a compatibility contract.
@MainActor
final class TranslationCacheKeyTests: XCTestCase {
    func testKeyIsDeterministicLowercaseHexSHA256() {
        let key = TranslationService.cacheKey(cleaned: "Attention is all you need.", target: "简体中文", model: "deepseek-chat")
        XCTAssertEqual(key, TranslationService.cacheKey(cleaned: "Attention is all you need.", target: "简体中文", model: "deepseek-chat"))
        XCTAssertEqual(key.count, 64)
        XCTAssertNotNil(key.range(of: "^[0-9a-f]{64}$", options: .regularExpression))
    }

    func testKeyFormatIsPinnedSoExistingCacheRowsKeepHitting() {
        // sha256("Attention is all you need." + U+001F + "简体中文" + U+001F + "deepseek/deepseek-chat")
        XCTAssertEqual(TranslationService.cacheKey(cleaned: "Attention is all you need.", target: "简体中文", model: "deepseek-chat"),
                       "7d7359be8aa80a704856b4c10dddcc7313bba34a555a957e9fd0929a93a9a6b2")
        // sha256(U+001F U+001F "deepseek/m")
        XCTAssertEqual(TranslationService.cacheKey(cleaned: "", target: "", model: "m"),
                       "6cc94e68b4d0d1ce02ad6ef3f06ec5ceb1755757b4fe13b51336530f970cd9c2")
    }

    func testEveryInputChangesTheKey() {
        let base = TranslationService.cacheKey(cleaned: "text", target: "简体中文", model: "m1")
        XCTAssertNotEqual(base, TranslationService.cacheKey(cleaned: "text ", target: "简体中文", model: "m1"))
        XCTAssertNotEqual(base, TranslationService.cacheKey(cleaned: "Text", target: "简体中文", model: "m1"))
        XCTAssertNotEqual(base, TranslationService.cacheKey(cleaned: "text", target: "English", model: "m1"))
        XCTAssertNotEqual(base, TranslationService.cacheKey(cleaned: "text", target: "简体中文", model: "m2"))
    }

    func testFieldBoundariesDoNotBleedIntoEachOther() {
        // "ab" + "c" must not collide with "a" + "bc" — the unit separator keeps the fields apart.
        XCTAssertNotEqual(TranslationService.cacheKey(cleaned: "ab", target: "c", model: "m"),
                          TranslationService.cacheKey(cleaned: "a", target: "bc", model: "m"))
        XCTAssertNotEqual(TranslationService.cacheKey(cleaned: "a", target: "b", model: "cm"),
                          TranslationService.cacheKey(cleaned: "a", target: "bc", model: "m"))
    }
}
