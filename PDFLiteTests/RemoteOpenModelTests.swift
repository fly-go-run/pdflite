import XCTest

/// Hand-cranked downloader: each `download` call parks until the test finishes it, so the tests
/// control exactly when a request is "in flight" while more arrive behind it.
private final class StubDownloads: @unchecked Sendable {
    private let lock = NSLock()
    private var pending: [(key: String, continuation: CheckedContinuation<URL, Error>)] = []
    private var _started: [String] = []
    private var _titles: [String: String?] = [:]

    var started: [String] { lock.withLock { _started } }
    func title(for key: String) -> String?? { lock.withLock { _titles[key] } }

    /// Requests are keyed by the last path component of the download URL ("a.pdf").
    func download(_ source: RemoteDocumentURL, title: String?) async throws -> URL {
        let key = source.downloadURL.lastPathComponent
        return try await withCheckedThrowingContinuation { continuation in
            lock.withLock {
                pending.append((key, continuation))
                _started.append(key)
                _titles[key] = .some(title)
            }
        }
    }

    /// Completes the oldest parked request for `key`.
    func finish(_ key: String, _ result: Result<URL, Error>) {
        let entry: CheckedContinuation<URL, Error>? = lock.withLock {
            guard let index = pending.firstIndex(where: { $0.key == key }) else { return nil }
            return pending.remove(at: index).continuation
        }
        guard let entry else { return XCTFail("no parked download for \(key)") }
        entry.resume(with: result)
    }

    func finishEverything() {
        let all = lock.withLock { () -> [CheckedContinuation<URL, Error>] in
            let c = pending.map(\.continuation)
            pending = []
            return c
        }
        all.forEach { $0.resume(throwing: CancellationError()) }
    }
}

@MainActor
final class RemoteOpenModelTests: XCTestCase {
    private var stub: StubDownloads!
    private var opened: [URL] = []
    private var closedCount = 0
    private var existing: [String: URL] = [:]

    override func setUp() async throws {
        stub = StubDownloads()
        opened = []
        closedCount = 0
        existing = [:]
    }

    override func tearDown() async throws {
        stub.finishEverything()
    }

    private func makeModel() -> RemoteOpenModel {
        RemoteOpenModel(
            download: { [stub = stub!] source, title, _ in
                try await stub.download(source, title: title)
            },
            existingFile: { [weak self] token in self?.existing[token] },
            openFile: { [weak self] url in self?.opened.append(url) },
            closePanel: { [weak self] in self?.closedCount += 1 }
        )
    }

    private func file(_ name: String) -> URL { URL(fileURLWithPath: "/tmp/library/\(name).pdf") }

