import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where url.pathExtension.lowercased() == "pdf" {
            DocumentOpener.requestOpen(url: url)
        }
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
        // Drain any pending URL into the new session if it's empty.
        if session.canAcceptOpen, let url = pendingURLs.first {
            pendingURLs.removeFirst()
            session.openDocument(url: url)
        }
    }
}
