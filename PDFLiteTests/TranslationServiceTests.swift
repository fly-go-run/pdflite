import GRDB
import PDFKit
import XCTest

/// End-to-end behaviour of `TranslationService` (config → stream → cache) on a temp database, a
/// temp config file and a stubbed endpoint. Nothing here touches the user's real data or key.
@MainActor
final class TranslationServiceTests: XCTestCase {
    private var directory: URL!
    private var database: Database!
    private var repository: TranslationRepository!
    private var configURL: URL!
    private var services: [TranslationService] = []

    private let source = "Attention is all you need."

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        database = Database(url: directory.appendingPathComponent("test.sqlite"))
        repository = TranslationRepository(database: database)
        configURL = directory.appendingPathComponent("config.json")
    }

    override func tearDown() async throws {
        for service in services { service.reset() }
        services = []
        try FileManager.default.removeItem(at: directory)
    }

    // MARK: - Helpers

    private func makeService(endpoint: URL, apiKey: String = "sk-test-A") throws -> TranslationService {
        try ConfigLoader.save(TranslationConfig(apiKey: apiKey, endpoint: endpoint, model: "test-model"),
                              to: configURL)
        let service = TranslationService(session: StubURLProtocol.makeSession(),
                                         repository: repository,
                                         configURL: configURL)
        services.append(service)
        return service
    }

    private func snapshot() -> SelectionSnapshot {
        SelectionSnapshot(
            pages: [PageSelection(pageIndex: 0, page: PDFPage(), lineRects: [], text: source)],
            rawText: source
        )
    }

    private var cacheHash: String {
        TranslationService.cacheKey(cleaned: TextCleaner.clean(source),
                                    target: TranslationConfig.defaultTargetLanguage,
                                    model: "test-model")
    }

    private func rows() async throws -> [TranslationRecord] {
        let hash = cacheHash
        return try await database.writer.read { db in
            try TranslationRecord.filter(Column("text_hash") == hash).order(Column("id")).fetchAll(db)
        }
    }

    /// Rewrites `old` → `new` inside config.json without changing its size, inode or mtime — an
    /// edit the file stamp cannot see.
    private func editConfigInvisibly(replacing old: String, with new: String) throws {
        XCTAssertEqual(old.utf8.count, new.utf8.count)
        // Restore the exact timespec: round-tripping through Date can shift the nanoseconds.
        var before = stat()
        XCTAssertEqual(stat(configURL.path, &before), 0)
        let contents = try String(contentsOf: configURL, encoding: .utf8)
            .replacingOccurrences(of: old, with: new)
        let handle = try FileHandle(forWritingTo: configURL)
        try handle.write(contentsOf: Data(contents.utf8))
        try handle.close()
        var times = [before.st_atimespec, before.st_mtimespec]
        XCTAssertEqual(utimensat(AT_FDCWD, configURL.path, &times, 0), 0)
    }

    private func documentId() async throws -> Int64 {
        let record = try await DocumentRepository(database: database)
            .upsert(fileHash: "doc-hash", fileURL: directory.appendingPathComponent("a.pdf"),
                    title: "A", pageCount: 1)
        return try XCTUnwrap(record.id)
    }

    private func finished(_ service: TranslationService) async throws {
        try await pollUntil { service.current?.isStreaming == false }
        XCTAssertEqual(service.current?.isStreaming, false, "Timed out waiting for the translation to end")
    }

    private func authorization(_ endpoint: URL) -> String? {
        StubURLProtocol.requests(for: endpoint).last?.value(forHTTPHeaderField: "Authorization")
    }

    private let complete = StubURLProtocol.Script(chunks: [SSE.delta("注意力"), SSE.delta("就是一切"),
                                                            SSE.finish("stop"), SSE.done])

    // MARK: - Persistence rules

    func testCompleteStreamIsPersistedAndServedFromCacheNextTime() async throws {
        let endpoint = StubURLProtocol.register(complete)
        let service = try makeService(endpoint: endpoint)
        let saved = SavedRecords()

        service.translate(snapshot: snapshot(), documentId: nil) { saved.append($0) }
        try await finished(service)
        try await pollUntil { saved.count == 1 }

        XCTAssertNil(service.current?.errorMessage)
        XCTAssertEqual(service.current?.partial, "注意力就是一切")
        let stored = try await rows()
        XCTAssertEqual(stored.map(\.targetText), ["注意力就是一切"])
        XCTAssertEqual(stored.first?.model, "test-model")

        service.translate(snapshot: snapshot(), documentId: nil)
        try await pollUntil { service.current?.fromCache == true }
        XCTAssertEqual(service.current?.fromCache, true)
        XCTAssertEqual(StubURLProtocol.requests(for: endpoint).count, 1, "A cache hit must not hit the network")
    }

    func testStreamWithoutTerminalMarkerIsNotPersistedOrCached() async throws {
        let endpoint = StubURLProtocol.register(.init(chunks: [SSE.delta("注意力")]))
        let service = try makeService(endpoint: endpoint)
        let saved = SavedRecords()

        service.translate(snapshot: snapshot(), documentId: nil) { saved.append($0) }
        try await finished(service)
        try await Task.sleep(for: .milliseconds(150))

        XCTAssertTrue(service.current?.errorMessage?.contains("中断") == true,
                      "Got \(String(describing: service.current?.errorMessage))")
        XCTAssertEqual(service.current?.partial, "注意力", "The partial text stays visible next to the error")
        XCTAssertTrue(service.canRetry)
        let stored = try await rows()
        XCTAssertTrue(stored.isEmpty, "A truncated stream must not become a cached translation")
        XCTAssertEqual(saved.count, 0, "onSaved must not fire for an incomplete stream")
    }

    func testLengthTruncationIsNotPersisted() async throws {
        let endpoint = StubURLProtocol.register(.init(chunks: [SSE.delta("很长很长"), SSE.finish("length"), SSE.done]))
        let service = try makeService(endpoint: endpoint)

        service.translate(snapshot: snapshot(), documentId: nil)
        try await finished(service)
        try await Task.sleep(for: .milliseconds(150))

        XCTAssertTrue(service.current?.errorMessage?.contains("长度上限") == true)
        let stored = try await rows()
        XCTAssertTrue(stored.isEmpty)
    }

    func testCancellingMidStreamSavesNothing() async throws {
        let endpoint = StubURLProtocol.register(.init(chunks: [SSE.delta("开头")], ending: .hang))
        let service = try makeService(endpoint: endpoint)
        let saved = SavedRecords()

        service.translate(snapshot: snapshot(), documentId: nil) { saved.append($0) }
        try await pollUntil { service.current?.partial == "开头" }
        XCTAssertEqual(service.current?.partial, "开头")

        service.cancelInFlight()
        try await pollUntil { StubURLProtocol.wasStopped(endpoint) }
        try await Task.sleep(for: .milliseconds(150))

        XCTAssertTrue(StubURLProtocol.wasStopped(endpoint), "The request must be torn down on cancel")
        XCTAssertEqual(service.current?.isStreaming, false)
        let stored = try await rows()
        XCTAssertTrue(stored.isEmpty)
        XCTAssertEqual(saved.count, 0)
    }

    func testJSONErrorBodyWith200ShowsServerMessageInsteadOfEmptyOutput() async throws {
        let body = Data(#"{"error":{"message":"Model Not Exist"}}"#.utf8)
        let endpoint = StubURLProtocol.register(.init(headers: ["Content-Type": "application/json"], chunks: [body]))
        let service = try makeService(endpoint: endpoint)

        service.translate(snapshot: snapshot(), documentId: nil)
        try await finished(service)

        XCTAssertEqual(service.current?.errorMessage, "Model Not Exist")
    }

    // MARK: - Retry

    func testRetryAfterTruncationFetchesAFreshTranslation() async throws {
        let endpoint = StubURLProtocol.register(.init(chunks: [SSE.delta("半截")]))
        let service = try makeService(endpoint: endpoint)
        let saved = SavedRecords()

        service.translate(snapshot: snapshot(), documentId: nil) { saved.append($0) }
        try await finished(service)
        XCTAssertTrue(service.canRetry)

        StubURLProtocol.update(endpoint, to: complete)
        service.retryLast()
        try await pollUntil { saved.count == 1 }

        XCTAssertEqual(service.current?.partial, "注意力就是一切")
        XCTAssertNil(service.current?.errorMessage)
        let stored = try await rows()
        XCTAssertEqual(stored.map(\.targetText), ["注意力就是一切"])
    }

    func testRetryBypassesTheCacheAndReplacesTheStoredRow() async throws {
        let endpoint = StubURLProtocol.register(complete)
        let service = try makeService(endpoint: endpoint)
        let docId = try await documentId()

        // A stale row for this document, as an older build could have left behind.
        let stale = try await repository.insert(TranslationRecord(
            id: nil, documentId: docId, pageIndex: 0, textHash: cacheHash, sourceText: source,
            targetText: "旧的半截译文", provider: TranslationConfig.provider, model: "test-model",
            createdAt: Date(timeIntervalSinceNow: -3600)))

        let saved = SavedRecords()
        service.translate(snapshot: snapshot(), documentId: docId) { saved.append($0) }
        try await pollUntil { saved.count == 1 }
        XCTAssertEqual(service.current?.fromCache, true, "Normal translation still serves the cache")
        XCTAssertEqual(service.current?.partial, "旧的半截译文")
        XCTAssertEqual(StubURLProtocol.requests(for: endpoint).count, 0)

        service.retryLast()
        try await pollUntil { saved.count == 2 }

        XCTAssertEqual(StubURLProtocol.requests(for: endpoint).count, 1, "Retry must go to the network")
        XCTAssertEqual(service.current?.fromCache, false)
        XCTAssertEqual(service.current?.partial, "注意力就是一切")

        let stored = try await rows()
        XCTAssertEqual(stored.count, 1, "The stale row is replaced, not duplicated")
        XCTAssertEqual(stored.first?.id, stale.id, "Row id is kept so bound highlights follow the new text")
        XCTAssertEqual(stored.first?.targetText, "注意力就是一切")
        XCTAssertEqual(saved.records.last?.id, stale.id)

        // The refreshed row is what the next cache lookup serves.
        let cached = try await repository.findCache(byHash: cacheHash)
        XCTAssertEqual(cached?.targetText, "注意力就是一切")
    }

    func testRetryReplacesUnboundRowsToo() async throws {
        let endpoint = StubURLProtocol.register(complete)
        let service = try makeService(endpoint: endpoint)
        _ = try await repository.insert(TranslationRecord(
            id: nil, documentId: nil, pageIndex: 0, textHash: cacheHash, sourceText: source,
            targetText: "旧", provider: TranslationConfig.provider, model: "test-model", createdAt: Date()))

        let saved = SavedRecords()
        service.translate(snapshot: snapshot(), documentId: nil) { saved.append($0) }
        try await pollUntil { saved.count == 1 }
        service.retryLast()
        try await pollUntil { saved.count == 2 }

        let stored = try await rows()
        XCTAssertEqual(stored.map(\.targetText), ["注意力就是一切"])
    }

    func testRetryStillBindsTheResultToTheOriginalHandler() async throws {
        let endpoint = StubURLProtocol.register(.init(status: 503, chunks: []))
        let service = try makeService(endpoint: endpoint)
        let saved = SavedRecords()

        service.translate(snapshot: snapshot(), documentId: nil) { saved.append($0) }
        try await finished(service)
        XCTAssertEqual(saved.count, 0)

        StubURLProtocol.update(endpoint, to: complete)
        service.retryLast()
        try await pollUntil { saved.count == 1 }
        XCTAssertEqual(saved.count, 1, "Auto-translate-on-highlight binds through onSaved; retry must keep it")
    }

    // MARK: - Config freshness

    func testEditedConfigIsPickedUpByTheNextAttempt() async throws {
        let endpoint = StubURLProtocol.register(.init(status: 401, chunks: [Data(#"{"error":{"message":"bad key"}}"#.utf8)]))
        let service = try makeService(endpoint: endpoint, apiKey: "sk-test-A")

        service.translate(snapshot: snapshot(), documentId: nil)
        try await finished(service)
        XCTAssertEqual(authorization(endpoint), "Bearer sk-test-A")
        XCTAssertTrue(service.current?.errorMessage?.contains("拒绝认证") == true)

        // The user fixes the file by hand (no Settings notification involved).
        try ConfigLoader.save(TranslationConfig(apiKey: "sk-test-B-longer", endpoint: endpoint, model: "test-model"),
                              to: configURL)
        StubURLProtocol.update(endpoint, to: complete)
        service.retryLast()
        try await pollUntil { service.current?.partial == "注意力就是一切" }

        XCTAssertEqual(authorization(endpoint), "Bearer sk-test-B-longer")
    }

    func testAuthFailureDropsTheCachedConfigEvenWhenTheFileLooksUnchanged() async throws {
        let endpoint = StubURLProtocol.register(.init(status: 401, chunks: []))
        let service = try makeService(endpoint: endpoint, apiKey: "sk-test-AAAA")

        service.translate(snapshot: snapshot(), documentId: nil)
        try await finished(service)
        XCTAssertEqual(authorization(endpoint), "Bearer sk-test-AAAA")

        // Same size, same inode, same mtime: only the 401 handling can make the next read fresh.
        try editConfigInvisibly(replacing: "sk-test-AAAA", with: "sk-test-BBBB")

        StubURLProtocol.update(endpoint, to: complete)
        service.retryLast()
        try await pollUntil { service.current?.partial == "注意力就是一切" }

        XCTAssertEqual(authorization(endpoint), "Bearer sk-test-BBBB")
    }

    func testSettingsNotificationStillInvalidatesTheCache() async throws {
        let endpoint = StubURLProtocol.register(complete)
        let service = try makeService(endpoint: endpoint, apiKey: "sk-test-AAAA")

        service.translate(snapshot: snapshot(), documentId: nil)
        try await finished(service)
        XCTAssertEqual(authorization(endpoint), "Bearer sk-test-AAAA")

        // An edit the stamp can't see, announced the way Settings announces a save.
        try editConfigInvisibly(replacing: "sk-test-AAAA", with: "sk-test-CCCC")
        NotificationCenter.default.post(name: ConfigLoader.configChangedNotification, object: nil)
        try await Task.sleep(for: .milliseconds(100))

        service.translate(snapshot: snapshot(), documentId: nil, bypassCache: true)
        try await pollUntil { StubURLProtocol.requests(for: endpoint).count == 2 }
        XCTAssertEqual(authorization(endpoint), "Bearer sk-test-CCCC")
    }

    func testMissingConfigFileReportsAnErrorInsteadOfUsingAStaleCache() async throws {
        let endpoint = StubURLProtocol.register(complete)
        let service = try makeService(endpoint: endpoint)
        service.translate(snapshot: snapshot(), documentId: nil)
        try await finished(service)
        XCTAssertNil(service.current?.errorMessage)

        try FileManager.default.removeItem(at: configURL)
        service.translate(snapshot: snapshot(), documentId: nil, bypassCache: true)

        XCTAssertNotNil(service.current?.errorMessage)
        XCTAssertEqual(service.current?.isStreaming, false)
    }
}

/// Collects `onSaved` callbacks (they arrive on the main actor, but keep the type Sendable).
private final class SavedRecords: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [TranslationRecord] = []

    var count: Int { lock.withLock { stored.count } }
    var records: [TranslationRecord] { lock.withLock { stored } }
    func append(_ record: TranslationRecord) { lock.withLock { stored.append(record) } }
}
