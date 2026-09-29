import XCTest

/// SSE handling of `DeepSeekClient` against a URLProtocol stub — no network, no real key.
final class DeepSeekClientTests: XCTestCase {
    private struct Outcome {
        var deltas: [String]
        var error: Error?
        var text: String { deltas.joined() }
    }

    private let messages = [["role": "user", "content": "hi"]]

    private func run(_ script: StubURLProtocol.Script) async -> Outcome {
        let endpoint = StubURLProtocol.register(script)
        return await run(endpoint: endpoint)
    }

    private func run(endpoint: URL) async -> Outcome {
        let config = TranslationConfig(apiKey: "sk-test-key", endpoint: endpoint, model: "test-model")
        let client = DeepSeekClient(config: config, session: StubURLProtocol.makeSession())
        var outcome = Outcome(deltas: [], error: nil)
        do {
            for try await delta in client.streamCompletion(messages: messages) {
                outcome.deltas.append(delta)
            }
        } catch {
            outcome.error = error
        }
        return outcome
    }

    private func incompleteReason(_ error: Error?, file: StaticString = #filePath, line: UInt = #line) -> String?? {
        guard case .incomplete(let reason)? = error as? TranslationStreamError else {
            XCTFail("Expected TranslationStreamError.incomplete, got \(String(describing: error))", file: file, line: line)
            return nil
        }
        return .some(reason)
    }

    // MARK: - Completion rules

    func testDoneTerminatedStreamCompletesNormally() async {
        let outcome = await run(.init(chunks: [
            SSE.delta("你好，"), SSE.delta("世界"), SSE.finish("stop"), SSE.done
        ]))
        XCTAssertNil(outcome.error)
        XCTAssertEqual(outcome.text, "你好，世界")
    }

    func testDoneWithoutFinishReasonStillCompletes() async {
        let outcome = await run(.init(chunks: [SSE.delta("译文"), SSE.done]))
        XCTAssertNil(outcome.error)
        XCTAssertEqual(outcome.text, "译文")
    }

    func testFinishReasonStopWithoutDoneCompletes() async {
        let outcome = await run(.init(chunks: [SSE.delta("译文"), SSE.finish("stop")]))
        XCTAssertNil(outcome.error, "finish_reason=stop is a complete answer even if [DONE] never arrives")
        XCTAssertEqual(outcome.text, "译文")
    }

    func testStopCarriedOnTheLastContentChunkCompletes() async {
        let outcome = await run(.init(chunks: [SSE.delta("前"), SSE.delta("后", finishReason: "stop")]))
        XCTAssertNil(outcome.error)
        XCTAssertEqual(outcome.text, "前后")
    }

    func testStreamEndingWithoutDoneOrFinishReasonIsIncomplete() async {
        let outcome = await run(.init(chunks: [SSE.delta("半截")]))
        XCTAssertEqual(outcome.text, "半截", "Deltas already delivered stay visible")
        guard let reason = incompleteReason(outcome.error) else { return }
        XCTAssertNil(reason, "A bare early close carries no finish_reason")
        XCTAssertTrue(outcome.error?.localizedDescription.contains("中断") == true)
    }

    func testFinishReasonLengthIsTruncationError() async {
        let outcome = await run(.init(chunks: [SSE.delta("很长"), SSE.finish("length"), SSE.done]))
        guard let reason = incompleteReason(outcome.error) else { return }
        XCTAssertEqual(reason, "length")
        XCTAssertTrue(outcome.error?.localizedDescription.contains("长度上限") == true)
    }

    func testOtherFinishReasonsAreNamedInTheError() async {
        for reason in ["content_filter", "insufficient_system_resource"] {
            let outcome = await run(.init(chunks: [SSE.delta("x"), SSE.finish(reason), SSE.done]))
            guard let got = incompleteReason(outcome.error) else { return }
            XCTAssertEqual(got, reason)
            XCTAssertTrue(outcome.error?.localizedDescription.contains(reason) == true)
        }
    }

