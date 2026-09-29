import AppKit
import Observation
import os.log
import SwiftUI

/// State machine behind the "从 URL 打开" panel: parse → dedup against the library → download
/// (racing the arXiv title fetch) → land → hand off to DocumentOpener. Requests that arrive while
/// a download is running wait in a FIFO queue instead of being dropped; a failure is reported and
/// the queue moves on to the next item. Errors keep the panel open with the failing input intact
/// so the user can fix or retry.
@MainActor
@Observable
final class RemoteOpenModel {
    /// One accepted request. `title` has already been vetted by `sanitizedDeepLinkTitle`.
    struct Job: Equatable {
        /// Distinguishes a re-submitted identical request from the stale run it replaced, so a
        /// cancelled download's late completion can never be applied to the new one.
        let id = UUID()
        let raw: String
        let source: RemoteDocumentURL
        let title: String?

        /// Short name for messages ("<label>：服务器返回了 HTTP 404。").
        var label: String {
            let name = title ?? source.fallbackName
            return name.count > 40 ? String(name.prefix(40)) + "…" : name
        }
    }

    enum SubmitOutcome: Equatable {
        /// Unparseable. Shown in the field (idle) or recorded as a failure line (busy).
        case invalid
        /// Already in the library — opened right away, nothing to download.
        case openedExisting
        /// Nothing was running; this request is downloading now.
        case started
        /// A download is running; this request waits its turn.
        case queued
        /// The same source is already downloading or waiting.
        case duplicate
    }

    /// Downloads and lands one source, returning the file in the library. Injected so the queue
    /// logic is testable without a network.
    typealias Download = @Sendable (
        RemoteDocumentURL, String?, @escaping @Sendable (Double?) -> Void
    ) async throws -> URL

    private let logger = Logger(subsystem: "com.pdflite.app", category: "RemoteOpen")
    @ObservationIgnored private let download: Download
    @ObservationIgnored private let existingFile: (String) -> URL?
    @ObservationIgnored private let openFile: @MainActor (URL) -> Void
    @ObservationIgnored private let closePanel: @MainActor () -> Void

    /// Mirrors what is downloading (or the last failed request, for retry) — also what the user
    /// types when submitting from the panel.
    var input = ""
    /// The request being downloaded right now.
    private(set) var current: Job?
    /// Requests waiting behind `current`, oldest first.
    private(set) var queue: [Job] = []
    /// 0…1, or nil while the server hasn't declared a Content-Length (indeterminate bar).
    private(set) var progress: Double?
    /// One line per failed request in this run — kept visible while the queue moves on.
    private(set) var failures: [String] = []
    /// Set when the panel's own text field holds something unparseable.
    private(set) var inputError: String?

    @ObservationIgnored private var downloadTask: Task<Void, Never>?
    @ObservationIgnored private var lastFailedInput: String?

    init(download: @escaping Download = { source, title, progress in
             try await RemoteDocumentFetch.downloadAndLand(source: source, suppliedTitle: title,
                                                           progress: progress)
         },
         existingFile: @escaping (String) -> URL? = { RemoteDocumentLibrary.existingFile(token: $0) },
         openFile: @escaping @MainActor (URL) -> Void = { DocumentOpener.requestOpen(url: $0) },
         closePanel: @escaping @MainActor () -> Void = { RemoteOpenPanelController.shared.close() }) {
        self.download = download
        self.existingFile = existingFile
        self.openFile = openFile
        self.closePanel = closePanel
    }

