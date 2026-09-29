import Foundation

/// Minimal DeepSeek (OpenAI-compatible) chat-completions streaming client. Single-purpose by
/// design — no Provider protocol, no registry, no model-routing layer (§1.1 forbids that).
struct DeepSeekClient {
    let config: TranslationConfig
    let session: URLSession

    init(config: TranslationConfig, session: URLSession = .shared) {
        self.config = config
        self.session = session
    }

    /// Yields the assistant's text deltas as they arrive over the SSE stream. The stream
    /// finishes normally only when the translation is provably complete: `data: [DONE]`, or a
    /// terminal `finish_reason` of `"stop"` (accepted even if the connection then closes without
    /// `[DONE]`). A stream that just ends — or whose `finish_reason` is `length` /
    /// `content_filter` / anything else — throws `TranslationStreamError.incomplete`, so the
    /// caller never mistakes a truncated translation for a finished one.
    /// Cancellation: cancel the consuming Task, or call `continuation.finish` from the caller —
    /// the inner streaming Task observes Task.isCancelled and tears down the URLSession bytes
    /// stream.
    func streamCompletion(messages: [[String: String]]) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let request: URLRequest
            do {
                request = try makeRequest(messages: messages)
            } catch {
                continuation.finish(throwing: error)
                return
            }

            let task = Task {
                do {
                    let (bytes, response) = try await session.bytes(for: request)
                    // Consumer-side cancellation reaches here via continuation.onTermination →
                    // task.cancel(); checking right after connect avoids reading a body we no
                    // longer want, and AsyncBytes tears down the connection on cancellation.
                    try Task.checkCancellation()
                    if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                        let body = await Self.collectBody(from: bytes, limit: Self.strayBodyLimit)
                        continuation.finish(throwing: Self.error(forStatus: http.statusCode, body: body))
                        return
                    }

                    var deltaCount = 0
                    // Lines that aren't SSE at all. A 200 response can carry a plain JSON error
                    // body (no `data:` prefix); keep a bounded copy so it can be reported instead
                    // of the misleading "empty output".
                    var strayBody = ""
                    for try await line in bytes.lines {
                        if Task.isCancelled {
                            continuation.finish(throwing: CancellationError())
                            return
                        }
                        guard let chunk = Self.parseSSELine(line) else { continue }
                        switch chunk {
                        case .done:
                            // A non-"stop" finish_reason has already failed the stream above, so
                            // reaching [DONE] means the model finished.
                            continuation.finish()
                            return
                        case .data(let delta, let finishReason):
                            if let delta {
                                deltaCount += 1
                                continuation.yield(delta)
                            }
                            if let finishReason {
                                if finishReason == "stop" {
                                    continuation.finish()
                                } else {
                                    continuation.finish(throwing: TranslationStreamError.incomplete(reason: finishReason))
                                }
                                return
                            }
                        case .stray(let text):
                            if strayBody.utf8.count < Self.strayBodyLimit {
                                strayBody += text + "\n"
                            }
                        case .error(let err):
                            continuation.finish(throwing: err)
                            return
                        }
                    }
                    // The connection closed with neither [DONE] nor a terminal finish_reason.
                    if deltaCount == 0, let message = Self.extractServerMessage(strayBody) {
                        continuation.finish(throwing: TranslationStreamError.server(message: message))
                    } else {
                        continuation.finish(throwing: TranslationStreamError.incomplete(reason: nil))
                    }
                } catch {
                    // URLSession reports a torn-down request as URLError.cancelled; that is the
                    // caller cancelling, not a network failure worth showing.
                    if Task.isCancelled || error is CancellationError
                        || (error as? URLError)?.code == .cancelled {
                        continuation.finish(throwing: CancellationError())
                    } else {
                        continuation.finish(throwing: TranslationStreamError.network(error))
                    }
                }
            }

            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    // MARK: - Request building

    private func makeRequest(messages: [[String: String]]) throws -> URLRequest {
        var request = URLRequest(url: config.endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")

        let body: [String: Any] = [
            "model": config.model,
            "messages": messages,
            "stream": true,
            "temperature": 0.2
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [])
        return request
    }

    // MARK: - SSE parsing

    /// Upper bound for the non-SSE / non-2xx body kept for error reporting.
    private static let strayBodyLimit = 4096

    enum Chunk {
        /// One `choices[0]` update: text delta and/or the terminal `finish_reason` (either may be
        /// present on its own; some servers put both in the last chunk).
        case data(delta: String?, finishReason: String?)
        case done
        case error(Error)
        /// Not SSE at all (no `data:` prefix, not a comment or SSE field): possibly the body of a
        /// JSON error returned with a 200 status.
        case stray(String)
    }

    static func parseSSELine(_ line: String) -> Chunk? {
        // Skip blanks and SSE comments (lines starting with ':').
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        guard !trimmed.hasPrefix(":") else { return nil }
        guard trimmed.hasPrefix("data:") else {
            // Other SSE fields carry nothing we need; anything else is a stray (error) body.
            let isSSEField = ["event:", "id:", "retry:"].contains { trimmed.hasPrefix($0) }
            return isSSEField ? nil : .stray(trimmed)
        }

        let payload = String(trimmed.dropFirst("data:".count))
            .trimmingCharacters(in: .whitespaces)

        if payload == "[DONE]" {
            return .done
        }

        guard let data = payload.data(using: .utf8) else { return nil }
        do {
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return nil
            }
            // Some servers occasionally inline an error object on the SSE channel.
            if let errorBlock = json["error"] as? [String: Any],
               let message = errorBlock["message"] as? String {
                return .error(TranslationStreamError.server(message: message))
            }
            guard let choices = json["choices"] as? [[String: Any]],
                  let first = choices.first else {
                return nil
            }
            var text: String?
            if let delta = first["delta"] as? [String: Any],
               let content = delta["content"] as? String, !content.isEmpty {
                text = content
            }
            // JSON null (every non-terminal chunk) bridges to NSNull, which `as? String` rejects.
            var reason: String?
            if let raw = first["finish_reason"] as? String, !raw.isEmpty {
                reason = raw
            }
            guard text != nil || reason != nil else { return nil }
            return .data(delta: text, finishReason: reason)
        } catch {
            return nil
        }
    }

    static func error(forStatus status: Int, body: String?) -> Error {
        let extracted = body.flatMap(extractServerMessage)
        let summary: String
        switch status {
        case 401, 403:
            summary = "DeepSeek 拒绝认证（HTTP \(status)）：API Key 可能错误或无权限"
        case 404:
            summary = "DeepSeek 端点 404：检查 endpoint 路径（应为 /chat/completions）"
        case 429:
            summary = "DeepSeek 限流（HTTP 429）：稍后再试"
        case 500...599:
            summary = "DeepSeek 服务端错误（HTTP \(status)）"
        default:
            summary = "DeepSeek 请求失败（HTTP \(status)）"
        }
        if let extracted, !extracted.isEmpty {
            return TranslationStreamError.http(status: status, message: "\(summary)：\(extracted)")
        }
        return TranslationStreamError.http(status: status, message: summary)
    }

    static func extractServerMessage(_ body: String) -> String? {
        guard let data = body.data(using: .utf8) else { return nil }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        if let block = json["error"] as? [String: Any], let msg = block["message"] as? String {
            return msg
        }
        return nil
    }

    private static func collectBody(from stream: URLSession.AsyncBytes, limit: Int) async -> String {
        var data = Data()
        data.reserveCapacity(limit)
        do {
            for try await byte in stream {
                if data.count >= limit { break }
                data.append(byte)
            }
        } catch {
            return String(data: data, encoding: .utf8) ?? ""
        }
        return String(data: data, encoding: .utf8) ?? ""
    }
}