    // MARK: - 200 responses that are really errors

    func testPlainJSONErrorBodyWith200IsReportedAsServerError() async {
        let body = #"{"error":{"message":"Invalid model name","type":"invalid_request_error"}}"#
        let outcome = await run(.init(headers: ["Content-Type": "application/json"], chunks: [Data(body.utf8)]))
        XCTAssertTrue(outcome.deltas.isEmpty)
        guard case .server(let message)? = outcome.error as? TranslationStreamError else {
            return XCTFail("Expected .server, got \(String(describing: outcome.error))")
        }
        XCTAssertEqual(message, "Invalid model name")
    }

    func testPrettyPrintedJSONErrorBodyWith200IsReported() async {
        let body = """
        {
          "error": {
            "message": "Insufficient Balance",
            "code": "402"
          }
        }
        """
        let outcome = await run(.init(headers: ["Content-Type": "application/json"], chunks: [Data(body.utf8)]))
        guard case .server(let message)? = outcome.error as? TranslationStreamError else {
            return XCTFail("Expected .server, got \(String(describing: outcome.error))")
        }
        XCTAssertEqual(message, "Insufficient Balance")
    }

    func testInStreamErrorObjectIsReported() async {
        let outcome = await run(.init(chunks: [
            SSE.delta("部分"),
            SSE.line(["error": ["message": "overloaded"]])
        ]))
        XCTAssertEqual(outcome.text, "部分")
        guard case .server(let message)? = outcome.error as? TranslationStreamError else {
            return XCTFail("Expected .server, got \(String(describing: outcome.error))")
        }
        XCTAssertEqual(message, "overloaded")
    }

    func testUnparseableStrayBodyFallsBackToIncomplete() async {
        let outcome = await run(.init(headers: ["Content-Type": "text/html"], chunks: [Data("<html>oops</html>".utf8)]))
        XCTAssertNotNil(incompleteReason(outcome.error) as Any?)
    }

    func testStrayBodyAfterDeltasDoesNotMaskIncompleteness() async {
        let outcome = await run(.init(chunks: [SSE.delta("译"), Data("{\"error\":{\"message\":\"late\"}}\n".utf8)]))
        XCTAssertEqual(outcome.text, "译")
        XCTAssertNotNil(incompleteReason(outcome.error) as Any?)
    }

    // MARK: - HTTP status mapping

    func testUnauthorizedMapsToAuthFailure() async {
        let body = #"{"error":{"message":"Authentication Fails"}}"#
        for status in [401, 403] {
            let outcome = await run(.init(status: status, headers: ["Content-Type": "application/json"],
                                          chunks: [Data(body.utf8)]))
            guard case .http(let got, let message)? = outcome.error as? TranslationStreamError else {
                return XCTFail("Expected .http, got \(String(describing: outcome.error))")
            }
            XCTAssertEqual(got, status)
            XCTAssertTrue(message.contains("拒绝认证"))
            XCTAssertTrue(message.contains("Authentication Fails"), "Server message is appended")
            XCTAssertEqual((outcome.error as? TranslationStreamError)?.isAuthFailure, true)
        }
    }

    func testRateLimitAndServerErrorMapping() async {
        let limited = await run(.init(status: 429, chunks: [Data("{}".utf8)]))
        guard case .http(429, let limitedMessage)? = limited.error as? TranslationStreamError else {
            return XCTFail("Expected .http(429), got \(String(describing: limited.error))")
        }
        XCTAssertTrue(limitedMessage.contains("限流"))
        XCTAssertEqual((limited.error as? TranslationStreamError)?.isAuthFailure, false)

        let broken = await run(.init(status: 503, chunks: []))
        guard case .http(503, let brokenMessage)? = broken.error as? TranslationStreamError else {
            return XCTFail("Expected .http(503), got \(String(describing: broken.error))")
        }
        XCTAssertTrue(brokenMessage.contains("服务端错误"))
    }

