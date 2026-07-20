import AppKit
import Observation
import os.log
import SwiftUI
import UniformTypeIdentifiers

/// Tracks the most recently activated document session so menus can fall back to it during the
/// brief window after macOS makes our doc window key but before SwiftUI's `@FocusedValue` has
/// re-routed. Also owns the "make sure the doc window is key + the PDFView is first responder"
/// routine that AppDelegate calls when the app activates or the user swipes Spaces.
@MainActor
@Observable
final class AppFocusState {
    static let shared = AppFocusState()

    private(set) var revision = 0
    @ObservationIgnored private weak var weakActiveSession: DocumentSession?
    @ObservationIgnored private var fullScreenTransitioningWindowIDs: Set<ObjectIdentifier> = []

    var activeSession: DocumentSession? {
        _ = revision
        return weakActiveSession
    }

    func activate(_ session: DocumentSession) {
        if weakActiveSession !== session {
            weakActiveSession = session
        }
        revision += 1
    }

    func setFullScreenTransitioning(_ window: NSWindow, _ transitioning: Bool) {
        let id = ObjectIdentifier(window)
        if transitioning {
            fullScreenTransitioningWindowIDs.insert(id)
        } else {
            fullScreenTransitioningWindowIDs.remove(id)
        }
        revision += 1
    }

    /// Re-assert key-window + first-responder for the active doc window when PDFLite is already
    /// the foreground app. Triggered after Space swipes, full-screen transitions, and app
    /// activation — without it menu shortcuts go dead until the user clicks the document.
    /// No-ops when PDFLite isn't active, so a Space swipe that happens to land on a Space
    /// containing one of our windows doesn't steal focus from whatever app the user is using.
    func reassertDocumentWindowFocus() {
        guard NSApp.isActive,
              let session = weakActiveSession,
              let window = session.pdfView?.window,
              window.isVisible,
              window.isOnActiveSpace,
              !fullScreenTransitioningWindowIDs.contains(ObjectIdentifier(window)) else {
            revision += 1
            return
        }

        if !window.isKeyWindow {
            window.makeKeyAndOrderFront(nil)
        }
        session.restoreReaderKeyboardFocusIfAppropriate()
        revision += 1
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let logger = Logger(subsystem: "com.pdflite.app", category: "AppDelegate")
    private var activeSpaceObserver: NSObjectProtocol?
    private var fullScreenObservers: [NSObjectProtocol] = []

    deinit {
        if let activeSpaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(activeSpaceObserver)
        }
        let center = NotificationCenter.default
        for observer in fullScreenObservers {
            center.removeObserver(observer)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Sync window chrome with the stored appearance choice before any window draws.
        ReaderSettings.shared.applyAppAppearance()

        // Space switches don't fire applicationDidBecomeActive when PDFLite is already frontmost
        // — we have to listen for the workspace notification ourselves and re-assert key window
        // / first responder, otherwise menu shortcuts go dead until the user clicks the doc.
        // Wait a beat for the new Space's window state to settle before checking.
        activeSpaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(180))
                AppFocusState.shared.reassertDocumentWindowFocus()
            }
        }

        let center = NotificationCenter.default
        fullScreenObservers = [
            center.addObserver(
                forName: NSWindow.willEnterFullScreenNotification,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                self?.handleFullScreenTransition(notification, transitioning: true)
            },
            center.addObserver(
                forName: NSWindow.willExitFullScreenNotification,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                self?.handleFullScreenTransition(notification, transitioning: true)
            },
            center.addObserver(
                forName: NSWindow.didEnterFullScreenNotification,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                self?.handleFullScreenTransition(notification, transitioning: false, reassertAfter: true)
            },
            center.addObserver(
                forName: NSWindow.didExitFullScreenNotification,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                self?.handleFullScreenTransition(notification, transitioning: false, reassertAfter: true)
            }
        ]
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        logger.info("application(open:) received \(urls.map(\.absoluteString).joined(separator: " "), privacy: .public)")
        for url in urls {
            if url.isFileURL {
                if url.pathExtension.lowercased() == "pdf" {
                    DocumentOpener.requestOpen(url: url)
                }
            } else if url.scheme?.lowercased() == "pdflite" {
                // Normally SwiftUI's URL-event handler consumes pdflite:// URLs before this
                // method ever runs (deep links arrive via ReaderWindowView.onOpenURL). Kept as
                // a harmless fallback: handleDeepLink is idempotent while a download runs.
                RemoteOpenPanelController.handleDeepLink(url)
            }
        }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        AppFocusState.shared.reassertDocumentWindowFocus()
        // Background launches defer SwiftUI's initial window until first activation; if it
        // still hasn't materialized shortly after, force one so the app is never a windowless
        // Dock icon. Delayed so we don't race the initial window SwiftUI may be creating.
        DocumentOpener.scheduleBootstrapCheck()
    }

    private func handleFullScreenTransition(_ notification: Notification,
                                            transitioning: Bool,
                                            reassertAfter: Bool = false) {
        guard let window = notification.object as? NSWindow else { return }
        Task { @MainActor in
            AppFocusState.shared.setFullScreenTransitioning(window, transitioning)
            guard reassertAfter else { return }
            try? await Task.sleep(for: .milliseconds(120))
            AppFocusState.shared.reassertDocumentWindowFocus()
        }
    }
}

