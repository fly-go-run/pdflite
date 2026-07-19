import CryptoKit
import Foundation
import Observation
import os.log

/// Public state of an in-flight translation. UI binds against this directly via @Observable.
struct TranslationOutput: Equatable {
    var sourceText: String          // raw selection text, for header display
    var cleanedText: String         // what we actually sent to the model
    var pageIndex: Int?
    var partial: String             // streaming buffer (also the final value when done)
    var isStreaming: Bool
    var fromCache: Bool
    var errorMessage: String?
    var startedAt: Date
    var completedAt: Date?
}

@MainActor
@Observable
final class TranslationService {
    private let logger = Logger(subsystem: "com.pdflite.app", category: "Translation")
    private let session: URLSession

    /// The current translation request. Starts a new one cancels the previous one.
    private(set) var current: TranslationOutput?

    private var streamTask: Task<Void, Never>?
    private var cachedConfig: TranslationConfig?
    /// Callback supplied with `translate()` to notify a successful save. Cleared on cancel/replace
    /// so a stale handler can't fire against a new translation.
    private var pendingOnSaved: ((TranslationRecord) -> Void)?
    /// Last request, kept so an error state can offer "重试" even after the selection is gone.
    @ObservationIgnored private var lastRequestSnapshot: SelectionSnapshot?
    @ObservationIgnored private var lastRequestDocumentId: Int64?
    /// Token from the block-based addObserver. Must be kept and removed explicitly —
    /// removeObserver(self) can't unregister block observers, so without this every closed
    /// window would leave a dead observer behind, all re-run on each config change.
    /// nonisolated(unsafe) is sound: written once in init, read once in deinit.
    @ObservationIgnored private nonisolated(unsafe) var configObserverToken: (any NSObjectProtocol)?

