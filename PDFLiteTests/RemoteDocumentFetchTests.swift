import XCTest

/// Answers every request from an in-memory routing table, so the whole download → validate →
/// land pipeline (including redirects and the arXiv title race) runs without a network.
/// Registered globally for the duration of the test class; `URLSession.shared` consults it.
private final class RemoteStubURLProtocol: URLProtocol, @unchecked Sendable {
    struct Reply {
        var status = 200
        var contentType = "application/pdf"
        var body = Data("%PDF-1.4\n%%EOF".utf8)
        /// When set, answers with a 302 to this URL instead.
        var redirectTo: URL?
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var routes: [String: Reply] = [:]
    nonisolated(unsafe) private static var _requested: [String] = []

    static func reset(routes: [String: Reply]) {
        lock.withLock {
            self.routes = routes
            _requested = []
        }
    }
    static var requested: [String] { lock.withLock { _requested } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        let key = url.absoluteString
        let reply: Reply? = Self.lock.withLock {
            Self._requested.append(key)
            return Self.routes[key]
        }
        guard let reply else {
            client?.urlProtocol(self, didFailWithError: URLError(.fileDoesNotExist))
            return
        }
        if let target = reply.redirectTo {
            let response = HTTPURLResponse(url: url, statusCode: 302, httpVersion: nil,
                                           headerFields: ["Location": target.absoluteString])!
            client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: target), redirectResponse: response)
            return
        }
        let response = HTTPURLResponse(url: url, statusCode: reply.status, httpVersion: nil,
                                       headerFields: ["Content-Type": reply.contentType])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: reply.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

final class RemoteDocumentFetchTests: XCTestCase {
    private var root: URL!
    private typealias Reply = RemoteStubURLProtocol.Reply

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdflite-fetch-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        URLProtocol.registerClass(RemoteStubURLProtocol.self)
    }

    override func tearDownWithError() throws {
        URLProtocol.unregisterClass(RemoteStubURLProtocol.self)
        RemoteStubURLProtocol.reset(routes: [:])
        try? FileManager.default.removeItem(at: root)
    }

    private func atom(title: String) -> Data {
        Data("""
        <?xml version="1.0"?><feed xmlns="http://www.w3.org/2005/Atom">
        <title>ArXiv Query</title><entry><title>\(title)</title></entry></feed>
        """.utf8)
    }

    private func fetch(_ input: String, title: String? = nil) async throws -> URL {
        let source = try XCTUnwrap(RemoteDocumentURL.parse(input))
        return try await RemoteDocumentFetch.downloadAndLand(
            source: source, suppliedTitle: title, in: root, progress: { _ in })
    }

    func testArxivDownloadIsNamedAfterTheAPITitle() async throws {
        RemoteStubURLProtocol.reset(routes: [
            "https://arxiv.org/pdf/2510.26692": Reply(),
            "https://export.arxiv.org/api/query?id_list=2510.26692":
                Reply(contentType: "application/atom+xml", body: atom(title: "API Title")),
        ])
        let landed = try await fetch("https://arxiv.org/abs/2510.26692")
        XCTAssertEqual(landed.lastPathComponent, "API Title [2510.26692].pdf")
        XCTAssertEqual(landed.deletingLastPathComponent().lastPathComponent, "arxiv")
    }

    func testSuppliedTitleNamesTheFileAndSkipsTheArxivAPI() async throws {
        RemoteStubURLProtocol.reset(routes: ["https://arxiv.org/pdf/2510.26692": Reply()])
        let landed = try await fetch("2510.26692", title: "Extension Title")
        XCTAssertEqual(landed.lastPathComponent, "Extension Title [2510.26692].pdf")
        XCTAssertEqual(RemoteStubURLProtocol.requested, ["https://arxiv.org/pdf/2510.26692"],
                       "no metadata request when the browser already gave us the title")
    }

    func testFailedTitleFetchFallsBackToTheIdAndStillLands() async throws {
        RemoteStubURLProtocol.reset(routes: ["https://arxiv.org/pdf/2510.26692": Reply()])   // API unrouted → error
        let landed = try await fetch("2510.26692")
        XCTAssertEqual(landed.lastPathComponent, "2510.26692 [2510.26692].pdf")
        XCTAssertEqual(RemoteDocumentLibrary.displayName(forFileName: landed.lastPathComponent), "2510.26692")
    }

    func testShortLinkThatRedirectsToAnAbstractPageIsRetriedAsArxiv() async throws {
        RemoteStubURLProtocol.reset(routes: [
            "https://t.co/xyz": Reply(redirectTo: URL(string: "https://arxiv.org/abs/2510.26692")!),
            "https://arxiv.org/abs/2510.26692": Reply(contentType: "text/html", body: Data("<html>abstract</html>".utf8)),
            "https://arxiv.org/pdf/2510.26692": Reply(),
        ])
        let landed = try await fetch("https://t.co/xyz", title: "Short Link Paper")
        // Landed under the arXiv identity, so any later spelling of the paper dedups to it.
        XCTAssertEqual(landed.lastPathComponent, "Short Link Paper [2510.26692].pdf")
        XCTAssertEqual(RemoteStubURLProtocol.requested.filter { !$0.contains("export.arxiv.org") },
                       ["https://t.co/xyz", "https://arxiv.org/abs/2510.26692", "https://arxiv.org/pdf/2510.26692"])
    }

    func testHTMLPageWithoutAnythingBetterFailsOnceWithoutRetryLoop() async throws {
        RemoteStubURLProtocol.reset(routes: [
            "https://example.com/blog": Reply(contentType: "text/html", body: Data("<html>hi</html>".utf8)),
        ])
        do {
            _ = try await fetch("https://example.com/blog")
            XCTFail("expected notPDF")
        } catch let error as RemoteDocumentError {
            guard case .notPDF = error else { return XCTFail("wrong error \(error)") }
        }
        XCTAssertEqual(RemoteStubURLProtocol.requested, ["https://example.com/blog"])
    }

    func testBotChallengeStatusesGetAHintOtherStatusesDoNot() {
        for code in [401, 403, 429] {
            XCTAssertTrue(RemoteDocumentError.badStatus(code).errorDescription?.contains("拖入 PDFLite") == true, "\(code)")
        }
        XCTAssertEqual(RemoteDocumentError.badStatus(404).errorDescription, "服务器返回了 HTTP 404。")
    }

    func testBadStatusSurfacesAsBadStatus() async throws {
        RemoteStubURLProtocol.reset(routes: ["https://example.com/gone.pdf": Reply(status: 404)])
        do {
            _ = try await fetch("https://example.com/gone.pdf")
            XCTFail("expected badStatus")
        } catch let error as RemoteDocumentError {
            guard case .badStatus(404) = error else { return XCTFail("wrong error \(error)") }
        }
    }
}