/// Routes every "open this PDF" request — Finder, ⌘O, Open Recent, bookshelf, drag & drop — to
/// the right window: a window already showing the file gets focused, an empty window gets
/// reused, and otherwise a fresh window is spawned. Documents are never silently replaced.
@MainActor
enum DocumentOpener {
    private static let logger = Logger(subsystem: "com.pdflite.app", category: "DocumentOpener")
    private static var pendingURLs: [URL] = []
    private static var handlers: [() -> DocumentSession?] = []
    /// True while a bootstrap window request is in flight — window materialization takes
    /// ~100ms, during which a second "no windows yet!" check must not fire another one.
    private static var bootstrapInFlight = false
    /// Spawns a fresh reader window (wired to SwiftUI's openWindow by ReaderWindowView).
    static var spawnWindow: (() -> Void)?

    static func requestOpen(url: URL) {
        let standardized = url.standardizedFileURL
        pruneHandlers()
        logger.info("requestOpen \(standardized.lastPathComponent, privacy: .public): sessions=\(liveSessions().count) pending=\(pendingURLs.count) spawnWired=\(spawnWindow != nil)")

        // Already open in some window? Focus it instead of opening a duplicate.
        if let existing = liveSessions().first(where: { $0.fileURL == standardized }) {
            existing.hostWindow?.makeKeyAndOrderFront(nil)
            return
        }

        if let empty = liveSessions().first(where: { $0.canAcceptOpen }) {
            empty.openDocument(url: standardized)
            empty.hostWindow?.makeKeyAndOrderFront(nil)
            return
        }

        pendingURLs.append(standardized)
        if spawnWindow != nil {
            spawnWindow?()
        } else {
            // No window has ever appeared (cold launch). SwiftUI usually creates the initial
            // window itself within a few hundred ms — check later instead of racing it, or we
            // end up with a duplicate empty window burying the document tab.
            scheduleBootstrapCheck()
        }
    }

    /// Delayed "is there still no window?" check. Gives SwiftUI's own initial window time to
    /// materialize before concluding it was skipped (which happens when a cold launch's odoc
    /// event beats scene setup).
    static func scheduleBootstrapCheck() {
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(800))
            bootstrapWindowIfNeeded()
        }
    }

    /// Deterministically ask SwiftUI for a reader window when none exists. The pdflite://
    /// scheme is the only external event the WindowGroup accepts, so opening it always
    /// materializes a reader window — even when openWindow isn't wired up yet.
    private static func bootstrapWindowIfNeeded() {
        pruneHandlers()
        logger.info("bootstrapWindowIfNeeded: sessions=\(liveSessions().count) pending=\(pendingURLs.count) inFlight=\(bootstrapInFlight)")
        guard liveSessions().isEmpty, !bootstrapInFlight,
              let url = URL(string: "pdflite://reader") else { return }
        bootstrapInFlight = true
        NSWorkspace.shared.open(url)
        // Failsafe: if no window ever registers (open failed), release the latch.
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            bootstrapInFlight = false
        }
    }

    /// Shared open panel. Multi-selection: the preferred (initiating) session takes the first
    /// file if it's empty; every other file routes through requestOpen (new windows as needed).
    static func presentOpenPanel(preferring preferred: DocumentSession? = nil) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType.pdf]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.begin { [weak preferred] response in
            guard response == .OK else { return }
            let urls = panel.urls
            Task { @MainActor in
                for url in urls {
                    if let preferred, preferred.canAcceptOpen {
                        preferred.openDocument(url: url)
                    } else {
                        requestOpen(url: url)
                    }
                }
            }
        }
    }

    /// Sessions register here so they can be discovered by the open handler.
    static func register(_ session: DocumentSession) {
        pruneHandlers()
        handlers.append({ [weak session] in session })
        bootstrapInFlight = false
        logger.info("register: sessions=\(handlers.count) canAccept=\(session.canAcceptOpen) pending=\(pendingURLs.count)")
        AppFocusState.shared.activate(session)
        // Drain any pending URL into the new session if it's empty. URLs can queue up before
        // any window exists (cold launch with documents while the app starts in the
        // background), so after taking one, keep spawning windows until the queue is empty.
        if session.canAcceptOpen, !pendingURLs.isEmpty {
            let url = pendingURLs.removeFirst()
            session.openDocument(url: url)
            // A sibling empty window created in the same launch burst may hold key status —
            // surface the tab that actually has the document.
            DispatchQueue.main.async { [weak session] in
                session?.hostWindow?.makeKeyAndOrderFront(nil)
            }
        }
        if !pendingURLs.isEmpty {
            spawnWindow?()
        }
    }

    private static func liveSessions() -> [DocumentSession] {
        handlers.compactMap { $0() }
    }

    private static func pruneHandlers() {
        handlers.removeAll { $0() == nil }
    }
}