enum TranslationStreamError: LocalizedError {
    case network(Error)
    /// The server reported an error inside a 200 response (in-stream or plain JSON body).
    case server(message: String)
    /// Non-2xx HTTP status. Kept separate from `.server` so callers can react to the status
    /// (a 401/403 means the cached config is stale) without parsing text.
    case http(status: Int, message: String)
    /// The stream ended before a complete translation arrived. `reason` is the terminal
    /// `finish_reason` when the model stopped for something other than "stop"; nil means the
    /// connection simply closed without `[DONE]` or any finish_reason.
    case incomplete(reason: String?)

    var errorDescription: String? {
        switch self {
        case .network(let underlying):
            return "网络错误：\(underlying.localizedDescription)"
        case .server(let message), .http(_, let message):
            return message
        case .incomplete(let reason):
            switch reason {
            case nil:
                return "译文被中断：连接在译文完整返回前已关闭，请重试"
            case "length":
                return "译文因长度上限被截断，可缩短选区后重试"
            case let other?:
                return "译文未完整生成：模型以 \(other) 结束，请重试"
            }
        }
    }

    /// True for the HTTP statuses that mean the API key / config is wrong or stale.
    var isAuthFailure: Bool {
        if case .http(let status, _) = self { return status == 401 || status == 403 }
        return false
    }
}
