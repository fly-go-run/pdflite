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
    /// finishes when the server sends `data: [DONE]` or closes the connection.
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
                        let body = await Self.collectBody(from: bytes, limit: 4096)
                        continuation.finish(throwing: Self.error(forStatus: http.statusCode, body: body))
                        return
                    }

                    for try await line in bytes.lines {
                        if Task.isCancelled {
                            continuation.finish(throwing: CancellationError())
                            return
                        }
                        guard let chunk = Self.parseSSELine(line) else { continue }
                        switch chunk {
                        case .done:
                            continuation.finish()
                            return
                        case .delta(let text):
                            continuation.yield(text)
                        case .error(let err):
                            continuation.finish(throwing: err)
                            return
                        }
                    }
                    continuation.finish()
                } catch {
                    if error is CancellationError {
                        continuation.finish(throwing: error)
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

    private enum Chunk {
        case delta(String)
        case done
        case error(Error)
    }

    private static func parseSSELine(_ line: String) -> Chunk? {
        // Skip blanks and SSE comments (lines starting with ':').
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        guard !trimmed.hasPrefix(":") else { return nil }
        guard trimmed.hasPrefix("data:") else { return nil }

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
                  let first = choices.first,
                  let delta = first["delta"] as? [String: Any] else {
                return nil
            }
            if let content = delta["content"] as? String, !content.isEmpty {
                return .delta(content)
            }
            return nil
        } catch {
            return nil
        }
    }

    private static func error(forStatus status: Int, body: String?) -> Error {
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
            return TranslationStreamError.server(message: "\(summary)：\(extracted)")
        }
        return TranslationStreamError.server(message: summary)
    }

    private static func extractServerMessage(_ body: String) -> String? {
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
    case server(message: String)

    var errorDescription: String? {
        switch self {
        case .network(let underlying):
            return "网络错误：\(underlying.localizedDescription)"
        case .server(let message):
            return message
        }
    }
}
