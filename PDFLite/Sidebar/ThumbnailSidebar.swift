import PDFKit
import SwiftUI

/// `PDFThumbnailView` that reports a click on it to the session before PDFKit acts. A thumbnail
/// click moves the reader to another page without touching any session command or `ReaderPDFView`
/// input hook, so without this the reading-position logic only notices it through the page-change
/// fallback (see `DocumentSession.noteUserNavigation()`).
///
/// It listens with a local event monitor instead of overriding `mouseDown(with:)`: the view hosts
/// an `NSCollectionView` that handles the click itself and does not pass it up the responder
/// chain, so a `mouseDown` override here never runs for a thumbnail click.
/// https://developer.apple.com/documentation/pdfkit/pdfthumbnailview
/// https://developer.apple.com/documentation/appkit/nsevent/addlocalmonitorforevents(matching:handler:)
final class ReaderThumbnailView: PDFThumbnailView {
    /// Same contract as `ReaderPDFView.userInteractionHandler`.
    var userInteractionHandler: (() -> Void)?

    /// Written on the main thread only; `nonisolated(unsafe)` so `deinit` may read it.
    private nonisolated(unsafe) var mouseMonitor: Any?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        removeMonitor()
        guard window != nil else { return }
        // A monitor sees the event before it is dispatched, and the closure returns it untouched.
        mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            self?.noteMouseDown(event)
            return event
        }
    }

    deinit {
        removeMonitor()
    }

    /// Reports the click when it lands on this view (not merely inside its frame: a popover or
    /// sheet in front of it must not count).
    func noteMouseDown(_ event: NSEvent) {
        guard let window, event.window === window,
              let hit = window.contentView?.superview?.hitTest(event.locationInWindow),
              hit.isDescendant(of: self) else { return }
        userInteractionHandler?()
    }

    private nonisolated func removeMonitor() {
        if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }
        mouseMonitor = nil
    }
}

struct ThumbnailSidebar: NSViewRepresentable {
    @Bindable var session: DocumentSession

    func makeNSView(context: Context) -> ReaderThumbnailView {
        let thumbnail = ReaderThumbnailView()
        thumbnail.thumbnailSize = CGSize(width: 180, height: 220)
        thumbnail.backgroundColor = .clear
        thumbnail.pdfView = session.pdfView
        thumbnail.userInteractionHandler = { [weak session] in session?.noteUserNavigation() }
        return thumbnail
    }

    func updateNSView(_ thumbnail: ReaderThumbnailView, context: Context) {
        if thumbnail.pdfView !== session.pdfView {
            thumbnail.pdfView = session.pdfView
        }
    }
}
