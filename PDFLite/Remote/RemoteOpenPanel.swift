import AppKit
import Observation
import os.log
import SwiftUI

/// State machine behind the "从 URL 打开" panel: parse → dedup against the library → download
/// (racing the arXiv title fetch) → land → hand off to DocumentOpener. Errors keep the panel
/// open with the input intact so the user can fix or retry.
@MainActor
@Observable
final class RemoteOpenModel {
    enum Phase: Equatable {
        case idle
        case downloading
        case failed(String)
    }

    private let logger = Logger(subsystem: "com.pdflite.app", category: "RemoteOpen")

    var input = ""
    private(set) var phase: Phase = .idle
    /// 0…1, or nil while the server hasn't declared a Content-Length (indeterminate bar).
    private(set) var progress: Double?

    @ObservationIgnored private var downloadTask: Task<Void, Never>?

    var isDownloading: Bool { phase == .downloading }
    var canStart: Bool {
        !isDownloading && !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func start() {
        guard phase != .downloading else { return }

        guard let source = RemoteDocumentURL.parse(input) else {
            phase = .failed("无法识别这个链接。支持 arXiv 链接 / 论文编号，或指向 PDF 的 http(s) 直链。")
            return
        }

        // Downloaded before? Any spelling of the same source hits the same token — open the
        // local copy with zero waiting.
        if let existing = RemoteDocumentLibrary.existingFile(token: source.dedupToken) {
            logger.info("dedup hit for \(source.dedupToken, privacy: .public)")
            finish(opening: existing)
            return
        }

        phase = .downloading
        progress = nil
        downloadTask = Task { [weak self] in
            await self?.run(source)
        }
    }

    private func run(_ source: RemoteDocumentURL) async {
        // Title fetch races the download; both are usually done within a couple of seconds and
        // a failed fetch just means the file keeps its arXiv id as its name.
        async let fetchedTitle = Self.titleIfArxiv(source)

        let downloader = RemoteDocumentDownloader()
        do {
            let tempFile = try await downloader.download(from: source.downloadURL) { [weak self] value in
                Task { @MainActor [weak self] in
                    guard let self, self.phase == .downloading else { return }
                    self.progress = value
                }
            }
            try RemoteDocumentLibrary.validatePDF(at: tempFile)
            let title = await fetchedTitle
            let landed = try RemoteDocumentLibrary.land(tempFile: tempFile, source: source, title: title)
            logger.info("landed \(landed.lastPathComponent, privacy: .public)")
            finish(opening: landed)
        } catch is CancellationError {
            phase = .idle
        } catch {
            logger.error("download failed: \(error.localizedDescription, privacy: .public)")
            let message = (error as? RemoteDocumentError)?.errorDescription
                ?? "下载失败：\(error.localizedDescription)"
            phase = .failed(message)
        }
    }

    private nonisolated static func titleIfArxiv(_ source: RemoteDocumentURL) async -> String? {
        guard let id = source.arxivID else { return nil }
        return await ArxivMetadataClient.fetchTitle(id: id)
    }

    private func finish(opening file: URL) {
        phase = .idle
        progress = nil
        input = ""
        RemoteOpenPanelController.shared.close()
        DocumentOpener.requestOpen(url: file)
    }

    func cancel() {
        downloadTask?.cancel()
        downloadTask = nil
        if phase == .downloading {
            phase = .idle
        }
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

    /// `pdflite://open?url=<encoded>` — sent by the browser extension / bookmarklet, delivered
    /// through ReaderWindowView.onOpenURL. Reuses the whole "从 URL 打开" pipeline: dedup,
    /// download with progress panel, arXiv title fetch. No-op while a download is in flight.
    static func handleDeepLink(_ url: URL) {
        guard url.scheme?.lowercased() == "pdflite",
              url.host?.lowercased() == "open",
              let target = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                  .queryItems?.first(where: { $0.name == "url" })?.value,
              !target.isEmpty
        else { return }
        shared.show(prefill: target, autoStart: true)
    }

    /// Shows the panel. With no prefill, a parseable URL sitting in the clipboard is offered as
    /// the initial input (selected, so typing replaces it). `autoStart` is used by link drops,
    /// where showing the panel and immediately downloading matches the user's intent.
    func show(prefill: String? = nil, autoStart: Bool = false) {
        let panel = ensurePanel()

        if !model.isDownloading {
            if let prefill {
                model.input = prefill
            } else if model.input.isEmpty,
                      let clipboard = NSPasteboard.general.string(forType: .string),
                      RemoteDocumentURL.parse(clipboard) != nil {
                model.input = clipboard.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        if !panel.isVisible {
            panel.center()
        }
        // Deep links arrive while the browser is frontmost — bring the panel to the user.
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)

        if autoStart, !model.isDownloading {
            model.start()
        }
    }

    func close() {
        panel?.close()
    }

    func windowWillClose(_ notification: Notification) {
        // Closing the panel abandons an in-flight download — predictable, and retrying later
        // is cheap.
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

            if case .failed(let message) = model.phase {
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
