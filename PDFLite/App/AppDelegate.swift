import AppKit
import CoreGraphics
import Observation
import SwiftUI

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
        guard weakActiveSession !== session else {
            revision += 1
            return
        }
        weakActiveSession = session
        revision += 1
    }

    func reassertActiveDocumentWindow() {
        guard let session = weakActiveSession,
              let window = session.pdfView?.window,
              window.isVisible else {
            revision += 1
            return
        }

        if !window.isKeyWindow {
            window.makeKey()
        }
        session.restoreReaderKeyboardFocusIfAppropriate()
        revision += 1
    }

    func activateFrontmostDocumentWindowIfNeeded() {
        guard let session = DocumentOpener.frontmostVisibleSessionOnActiveSpace(),
              let window = session.pdfView?.window else {
            revision += 1
            return
        }

        activate(session)
        // Already-active path matters too: switching Spaces while PDFLite is the frontmost app
        // commonly leaves NSApp.isActive == true but no keyWindow, which kills @FocusedValue
        // routing for the menus. Always re-make the doc window key after a Space change.
        if !NSApp.isActive {
            NSApp.activate(ignoringOtherApps: true)
        }
        if !window.isKeyWindow {
            window.makeKeyAndOrderFront(nil)
        }
        session.restoreReaderKeyboardFocusIfAppropriate()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var activeSpaceObserver: NSObjectProtocol?

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        activeSpaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(180))
                AppFocusState.shared.activateFrontmostDocumentWindowIfNeeded()
            }
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where url.pathExtension.lowercased() == "pdf" {
            DocumentOpener.requestOpen(url: url)
        }
    }

    /// macOS Spaces / Mission Control gestures sometimes leave the app frontmost but with no
    /// key window. SwiftUI's `@FocusedValue` only routes when a scene is the key window, so the
    /// menu items (and their keyboard shortcuts) stay disabled until the user clicks the doc.
    /// Force-pick a doc window to be key whenever we activate without one.
    func applicationDidBecomeActive(_ notification: Notification) {
        AppFocusState.shared.reassertActiveDocumentWindow()
        guard NSApp.keyWindow == nil else { return }
        let candidate = NSApp.windows.first { window in
            window.isVisible
                && window.canBecomeKey
                && !(window is NSPanel)
        }
        candidate?.makeKey()
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

    static func frontmostVisibleSessionOnActiveSpace() -> DocumentSession? {
        let sessionsByWindowNumber = Dictionary(
            uniqueKeysWithValues: liveSessions().compactMap { session -> (Int, DocumentSession)? in
                guard session.readerWindowIsVisibleOnActiveSpace,
                      let windowNumber = session.readerWindowNumber else { return nil }
                return (windowNumber, session)
            }
        )
        guard !sessionsByWindowNumber.isEmpty,
              let windowInfos = CGWindowListCopyWindowInfo(
                [.optionOnScreenOnly, .excludeDesktopElements],
                kCGNullWindowID
              ) as? [[String: Any]] else {
            return nil
        }

        let pid = ProcessInfo.processInfo.processIdentifier
        for info in windowInfos {
            guard intValue(info[kCGWindowLayer as String]) == 0,
                  let ownerPID = intValue(info[kCGWindowOwnerPID as String]),
                  let windowNumber = intValue(info[kCGWindowNumber as String]) else {
                continue
            }

            if ownerPID == pid {
                if let session = sessionsByWindowNumber[windowNumber] {
                    return session
                }
                // A PDFLite panel/settings window can be above the document. Keep walking until
                // we either find the document window or hit a different app in front.
                continue
            }

            return nil
        }

        return nil
    }

    private static func liveSessions() -> [DocumentSession] {
        handlers.compactMap { $0() }
    }

    private static func intValue(_ value: Any?) -> Int? {
        if let value = value as? Int {
            return value
        }
        if let value = value as? NSNumber {
            return value.intValue
        }
        return nil
    }
}
