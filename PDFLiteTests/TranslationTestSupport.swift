import Foundation

/// In-process stand-in for the DeepSeek endpoint. Tests never open a socket and never see a real
/// API key: each test registers a script under a unique `*.stub.test` host, points the client's
/// endpoint at it, and hands `StubURLProtocol.makeSession()` to `DeepSeekClient` /
/// `TranslationService`.
final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    struct Script {
        enum Ending {
            /// Complete the response after the last chunk (connection closes).
            case finish
            /// Keep the connection open forever (until the client cancels).
            case hang
            /// Fail the transfer with a transport error.
            case fail(URLError.Code)
        }

        var status = 200
        var headers = ["Content-Type": "text/event-stream"]
        var chunks: [Data] = []
        var ending: Ending = .finish
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var scripts: [String: Script] = [:]
    nonisolated(unsafe) private static var seenRequests: [String: [URLRequest]] = [:]
    nonisolated(unsafe) private static var stoppedHosts: Set<String> = []

    private var stopped = false
    private let stateLock = NSLock()

    // MARK: - Test-facing API

    /// Registers `script` under a fresh host and returns the endpoint URL to configure.
    static func register(_ script: Script) -> URL {
        let host = "\(UUID().uuidString.lowercased()).stub.test"
        lock.withLock { scripts[host] = script }
        return URL(string: "https://\(host)/chat/completions")!
    }

    /// Replaces the script behind an already registered endpoint (e.g. for a retry).
    static func update(_ endpoint: URL, to script: Script) {
        guard let host = endpoint.host else { return }
        lock.withLock { scripts[host] = script }
    }

    static func requests(for endpoint: URL) -> [URLRequest] {
        lock.withLock { seenRequests[endpoint.host ?? ""] ?? [] }
    }

    /// True once URLSession told the protocol to stop, i.e. the client tore the request down.
    static func wasStopped(_ endpoint: URL) -> Bool {
        lock.withLock { stoppedHosts.contains(endpoint.host ?? "") }
    }

    static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    // MARK: - URLProtocol

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host?.hasSuffix(".stub.test") == true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let host = url.host,
              let script = Self.lock.withLock({ Self.scripts[host] }) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        Self.lock.withLock { Self.seenRequests[host, default: []].append(request) }

        let response = HTTPURLResponse(url: url, statusCode: script.status, httpVersion: "HTTP/1.1",
                                       headerFields: script.headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)

        DispatchQueue.global().async { [self] in
            for chunk in script.chunks {
                guard !isStopped else { return }
                client?.urlProtocol(self, didLoad: chunk)
                // Give the consumer a moment so chunks arrive as separate reads.
                Thread.sleep(forTimeInterval: 0.01)
            }
            switch script.ending {
            case .finish:
                guard !isStopped else { return }
                client?.urlProtocolDidFinishLoading(self)
            case .hang:
                break
            case .fail(let code):
                guard !isStopped else { return }
                client?.urlProtocol(self, didFailWithError: URLError(code))
            }
        }
    }

    override func stopLoading() {
        stateLock.withLock { stopped = true }
        if let host = request.url?.host {
            Self.lock.withLock { _ = Self.stoppedHosts.insert(host) }
        }
    }

    private var isStopped: Bool { stateLock.withLock { stopped } }
}

/// Builders for the wire format DeepSeek streams.
enum SSE {
    static func delta(_ text: String, finishReason: String? = nil) -> Data {
        chunk(delta: ["content": text], finishReason: finishReason)
    }

    /// The empty terminal chunk DeepSeek sends after the last content delta.
    static func finish(_ reason: String) -> Data {
        chunk(delta: ["content": ""], finishReason: reason)
    }

    static let done = Data("data: [DONE]\n\n".utf8)

    static func line(_ payload: [String: Any]) -> Data {
        let json = try! JSONSerialization.data(withJSONObject: payload)
        return Data("data: ".utf8) + json + Data("\n\n".utf8)
    }

    private static func chunk(delta: [String: String], finishReason: String?) -> Data {
        line([
            "choices": [[
                "index": 0,
                "delta": delta,
                "finish_reason": finishReason.map { $0 as Any } ?? NSNull()
            ]]
        ])
    }
}

/// Polls `predicate` (5 s cap) — the async pipelines under test have no completion hook. Runs on
/// the main actor so predicates may read main-actor state such as `TranslationService.current`.
@MainActor
func pollUntil(timeout: Duration = .seconds(5), _ predicate: () -> Bool) async throws {
    let deadline = ContinuousClock.now + timeout
    while !predicate(), ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(10))
    }
}
