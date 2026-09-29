import Dispatch
import GRDB
import XCTest

/// The repositories share one `DatabasePool`: writes are serialised, reads run concurrently with
/// them (WAL). These tests hammer that from many tasks at once and check nothing errors, nothing
/// is lost and nothing is read half-written.
final class RepositoryConcurrencyTests: RepositoryTestCase {
    func testFiftyParallelUpsertsWithInterleavedReadsLoseNoRows() async throws {
        let documents = self.documents!
        let expected = 50

        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<expected {
                group.addTask {
                    let url = URL(fileURLWithPath: "/tmp/pdflite-tests/parallel-\(index).pdf")
                    let record = try await documents.upsert(fileHash: "parallel-\(index)", fileURL: url,
                                                            title: "Paper \(index)", pageCount: index + 1)
                    XCTAssertNotNil(record.id)
                }
                group.addTask {
                    // Readers race the writers: a hit must be a complete row, a miss is fine.
                    if let found = try await documents.find(byHash: "parallel-\(index)") {
                        XCTAssertEqual(found.title, "Paper \(index)")
                        XCTAssertEqual(found.pageCount, index + 1)
                    }
                    _ = try await documents.find(byURL: URL(fileURLWithPath: "/tmp/pdflite-tests/parallel-\(index).pdf"))
                }
            }
            try await group.waitForAll()
        }