    // MARK: - Transport errors and cancellation

    func testURLErrorCancelledIsCancellationNotNetworkError() async {
        let outcome = await run(.init(chunks: [SSE.delta("x")], ending: .fail(.cancelled)))
        XCTAssertTrue(outcome.error is CancellationError, "Got \(String(describing: outcome.error))")
    }

    func testOtherTransportFailureIsNetworkError() async {
        let outcome = await run(.init(chunks: [SSE.delta("x")], ending: .fail(.networkConnectionLost)))
        guard case .network(let underlying)? = outcome.error as? TranslationStreamError else {
            return XCTFail("Expected .network, got \(String(describing: outcome.error))")
        }
        XCTAssertEqual((underlying as? URLError)?.code, .networkConnectionLost)
    }

    func testConsumerCancellationTearsDownTheConnection() async throws {
        let endpoint = StubURLProtocol.register(.init(chunks: [SSE.delta("开头")], ending: .hang))
        let config = TranslationConfig(apiKey: "sk-test-key", endpoint: endpoint, model: "test-model")
        let client = DeepSeekClient(config: config, session: StubURLProtocol.makeSession())

        let received = Received()
        let messages = messages
        let consumer = Task {
            do {
                for try await delta in client.streamCompletion(messages: messages) {
                    received.append(delta)
                }
            } catch {
                received.fail(error)
            }
        }
        try await pollUntil { received.text == "开头" }
        XCTAssertEqual(received.text, "开头")

        consumer.cancel()
        await consumer.value
        try await pollUntil { StubURLProtocol.wasStopped(endpoint) }
        XCTAssertTrue(StubURLProtocol.wasStopped(endpoint), "Cancelling the consumer must abort the request")
    }

    // MARK: - Request shape

    func testRequestCarriesBearerKeyAndStreamFlag() async throws {
        let endpoint = StubURLProtocol.register(.init(chunks: [SSE.delta("ok"), SSE.done]))
        _ = await run(endpoint: endpoint)
        let request = try XCTUnwrap(StubURLProtocol.requests(for: endpoint).first)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer sk-test-key")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "text/event-stream")
    }

    // MARK: - Line parser

    func testParserExtractsDeltaAndFinishReasonFromOneChunk() {
        let line = #"data: {"choices":[{"delta":{"content":"末"},"finish_reason":"stop"}]}"#
        guard case .data(let delta, let reason)? = DeepSeekClient.parseSSELine(line) else {
            return XCTFail("Expected a data chunk")
        }
        XCTAssertEqual(delta, "末")
        XCTAssertEqual(reason, "stop")
    }

    func testParserIgnoresNonTerminalNullFinishReasonAndRoleOnlyDeltas() {
        XCTAssertNil(DeepSeekClient.parseSSELine(#"data: {"choices":[{"delta":{"role":"assistant","content":""},"finish_reason":null}]}"#))
        XCTAssertNil(DeepSeekClient.parseSSELine(": keep-alive"))
        XCTAssertNil(DeepSeekClient.parseSSELine("event: message"))
        XCTAssertNil(DeepSeekClient.parseSSELine(""))
        // A usage-only chunk after the answer has an empty choices array.
        XCTAssertNil(DeepSeekClient.parseSSELine(#"data: {"choices":[],"usage":{"total_tokens":3}}"#))
    }

    func testParserFlagsNonSSELinesAsStray() {
        guard case .stray(let text)? = DeepSeekClient.parseSSELine(#"  {"error":{"message":"x"}}  "#) else {
            return XCTFail("Expected a stray line")
        }
        XCTAssertEqual(text, #"{"error":{"message":"x"}}"#)
    }
}

/// Thread-safe sink for the consumer Task in the cancellation test.
private final class Received: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = ""
    private var failure: Error?

    var text: String { lock.withLock { buffer } }
    func append(_ text: String) { lock.withLock { buffer += text } }
    func fail(_ error: Error) { lock.withLock { failure = error } }
}