    init(session: URLSession = .shared) {
        self.session = session
        // Settings UI posts this after rewriting ~/.config/pdflite/config.json. Drop the cache so
        // the next translate() call picks up the new key/endpoint/model without restarting the app.
        configObserverToken = NotificationCenter.default.addObserver(
            forName: ConfigLoader.configChangedNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.invalidateConfigCache()
            }
        }
    }

    deinit {
        if let configObserverToken {
            NotificationCenter.default.removeObserver(configObserverToken)
        }
    }

    func reset() {
        cancelInFlight()
        current = nil
        lastRequestSnapshot = nil
        lastRequestDocumentId = nil
    }

    /// True when the current output is an error and we still know what was requested.
    var canRetry: Bool {
        current?.errorMessage != nil && lastRequestSnapshot != nil
    }

    /// Re-run the last translation request (typically after a network / config error).
    func retryLast() {
        guard let snapshot = lastRequestSnapshot else { return }
        translate(snapshot: snapshot, documentId: lastRequestDocumentId)
    }

    // MARK: - Translate

    /// Kick off a translation for `snapshot`. If a cached translation exists for the same
    /// (cleaned text + language + model), it's served synchronously without hitting the network.
    /// Otherwise an SSE stream is started; tokens land in `current.partial` as they arrive.
    /// `onSaved` fires once when a row is committed (cache hit or stream finish). Errors and
    /// cancellation never call it.
    func translate(snapshot: SelectionSnapshot,
                   documentId: Int64?,
                   targetLanguage: String = TranslationConfig.defaultTargetLanguage,
                   onSaved: ((TranslationRecord) -> Void)? = nil) {
        cancelInFlight()
        pendingOnSaved = onSaved
        lastRequestSnapshot = snapshot
        lastRequestDocumentId = documentId

        let config: TranslationConfig
        do {
            config = try loadConfig()
        } catch let configError as TranslationConfigError {
            current = TranslationOutput(
                sourceText: snapshot.rawText,
                cleanedText: snapshot.rawText,
                pageIndex: snapshot.pageIndex,
                partial: "",
                isStreaming: false,
                fromCache: false,
                errorMessage: [configError.errorDescription, configError.recoverySuggestion]
                    .compactMap { $0 }
                    .joined(separator: "\n\n"),
                startedAt: Date(),
                completedAt: Date()
            )
            return
        } catch {
            current = makeErrorOutput(snapshot: snapshot, message: error.localizedDescription)
            return
        }

        let cleaned = TextCleaner.clean(snapshot.rawText)
        let hash = Self.cacheKey(cleaned: cleaned, target: targetLanguage, model: config.model)

        current = TranslationOutput(
            sourceText: snapshot.rawText,
            cleanedText: cleaned,
            pageIndex: snapshot.pageIndex,
            partial: "",
            isStreaming: true,
            fromCache: false,
            errorMessage: nil,
            startedAt: Date(),
            completedAt: nil
        )

        let messages = PromptBuilder.messages(sourceText: cleaned, targetLanguage: targetLanguage)
        let client = DeepSeekClient(config: config, session: session)

        streamTask = Task { [weak self] in
            // Cache lookup happens inside the task so SQLite never blocks the call site; a hit
            // resolves in a few ms without touching the network.
            if let cached = try? await TranslationRepository.shared.findCache(byHash: hash) {
                if Task.isCancelled { return }
                await self?.finishFromCache(cached: cached,
                                            hash: hash,
                                            cleaned: cleaned,
                                            snapshot: snapshot,
                                            documentId: documentId,
                                            model: config.model)
                return
            }
            if Task.isCancelled { return }
            await self?.consumeStream(client: client,
                                      messages: messages,
                                      hash: hash,
                                      cleaned: cleaned,
                                      snapshot: snapshot,
                                      documentId: documentId,
                                      model: config.model)
        }
    }

    func cancelInFlight() {
        streamTask?.cancel()
        streamTask = nil
        // Drop any outstanding bind callback — we don't want it to fire against a fresh request.
        pendingOnSaved = nil
        if var existing = current, existing.isStreaming {
            existing.isStreaming = false
            existing.completedAt = Date()
            if existing.partial.isEmpty {
                existing.errorMessage = "已取消"
            }
            current = existing
        }
    }

    // MARK: - Config

    /// Force a fresh read of the config file on the next translation.
    func invalidateConfigCache() {
        cachedConfig = nil
    }

    private func loadConfig() throws -> TranslationConfig {
        if let cachedConfig { return cachedConfig }
        let loaded = try ConfigLoader.load()
        cachedConfig = loaded
        return loaded
    }

    // MARK: - Stream consumption

    private func consumeStream(client: DeepSeekClient,
                               messages: [[String: String]],
                               hash: String,
                               cleaned: String,
                               snapshot: SelectionSnapshot,
                               documentId: Int64?,
                               model: String) async {
        var buffer = ""
        var failure: Error?
        do {
            for try await delta in client.streamCompletion(messages: messages) {
                if Task.isCancelled { return }
                buffer.append(delta)
                appendToCurrent(delta)
            }
        } catch {
            failure = error
        }

        // Finalise UI state
        if Task.isCancelled { return }

        if let failure {
            if var existing = current {
                existing.isStreaming = false
                existing.completedAt = Date()
                existing.errorMessage = failure.localizedDescription
                current = existing
            }
            return
        }

        let final = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !final.isEmpty else {
            if var existing = current {
                existing.isStreaming = false
                existing.completedAt = Date()
                existing.errorMessage = "DeepSeek 返回空内容"
                current = existing
            }
            return
        }

        if var existing = current {
            existing.partial = final
            existing.isStreaming = false
            existing.completedAt = Date()
            current = existing
        }

        // Persist
        let record = TranslationRecord(
            id: nil,
            documentId: documentId,
            pageIndex: snapshot.pageIndex,
            textHash: hash,
            sourceText: cleaned,
            targetText: final,
            provider: TranslationConfig.provider,
            model: model,
            createdAt: Date()
        )
        do {
            let saved = try await TranslationRepository.shared.insert(record)
            if Task.isCancelled { return }
            let handler = pendingOnSaved
            pendingOnSaved = nil
            handler?(saved)
        } catch {
            logger.error("Failed to persist translation: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Cache-hit completion: commit a per-document row if needed, then flip `current` from the
    /// optimistic streaming state to the cached result.
    private func finishFromCache(cached: TranslationRecord,
                                 hash: String,
                                 cleaned: String,
                                 snapshot: SelectionSnapshot,
                                 documentId: Int64?,
                                 model: String) async {
        let committed = await commitCachedTranslationIfNeeded(
            cached: cached,
            hash: hash,
            cleaned: cleaned,
            snapshot: snapshot,
            documentId: documentId,
            model: model
        )
        if Task.isCancelled { return }

        if var existing = current {
            existing.partial = committed.targetText
            existing.isStreaming = false
            existing.fromCache = true
            existing.completedAt = Date()
            current = existing
        }
        let handler = pendingOnSaved
        pendingOnSaved = nil
        handler?(committed)
    }

    private func commitCachedTranslationIfNeeded(cached: TranslationRecord,
                                                 hash: String,
                                                 cleaned: String,
                                                 snapshot: SelectionSnapshot,
                                                 documentId: Int64?,
                                                 model: String) async -> TranslationRecord {
        guard let documentId else { return cached }

        if let existing = try? await TranslationRepository.shared.findInDocument(
            textHash: hash,
            documentId: documentId,
            pageIndex: snapshot.pageIndex
        ) {
            return existing
        }

        let record = TranslationRecord(
            id: nil,
            documentId: documentId,
            pageIndex: snapshot.pageIndex,
            textHash: hash,
            sourceText: cleaned,
            targetText: cached.targetText,
            provider: TranslationConfig.provider,
            model: model,
            createdAt: Date()
        )
        return (try? await TranslationRepository.shared.insert(record)) ?? cached
    }

    private func appendToCurrent(_ delta: String) {
        guard var existing = current else { return }
        existing.partial.append(delta)
        current = existing
    }

    private func makeErrorOutput(snapshot: SelectionSnapshot, message: String) -> TranslationOutput {
        TranslationOutput(
            sourceText: snapshot.rawText,
            cleanedText: snapshot.rawText,
            pageIndex: snapshot.pageIndex,
            partial: "",
            isStreaming: false,
            fromCache: false,
            errorMessage: message,
            startedAt: Date(),
            completedAt: Date()
        )
    }

    // MARK: - Cache key

    static func cacheKey(cleaned: String, target: String, model: String) -> String {
        let payload = "\(cleaned)\u{1F}\(target)\u{1F}\(TranslationConfig.provider)/\(model)"
        let digest = SHA256.hash(data: Data(payload.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