    var isDownloading: Bool { current != nil }
    var queuedCount: Int { queue.count }
    var canStart: Bool {
        !isDownloading && !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// "打开" in the panel: submits whatever is in the text field.
    func start() {
        guard canStart else { return }
        if submit(raw: input) == .openedExisting {
            input = ""
            closePanel()
        }
    }

    /// Single entry for every "open this URL" request — panel field, deep link, dropped link.
    /// Dedup against the library comes first so a hit never waits behind a download.
    @discardableResult
    func submit(raw rawInput: String, title suppliedTitle: String? = nil) -> SubmitOutcome {
        let raw = rawInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let source = RemoteDocumentURL.parse(raw) else {
            let message = "无法识别这个链接。支持 arXiv 链接 / 论文编号，或指向 PDF 的 http(s) 直链。"
            if isDownloading {
                // The field belongs to the running download; don't lose the request silently.
                failures.append("\(raw.prefix(60))：\(message)")
            } else {
                input = raw
                inputError = message
            }
            return .invalid
        }
        inputError = nil

        let token = source.dedupToken
        let job = Job(raw: raw, source: source,
                      title: RemoteDocumentLibrary.sanitizedDeepLinkTitle(suppliedTitle))

        if !isDownloading {
            // Fresh run: last run's messages have been seen.
            failures = []
            lastFailedInput = nil
        }
        // A library hit opens at once — even mid-download, never waiting behind the queue.
        if let existing = existingFile(token) {
            logger.info("dedup hit for \(token, privacy: .public)")
            openFile(existing)
            return .openedExisting
        }

        if isDownloading {
            let pending = [current].compactMap { $0 } + queue
            if pending.contains(where: { $0.source.dedupToken == token }) { return .duplicate }
            queue.append(job)
            logger.info("queued \(token, privacy: .public), \(self.queue.count) waiting")
            return .queued
        }

        run(job)
        return .started
    }

    private func run(_ job: Job) {
        current = job
        progress = nil
        input = job.raw
        let download = self.download
        let report: @Sendable (Double?) -> Void = { [weak self] value in
            Task { @MainActor [weak self] in
                guard let self, self.current == job else { return }
                self.progress = value
            }
        }
        downloadTask = Task { [weak self] in
            do {
                let landed = try await download(job.source, job.title, report)
                self?.complete(job, result: .success(landed))
            } catch is CancellationError {
                // cancel() has already reset the state.
            } catch {
                self?.complete(job, result: .failure(error))
            }
        }
    }

    private func complete(_ job: Job, result: Result<URL, Error>) {
        guard current == job else { return } // cancelled while finishing
        current = nil
        progress = nil
        downloadTask = nil
        switch result {
        case .success(let landed):
            logger.info("landed \(landed.lastPathComponent, privacy: .public)")
            openFile(landed)
        case .failure(let error):
            logger.error("download failed: \(error.localizedDescription, privacy: .public)")
            let message = (error as? RemoteDocumentError)?.errorDescription
                ?? "下载失败：\(error.localizedDescription)"
            failures.append("\(job.label)：\(message)")
            lastFailedInput = job.raw
        }
        advance()
    }

    /// Start the next waiting request, or wrap up. A quiet run closes the panel; if anything
    /// failed it stays open with the last failing input in the field for a retry.
    private func advance() {
        while !queue.isEmpty {
            let next = queue.removeFirst()
            if let existing = existingFile(next.source.dedupToken) {
                openFile(existing)
                continue
            }
            run(next)
            return
        }
        if failures.isEmpty {
            input = ""
            closePanel()
        } else if let lastFailedInput {
            input = lastFailedInput
        }
    }

    /// Abandons the running download and everything queued behind it. Reached when the panel
    /// closes — predictable, and retrying later is cheap.
    func cancel() {
        downloadTask?.cancel()
        downloadTask = nil
        current = nil
        queue = []
        failures = []
        inputError = nil
        progress = nil
    }
}

/// Owns the standalone "从 URL 打开" NSPanel. Deliberately plain AppKit — a SwiftUI scene here
/// would have to fight the WindowGroup's handlesExternalEvents / tabbing arrangements, and a
/// panel needs neither.
@MainActor
final class RemoteOpenPanelController: NSObject, NSWindowDelegate {
    static let shared = RemoteOpenPanelController()

    let model = RemoteOpenModel()
    private var panel: NSPanel?

