import GRDB
import PDFKit
import XCTest

/// "重新翻译": a finished translation — typically a cached row an older build saved from a
/// truncated stream — can be re-fetched, replacing the stored row in place. Temp database, temp
/// config file, stubbed endpoint; no real key, network or user data.
@MainActor
final class RetranslateTests: XCTestCase {
    private var directory: URL!
    private var database: Database!
    private var repository: TranslationRepository!
    private var configURL: URL!
    private var services: [TranslationService] = []
    private var sessions: [DocumentSession] = []

    private let source = "Attention is all you need."
    private let complete = StubURLProtocol.Script(chunks: [SSE.delta("注意力"), SSE.delta("就是一切"),
                                                            SSE.finish("stop"), SSE.done])

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
        for session in sessions {
            session.translation.reset()
            session.closeDocument()
            DocumentOpener.unregister(session)
        }
        sessions = []
        try FileManager.default.removeItem(at: directory)
    }

    // MARK: - Helpers

    private func makeService(endpoint: URL) throws -> TranslationService {
        try ConfigLoader.save(TranslationConfig(apiKey: "sk-test-A", endpoint: endpoint, model: "test-model"),
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

    /// A row as an older build could have left it: complete-looking, actually cut short.
    private func insertStaleRow(documentId: Int64?) async throws -> TranslationRecord {
        try await repository.insert(TranslationRecord(
            id: nil, documentId: documentId, pageIndex: 0, textHash: cacheHash, sourceText: source,
            targetText: "旧的半截译", provider: TranslationConfig.provider, model: "test-model",
            createdAt: Date(timeIntervalSinceNow: -3600)))
    }

    // MARK: - canRetranslate truth table

    func testNothingRequestedYetCannotBeRetranslated() throws {
        let service = try makeService(endpoint: StubURLProtocol.register(complete))
        XCTAssertNil(service.current)
        XCTAssertFalse(service.canRetranslate)
        XCTAssertFalse(service.canRetry)
    }

    func testStreamingCannotBeRetranslated() async throws {
        let endpoint = StubURLProtocol.register(.init(chunks: [SSE.delta("开头")], ending: .hang))
        let service = try makeService(endpoint: endpoint)

        service.translate(snapshot: snapshot(), documentId: nil)
        XCTAssertEqual(service.current?.isStreaming, true)
        XCTAssertFalse(service.canRetranslate, "Nothing finished yet — even before the first token")

        try await pollUntil { service.current?.partial == "开头" }
        XCTAssertEqual(service.current?.isStreaming, true)
        XCTAssertFalse(service.canRetranslate, "Text has arrived, but the stream is still running")

        // Guard, not just a hidden button: the command itself must refuse mid-stream.
        service.retranslate()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(StubURLProtocol.requests(for: endpoint).count, 1, "No second request while streaming")
    }

    func testFinishedTranslationCanBeRetranslated() async throws {
        let service = try makeService(endpoint: StubURLProtocol.register(complete))

        service.translate(snapshot: snapshot(), documentId: nil)
        try await finished(service)

        XCTAssertNil(service.current?.errorMessage)
        XCTAssertTrue(service.canRetranslate)
        XCTAssertFalse(service.canRetry, "The two are exclusive: 重试 is for errors, 重新翻译 for results")
    }

    func testCacheHitCanBeRetranslated() async throws {
        let service = try makeService(endpoint: StubURLProtocol.register(complete))
        _ = try await insertStaleRow(documentId: nil)

        service.translate(snapshot: snapshot(), documentId: nil)
        try await pollUntil { service.current?.fromCache == true }

        XCTAssertEqual(service.current?.fromCache, true)
        XCTAssertTrue(service.canRetranslate, "A cached translation is exactly what one re-translates")
    }

    func testErrorsCannotBeRetranslatedButCanBeRetried() async throws {
        let service = try makeService(endpoint: StubURLProtocol.register(.init(status: 503, chunks: [])))

        service.translate(snapshot: snapshot(), documentId: nil)
        try await finished(service)

        XCTAssertNotNil(service.current?.errorMessage)
        XCTAssertFalse(service.canRetranslate)
        XCTAssertTrue(service.canRetry)
    }

    func testTruncatedStreamWithVisibleTextIsAnErrorNotAResult() async throws {
        // Partial text next to an error: the Inspector offers 重试 there, never 重新翻译.
        let service = try makeService(endpoint: StubURLProtocol.register(.init(chunks: [SSE.delta("半截")])))

        service.translate(snapshot: snapshot(), documentId: nil)
        try await finished(service)

        XCTAssertEqual(service.current?.partial, "半截")
        XCTAssertFalse(service.canRetranslate)
        XCTAssertTrue(service.canRetry)
    }

    func testMissingConfigurationCannotBeRetranslated() throws {
        let service = TranslationService(session: StubURLProtocol.makeSession(), repository: repository,
                                         configURL: directory.appendingPathComponent("absent.json"))
        services.append(service)

        service.translate(snapshot: snapshot(), documentId: nil)

        XCTAssertNotNil(service.current?.errorMessage)
        XCTAssertFalse(service.canRetranslate)
    }

    func testCancelledStreamIsRetranslatableOnlyWhenSomeTextArrived() async throws {
        // Cancelling keeps what streamed so far as a finished-looking result (no error), which is a
        // fine thing to re-run; a cancel before any text is reported as "已取消" and is not.
        let endpoint = StubURLProtocol.register(.init(chunks: [SSE.delta("开头")], ending: .hang))
        let service = try makeService(endpoint: endpoint)
        service.translate(snapshot: snapshot(), documentId: nil)
        try await pollUntil { service.current?.partial == "开头" }
        service.cancelInFlight()
        XCTAssertNil(service.current?.errorMessage)
        XCTAssertTrue(service.canRetranslate)

        let silent = StubURLProtocol.register(.init(chunks: [], ending: .hang))
        let second = try makeService(endpoint: silent)
        second.translate(snapshot: snapshot(), documentId: nil)
        second.cancelInFlight()
        XCTAssertEqual(second.current?.errorMessage, "已取消")
        XCTAssertFalse(second.canRetranslate)
    }

    func testResetForgetsTheRequest() async throws {
        let service = try makeService(endpoint: StubURLProtocol.register(complete))
        service.translate(snapshot: snapshot(), documentId: nil)
        try await finished(service)
        XCTAssertTrue(service.canRetranslate)

        service.reset()

        XCTAssertNil(service.current)
        XCTAssertFalse(service.canRetranslate)
    }

    // MARK: - Behaviour

    func testRetranslateOfACachedTranslationMakesExactlyOneRequestAndReplacesTheRowInPlace() async throws {
        let endpoint = StubURLProtocol.register(complete)
        let service = try makeService(endpoint: endpoint)
        let docId = try await documentId()
        let stale = try await insertStaleRow(documentId: docId)

        let saved = SavedRows()
        service.translate(snapshot: snapshot(), documentId: docId) { saved.append($0) }
        try await pollUntil { saved.count == 1 }
        XCTAssertEqual(service.current?.fromCache, true)
        XCTAssertEqual(service.current?.partial, "旧的半截译")
        XCTAssertEqual(StubURLProtocol.requests(for: endpoint).count, 0, "Sanity: the cache row was served")
        XCTAssertTrue(service.canRetranslate)

        service.retranslate()
        try await pollUntil { saved.count == 2 }
        // A late duplicate request would show up shortly after the row landed.
        try await Task.sleep(for: .milliseconds(100))

        XCTAssertEqual(StubURLProtocol.requests(for: endpoint).count, 1,
                       "Re-translating must hit the network once, cache row or not")
        XCTAssertEqual(service.current?.fromCache, false)
        XCTAssertEqual(service.current?.partial, "注意力就是一切")

        let stored = try await rows()
        XCTAssertEqual(stored.count, 1, "The stale row is replaced, not duplicated")
        XCTAssertEqual(stored.first?.id, stale.id, "Row id is kept so a bound highlight follows the new text")
        XCTAssertEqual(stored.first?.targetText, "注意力就是一切")
        XCTAssertEqual(saved.records.last?.id, stale.id)

        // The corrected text is what every later lookup serves.
        service.translate(snapshot: snapshot(), documentId: docId)
        try await pollUntil { service.current?.fromCache == true && service.current?.isStreaming == false }
        XCTAssertEqual(service.current?.partial, "注意力就是一切")
        XCTAssertEqual(StubURLProtocol.requests(for: endpoint).count, 1)
    }

    func testRetranslateAfterAFreshStreamAlsoReplacesInPlace() async throws {
        let endpoint = StubURLProtocol.register(complete)
        let service = try makeService(endpoint: endpoint)

        let saved = SavedRows()
        service.translate(snapshot: snapshot(), documentId: nil) { saved.append($0) }
        try await pollUntil { saved.count == 1 }
        let firstID = try await rows().first?.id

        StubURLProtocol.update(endpoint, to: .init(chunks: [SSE.delta("全新译文"), SSE.finish("stop"), SSE.done]))
        service.retranslate()
        try await pollUntil { saved.count == 2 }

        XCTAssertEqual(StubURLProtocol.requests(for: endpoint).count, 2)
        let stored = try await rows()
        XCTAssertEqual(stored.map(\.targetText), ["全新译文"])
        XCTAssertEqual(stored.first?.id, firstID)
    }

    func testRetranslateIsANoOpForAnErrorState() async throws {
        let endpoint = StubURLProtocol.register(.init(status: 503, chunks: []))
        let service = try makeService(endpoint: endpoint)

        service.translate(snapshot: snapshot(), documentId: nil)
        try await finished(service)
        let before = StubURLProtocol.requests(for: endpoint).count

        service.retranslate()
        try await Task.sleep(for: .milliseconds(100))

        XCTAssertEqual(StubURLProtocol.requests(for: endpoint).count, before)
        XCTAssertNotNil(service.current?.errorMessage, "The error card is left alone")
    }

    // MARK: - Session command

    func testSessionCommandRetranslatesAndOpensTheInspector() async throws {
        let endpoint = StubURLProtocol.register(complete)
        try ConfigLoader.save(TranslationConfig(apiKey: "sk-test-A", endpoint: endpoint, model: "test-model"),
                              to: configURL)
        let reader = DocumentSession(documentRepository: DocumentRepository(database: database),
                                     annotationRepository: AnnotationRepository(database: database),
                                     didOpenDocument: { _ in })
        sessions.append(reader)
        reader.translation = TranslationService(session: StubURLProtocol.makeSession(),
                                                repository: repository, configURL: configURL)

        // Nothing translated yet: the command is a no-op and must not pop the Inspector open.
        reader.retranslateCurrent()
        XCTAssertFalse(reader.isTranslationInspectorVisible)
        XCTAssertNil(reader.translation.current)

        reader.translation.translate(snapshot: snapshot(), documentId: nil)
        try await finished(reader.translation)
        XCTAssertFalse(reader.isTranslationInspectorVisible)

        reader.retranslateCurrent()
        XCTAssertTrue(reader.isTranslationInspectorVisible)
        try await pollUntil { StubURLProtocol.requests(for: endpoint).count == 2 }
        try await finished(reader.translation)
        XCTAssertEqual(StubURLProtocol.requests(for: endpoint).count, 2)
        XCTAssertEqual(reader.translation.current?.partial, "注意力就是一切")
    }
}

/// Collects `onSaved` callbacks (they arrive on the main actor, but keep the type Sendable).
private final class SavedRows: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [TranslationRecord] = []

    var count: Int { lock.withLock { stored.count } }
    var records: [TranslationRecord] { lock.withLock { stored } }
    func append(_ record: TranslationRecord) { lock.withLock { stored.append(record) } }
}