    private func waitUntil(_ what: String = "", _ predicate: () -> Bool,
                           file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !predicate() {
            if ContinuousClock.now > deadline {
                return XCTFail("timed out waiting for \(what)", file: file, line: line)
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    // MARK: queueing

    func testRequestsArrivingMidDownloadQueueInOrderAndAFailureDoesNotStopTheQueue() async throws {
        let model = makeModel()

        XCTAssertEqual(model.submit(raw: "https://example.com/a.pdf"), .started)
        XCTAssertEqual(model.submit(raw: "https://example.com/b.pdf", title: "Paper B Title"), .queued)
        XCTAssertEqual(model.submit(raw: "https://example.com/c.pdf"), .queued)
        XCTAssertEqual(model.queuedCount, 2)
        // Dedup covers the in-flight request (fragment ignored) and the waiting ones.
        XCTAssertEqual(model.submit(raw: "https://example.com/a.pdf#page=2"), .duplicate)
        XCTAssertEqual(model.submit(raw: "https://example.com/c.pdf"), .duplicate)
        XCTAssertEqual(model.queuedCount, 2)
        // Not silently lost even when busy: recorded as a failure line.
        XCTAssertEqual(model.submit(raw: "not a link"), .invalid)
        XCTAssertEqual(model.failures.count, 1)
        XCTAssertNil(model.inputError, "the field belongs to the running download")

        try await waitUntil("a to start") { stub.started == ["a.pdf"] }
        stub.finish("a.pdf", .success(file("A")))

        try await waitUntil("b to start") { stub.started == ["a.pdf", "b.pdf"] }
        XCTAssertEqual(opened, [file("A")], "a success opens its document immediately")
        XCTAssertEqual(model.queuedCount, 1)
        XCTAssertEqual(model.current?.source.downloadURL.lastPathComponent, "b.pdf")
        XCTAssertEqual(stub.title(for: "b.pdf"), .some("Paper B Title"), "vetted title reaches the downloader")
        XCTAssertEqual(stub.title(for: "a.pdf"), .some(nil))

        stub.finish("b.pdf", .failure(RemoteDocumentError.badStatus(404)))
        try await waitUntil("c to start") { stub.started.count == 3 }
        XCTAssertTrue(model.failures.contains { $0.contains("Paper B Title") && $0.contains("404") },
                      "\(model.failures)")
        XCTAssertEqual(model.queuedCount, 0)

        stub.finish("c.pdf", .success(file("C")))
        try await waitUntil("queue to drain") { !model.isDownloading }
        XCTAssertEqual(opened, [file("A"), file("C")])
        XCTAssertEqual(closedCount, 0, "a failure keeps the panel open so its message can be read")
        XCTAssertEqual(model.input, "https://example.com/b.pdf", "failing input stays for a retry")
        XCTAssertEqual(model.failures.count, 2)
    }

    func testCleanRunOpensEverythingThenClosesThePanelOnce() async throws {
        let model = makeModel()
        XCTAssertEqual(model.submit(raw: "https://example.com/a.pdf"), .started)
        XCTAssertEqual(model.submit(raw: "https://example.com/b.pdf"), .queued)

        try await waitUntil("a") { stub.started == ["a.pdf"] }
        stub.finish("a.pdf", .success(file("A")))
        try await waitUntil("b") { stub.started == ["a.pdf", "b.pdf"] }
        XCTAssertEqual(closedCount, 0, "panel stays up while the queue still has work")
        stub.finish("b.pdf", .success(file("B")))
        try await waitUntil("done") { !model.isDownloading }

        XCTAssertEqual(opened, [file("A"), file("B")])
        XCTAssertEqual(closedCount, 1)
        XCTAssertEqual(model.input, "")
        XCTAssertTrue(model.failures.isEmpty)
    }

    func testLibraryHitOpensWithoutDownloading() throws {
        let model = makeModel()
        let cached = try XCTUnwrap(RemoteDocumentURL.parse("2510.26692"))
        existing[cached.dedupToken] = file("cached")

        XCTAssertEqual(model.submit(raw: "https://arxiv.org/abs/2510.26692"), .openedExisting)
        XCTAssertEqual(opened, [file("cached")])
        XCTAssertFalse(model.isDownloading)
        XCTAssertTrue(stub.started.isEmpty)
        XCTAssertEqual(closedCount, 0, "the model does not touch a panel that was never shown")

        // Panel path: the "打开" button closes the (visible) panel after a hit.
        model.input = "2510.26692"
        model.start()
        XCTAssertEqual(opened, [file("cached"), file("cached")])
        XCTAssertEqual(closedCount, 1)
        XCTAssertEqual(model.input, "")
    }

    func testLibraryHitDuringADownloadOpensImmediatelyInsteadOfQueueing() async throws {
        let model = makeModel()
        XCTAssertEqual(model.submit(raw: "https://example.com/a.pdf"), .started)
        try await waitUntil("a") { stub.started == ["a.pdf"] }

        let cached = try XCTUnwrap(RemoteDocumentURL.parse("https://example.com/z.pdf"))
        existing[cached.dedupToken] = file("Z-local")
        XCTAssertEqual(model.submit(raw: "https://example.com/z.pdf"), .openedExisting)
        XCTAssertEqual(opened, [file("Z-local")])
        XCTAssertEqual(model.queuedCount, 0)
        XCTAssertEqual(model.current?.source.downloadURL.lastPathComponent, "a.pdf", "download undisturbed")
    }

    func testQueuedItemThatBecomesAvailableLocallyIsOpenedWithoutDownload() async throws {
        let model = makeModel()
        XCTAssertEqual(model.submit(raw: "https://example.com/a.pdf"), .started)
        XCTAssertEqual(model.submit(raw: "https://example.com/b.pdf"), .queued)
        XCTAssertEqual(model.submit(raw: "https://example.com/c.pdf"), .queued)

        // b lands in the library some other way while a downloads.
        let b = try XCTUnwrap(RemoteDocumentURL.parse("https://example.com/b.pdf"))
        existing[b.dedupToken] = file("B-local")

        try await waitUntil("a") { stub.started == ["a.pdf"] }
        stub.finish("a.pdf", .success(file("A")))
        try await waitUntil("c") { stub.started == ["a.pdf", "c.pdf"] }
        XCTAssertEqual(opened, [file("A"), file("B-local")])
        stub.finish("c.pdf", .success(file("C")))
        try await waitUntil("done") { !model.isDownloading }
        XCTAssertEqual(opened, [file("A"), file("B-local"), file("C")])
    }

    // MARK: invalid input, cancel

    func testInvalidInputWhileIdleShowsInTheFieldWithAnError() {
        let model = makeModel()
        XCTAssertEqual(model.submit(raw: "  definitely not a link "), .invalid)
        XCTAssertEqual(model.input, "definitely not a link")
        XCTAssertNotNil(model.inputError)
        XCTAssertFalse(model.isDownloading)

        // A valid submission clears it.
        model.input = "https://example.com/a.pdf"
        model.start()
        XCTAssertNil(model.inputError)
        XCTAssertTrue(model.isDownloading)
    }

    func testCancelDropsTheQueueAndIgnoresTheLateCompletion() async throws {
        let model = makeModel()
        XCTAssertEqual(model.submit(raw: "https://example.com/a.pdf"), .started)
        XCTAssertEqual(model.submit(raw: "https://example.com/b.pdf"), .queued)
        try await waitUntil("a") { stub.started == ["a.pdf"] }

        model.cancel()
        XCTAssertFalse(model.isDownloading)
        XCTAssertEqual(model.queuedCount, 0)

        // Same request again: a fresh run, distinct from the cancelled one.
        XCTAssertEqual(model.submit(raw: "https://example.com/a.pdf"), .started)
        try await waitUntil("second a") { stub.started == ["a.pdf", "a.pdf"] }

        // The cancelled download finishing late must not be applied to the new run.
        stub.finish("a.pdf", .success(file("stale")))
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(opened.isEmpty)
        XCTAssertTrue(model.isDownloading)

        stub.finish("a.pdf", .success(file("fresh")))
        try await waitUntil("fresh done") { !model.isDownloading }
        XCTAssertEqual(opened, [file("fresh")])
    }

    // MARK: deep link parsing

    func testDeepLinkParsingWithAndWithoutTitle() throws {
        func link(_ s: String) throws -> (target: String, title: String?)? {
            RemoteOpenPanelController.parseDeepLink(try XCTUnwrap(URL(string: s)))
        }

        // Backward compatible: no title param.
        let plain = try XCTUnwrap(link("pdflite://open?url=https%3A%2F%2Farxiv.org%2Fabs%2F2510.26692"))
        XCTAssertEqual(plain.target, "https://arxiv.org/abs/2510.26692")
        XCTAssertNil(plain.title)

        // Title is percent-decoded; "&" inside it does not split the query.
        let titled = try XCTUnwrap(link(
            "pdflite://open?url=https%3A%2F%2Farxiv.org%2Fabs%2F2510.26692&title=%5B2510.26692%5D%20Kimi%20Linear%20%26%20More"))
        XCTAssertEqual(titled.title, "[2510.26692] Kimi Linear & More")

        // The target's own query string survives.
        let nested = try XCTUnwrap(link("pdflite://open?url=https%3A%2F%2Fexample.com%2Fa%3Fx%3D1%26y%3D2"))
        XCTAssertEqual(nested.target, "https://example.com/a?x=1&y=2")

        XCTAssertNil(try link("https://open?url=https%3A%2F%2Fexample.com%2Fa.pdf"))
        XCTAssertNil(try link("pdflite://reader?url=https%3A%2F%2Fexample.com%2Fa.pdf"))
        XCTAssertNil(try link("pdflite://open"))
        XCTAssertNil(try link("pdflite://open?url="))
        XCTAssertNil(try link("pdflite://open?title=Only%20A%20Title"))
    }

    func testUnsafeTitleFromDeepLinkIsVettedBeforeReachingTheDownloader() async throws {
        let model = makeModel()
        XCTAssertEqual(model.submit(raw: "https://example.com/a.pdf", title: "paper.pdf"), .started)
        try await waitUntil("a") { stub.started == ["a.pdf"] }
        XCTAssertEqual(stub.title(for: "a.pdf"), .some(nil), "filename-like title is dropped")
    }
}