    /// `pdflite://open?url=<encoded>[&title=<encoded>]` — sent by the browser extension /
    /// bookmarklet. `title` is optional (older links and the bookmarklet omit it) and untrusted.
    static func parseDeepLink(_ url: URL) -> (target: String, title: String?)? {
        guard url.scheme?.lowercased() == "pdflite",
              url.host?.lowercased() == "open",
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              let target = items.first(where: { $0.name == "url" })?.value,
              !target.isEmpty
        else { return nil }
        return (target, items.first(where: { $0.name == "title" })?.value)
    }

    /// Delivered through ReaderWindowView.onOpenURL. Reuses the whole "从 URL 打开" pipeline:
    /// dedup, download with progress panel, queueing while busy, arXiv title fetch.
    static func handleDeepLink(_ url: URL) {
        guard let link = parseDeepLink(url) else { return }
        shared.open(link.target, title: link.title)
    }

    /// Programmatic "open this URL" (deep links, dropped links). Already-downloaded papers open
    /// straight from the library without ever showing the panel; the panel only appears when
    /// there is a download to watch, a queue to see or an error to read.
    func open(_ raw: String, title: String? = nil) {
        switch model.submit(raw: raw, title: title) {
        case .openedExisting:
            // The browser is frontmost; the document window was ordered front but the app
            // itself still has to be brought along.
            NSApp.activate(ignoringOtherApps: true)
        case .invalid, .started, .queued, .duplicate:
            present()
        }
    }

    /// Shows the panel. With no prefill, a parseable URL sitting in the clipboard is offered as
    /// the initial input (selected, so typing replaces it). `autoStart` is used by link drops,
    /// where downloading immediately matches the user's intent — those go through `open`.
    func show(prefill: String? = nil, autoStart: Bool = false) {
        if autoStart, let prefill {
            open(prefill)
            return
        }

        if !model.isDownloading {
            if let prefill {
                model.input = prefill
            } else if model.input.isEmpty,
                      let clipboard = NSPasteboard.general.string(forType: .string),
                      RemoteDocumentURL.parse(clipboard) != nil {
                model.input = clipboard.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        present()

        if autoStart, !model.isDownloading {
            model.start()
        }
    }

    private func present() {
        let panel = ensurePanel()
        if !panel.isVisible {
            panel.center()
        }
        // Deep links arrive while the browser is frontmost — bring the panel to the user.
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    func close() {
        panel?.close()
    }

    func windowWillClose(_ notification: Notification) {
        // Closing the panel abandons an in-flight download and anything queued behind it.
        model.cancel()
    }

    private func ensurePanel() -> NSPanel {
        if let panel { return panel }
        let hosting = NSHostingController(rootView: RemoteOpenView(model: model))
        let created = NSPanel(contentViewController: hosting)
        created.title = "从 URL 打开"
        created.styleMask = [.titled, .closable]
        created.isReleasedWhenClosed = false
        created.delegate = self
        panel = created
        return created
    }
}

struct RemoteOpenView: View {
    @Bindable var model: RemoteOpenModel
    @FocusState private var inputFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField("arXiv 链接 / 论文编号，或 PDF 直链", text: $model.input)
                .textFieldStyle(.roundedBorder)
                .focused($inputFocused)
                .onSubmit { model.start() }
                .disabled(model.isDownloading)

            if let message = model.inputError {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // Failed requests stay listed while the queue keeps moving, so none goes unnoticed.
            ForEach(Array(model.failures.suffix(3).enumerated()), id: \.offset) { _, message in
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if model.isDownloading {
                HStack(spacing: 10) {
                    if let progress = model.progress {
                        ProgressView(value: progress)
                        Text("\(Int(progress * 100))%")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                            .frame(width: 36, alignment: .trailing)
                    } else {
                        ProgressView()
                            .progressViewStyle(.linear)
                        Text("下载中")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if model.queuedCount > 0 {
                Text("还有 \(model.queuedCount) 篇等待")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Spacer()
                Button("取消") {
                    RemoteOpenPanelController.shared.close()
                }
                .keyboardShortcut(.cancelAction)
                Button(model.isDownloading ? "下载中…" : "打开") {
                    model.start()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!model.canStart)
            }
        }
        .padding(16)
        .frame(width: 460)
        .onAppear {
            inputFocused = true
        }
    }
}