        let rows = try await count("documents")
        XCTAssertEqual(rows, expected)
        let distinctIds = try await database.writer.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(DISTINCT id) FROM documents") ?? 0
        }
        XCTAssertEqual(distinctIds, expected)
        for index in 0..<expected {
            let found = try await documents.find(byHash: "parallel-\(index)")
            XCTAssertEqual(found?.pageCount, index + 1, "row \(index) missing or stale")
        }
    }

    func testParallelUpsertsOfTheSameDocumentConvergeOnOneRow() async throws {
        let documents = self.documents!
        let ids = try await withThrowingTaskGroup(of: Int64?.self) { group -> [Int64?] in
            for index in 0..<30 {
                group.addTask {
                    try await documents.upsert(fileHash: "one-document",
                                               fileURL: URL(fileURLWithPath: "/tmp/pdflite-tests/one-\(index).pdf"),
                                               title: "Opened \(index) times", pageCount: 7).id
                }
            }
            var collected: [Int64?] = []
            for try await id in group { collected.append(id) }
            return collected
        }
        XCTAssertEqual(Set(ids.map { $0 ?? -1 }).count, 1, "every racer must get the same row id")
        XCTAssertFalse(ids.contains { $0 == nil })
        let rows = try await count("documents")
        XCTAssertEqual(rows, 1)
        let final = try await documents.find(byHash: "one-document")
        XCTAssertEqual(final?.pageCount, 7)
        XCTAssertTrue(final?.fileURL.hasPrefix("/tmp/pdflite-tests/one-") == true, "last writer wins, fully")
    }

    func testReadingStateWritesAreAtomicAgainstConcurrentReads() async throws {
        let id = try await makeDocumentId()
        let documents = self.documents!
        // Every write keeps page == y == scale * 10 so a torn read is detectable.
        try await withThrowingTaskGroup(of: Void.self) { group in
            for page in 1...40 {
                group.addTask {
                    let location = ReadingLocation(pageIndex: page, point: CGPoint(x: 0, y: Double(page)),
                                                   scale: Double(page) / 10, autoScales: false, displayMode: page % 4)
                    try await documents.updateReadingState(documentId: id, location: location)
                }
                group.addTask {
                    guard let record = try await documents.find(byHash: "hash-paper") else {
                        XCTFail("row vanished")
                        return
                    }
                    if record.lastPage != 0 {
                        XCTAssertEqual(record.lastScrollY, Double(record.lastPage), "torn read")
                        XCTAssertEqual(record.lastZoom, Double(record.lastPage) / 10, "torn read")
                    }
                }
            }
            try await group.waitForAll()
        }
        let final = try await documents.find(byHash: "hash-paper")
        XCTAssertEqual(final?.lastScrollY, Double(final?.lastPage ?? -1))
    }

    func testSynchronousFlushesFromManyThreadsAreAllApplied() async throws {
        let id = try await makeDocumentId()
        let documents = self.documents!
        let failures = FailureCollector()
        DispatchQueue.concurrentPerform(iterations: 40) { index in
            do {
                try documents.updateReadingStateNow(documentId: id, location: ReadingLocation(pageIndex: index))
            } catch {
                failures.record("\(error)")
            }
        }
        XCTAssertEqual(failures.all, [])
        let final = try await documents.find(byHash: "hash-paper")
        XCTAssertTrue((0..<40).contains(try XCTUnwrap(final).lastPage))
    }

    func testParallelAnnotationInsertsDeletesAndListsStayConsistent() async throws {
        let document = try await makeDocumentId()
        let annotations = self.annotations!

        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<40 {
                group.addTask {
                    // A two-page highlight is inserted atomically: a reader never sees half of it.
                    try await annotations.insertAll([
                        RepositoryTestCase.makeAnnotation("a\(index)-1", group: "g\(index)", document: document, page: 1, at: Double(index)),
                        RepositoryTestCase.makeAnnotation("a\(index)-2", group: "g\(index)", document: document, page: 2, at: Double(index)),
                    ])
                }
                group.addTask {
                    let listed = try await annotations.list(forDocumentId: document)
                    var perGroup: [String: Int] = [:]
                    for record in listed { perGroup[record.groupId, default: 0] += 1 }
                    XCTAssertTrue(perGroup.values.allSatisfy { $0 == 2 }, "saw a partially inserted highlight: \(perGroup)")
                }
                if index % 2 == 0 {
                    group.addTask {
                        // Deleting a group that may not exist yet is a harmless no-op.
                        try await annotations.delete(groupId: "g\(index)")
                    }
                }
            }
            try await group.waitForAll()
        }

        // Deletes that raced ahead of their insert removed nothing; the rest cleaned up whole groups.
        let listed = try await annotations.list(forDocumentId: document)
        var perGroup: [String: Int] = [:]
        for record in listed { perGroup[record.groupId, default: 0] += 1 }
        XCTAssertTrue(perGroup.values.allSatisfy { $0 == 2 }, "\(perGroup)")
        let odd = (0..<40).filter { $0 % 2 == 1 }.map { "g\($0)" }
        XCTAssertTrue(Set(odd).isSubset(of: Set(perGroup.keys)), "no odd-numbered highlight may be lost")
    }

    func testParallelTranslationInsertsAndRetriesKeepHistoryAndConverge() async throws {
        let document = try await makeDocumentId()
        let translations = self.translations!

        try await withThrowingTaskGroup(of: Void.self) { group in
            // 20 distinct cache entries...
            for index in 0..<20 {
                group.addTask {
                    _ = try await translations.insert(RepositoryTestCase.makeTranslation(hash: "unique-\(index)", document: document,
                                                                       target: "t\(index)", at: Double(index)))
                }
                group.addTask { _ = try await translations.findCache(byHash: "unique-\(index)") }
            }
            // ...and 20 racing retries of the same (document, page, hash): they must converge on one row.
            for index in 0..<20 {
                group.addTask {
                    _ = try await translations.replaceOrInsert(RepositoryTestCase.makeTranslation(hash: "retry", document: document, page: 3,
                                                                                 target: "attempt \(index)", at: Double(index)))
                }
            }
            try await group.waitForAll()
        }

        let unique = try await database.writer.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM translations WHERE text_hash LIKE 'unique-%'") ?? -1
        }
        let retries = try await database.writer.read { db in
            try TranslationRecord.filter(Column("text_hash") == "retry").fetchAll(db)
        }
        XCTAssertEqual(unique, 20)
        XCTAssertEqual(retries.count, 1, "replaceOrInsert is check-and-write in one transaction")
        XCTAssertTrue(retries[0].targetText.hasPrefix("attempt "))
    }

    func testDatabaseStaysHealthyAfterTheStorm() async throws {
        // Interleave every write path once more, then run the integrity checks.
        let documents = self.documents!, annotations = self.annotations!, translations = self.translations!
        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<25 {
                group.addTask {
                    let record = try await documents.upsert(fileHash: "storm-\(index)",
                                                            fileURL: URL(fileURLWithPath: "/tmp/pdflite-tests/storm-\(index).pdf"),
                                                            title: nil, pageCount: 3)
                    let id = try XCTUnwrap(record.id)
                    let saved = try await translations.insert(RepositoryTestCase.makeTranslation(hash: "storm-\(index)", document: id))
                    try await annotations.insertAll([RepositoryTestCase.makeAnnotation("storm-a-\(index)", document: id, translation: saved.id)])
                    try await documents.updateReadingState(documentId: id, location: ReadingLocation(pageIndex: 1))
                }
            }
            try await group.waitForAll()
        }
        let (integrity, violations, docs, notes, texts) = try await database.writer.read { db in
            (try DatabaseInspector.integrityCheck(db),
             try DatabaseInspector.foreignKeyViolations(db).count,
             try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM documents") ?? -1,
             try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM annotations") ?? -1,
             try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM translations") ?? -1)
        }
        XCTAssertEqual(integrity, ["ok"])
        XCTAssertEqual(violations, 0)
        XCTAssertEqual([docs, notes, texts], [25, 25, 25])
    }
}

private final class FailureCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var messages: [String] = []
    func record(_ message: String) { lock.withLock { messages.append(message) } }
    var all: [String] { lock.withLock { messages } }
}
