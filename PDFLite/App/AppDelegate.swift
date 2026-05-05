import AppKit
import Observation
import SwiftUI

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

    /// Make sure the active doc window is key and PDFView holds first responder. Activates the
    /// app first if needed (Space-swipe scenarios where macOS hasn't auto-activated us yet).
    /// No-ops when there's no tracked session, or the session's window isn't on the current
    /// Space (so we don't yank focus from another visible window).
    func reassertOrActivateDocumentWindow() {
        guard let session = weakActiveSession,
              let window = session.pdfView?.window,
              window.isVisible,
              window.isOnActiveSpace else {
            revision += 1
            return
        }

        if !NSApp.isActive {
            NSApp.activate(ignoringOtherApps: true)
        }
        if !window.isKeyWindow {
            window.makeKeyAndOrderFront(nil)
        }
        session.restoreReaderKeyboardFocusIfAppropriate()
        revision += 1
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var activeSpaceObserver: NSObjectProtocol?

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
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
                AppFocusState.shared.reassertOrActivateDocumentWindow()
            }
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where url.pathExtension.lowercased() == "pdf" {
            DocumentOpener.requestOpen(url: url)
        }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        AppFocusState.shared.reassertOrActivateDocumentWindow()
    }
}

/// Bridges Finder-driven open events to whichever window/session handles the document.
@MainActor
enum DocumentOpener {
    /// Multicast: each ReaderWindowView registers its session here. A pending URL is consumed by
    /// the first registered session that is empty; otherwise it falls through and the OS will
    /// likely have already opened a fresh window via WindowGroup.
    private static var pendingURLs: [URL] = []
    private static var handlers: [() -> DocumentSession?] = []

    static func requestOpen(url: URL) {
        if let handler = handlers.first(where: { $0()?.canAcceptOpen == true }),
           let session = handler() {
            session.openDocument(url: url)
            return
        }
        pendingURLs.append(url)
    }

    /// Sessions register here so they can be discovered by the open handler.
    static func register(_ session: DocumentSession) {
        handlers.append({ [weak session] in session })
        AppFocusState.shared.activate(session)
        // Drain any pending URL into the new session if it's empty.
        if session.canAcceptOpen, let url = pendingURLs.first {
            pendingURLs.removeFirst()
            session.openDocument(url: url)
        }
    }
}
