import AppKit
import PDFKit
import XCTest

/// A thumbnail click counts as the user taking control of the viewport (`ReaderThumbnailView`).
///
/// The click is never delivered through `super.mouseDown` here: the PDFKit view hosts an
/// `NSCollectionView` whose `mouseDown` runs a tracking loop and swallows the event, and a
/// never-ordered window drops real mouse dispatch anyway. So the tests feed events to the
/// reporting logic directly (`noteMouseDown`) and, for the monitor's install/remove lifecycle,
/// through `NSApp.sendEvent` — the local event monitor runs there, before any dispatch, and the
/// window is invisible so nothing is delivered to a view. Windows are transparent and never
/// ordered front; documents are synthetic.
@MainActor
final class ThumbnailClickTests: XCTestCase {
    private var windows: [NSWindow] = []

    override func tearDown() async throws {
        for window in windows { window.contentView = nil; window.close() }
        windows = []
    }

    // MARK: - Helpers

    private func makeDocument(pages: Int = 4) throws -> PDFDocument {
        let data = NSMutableData()
        let consumer = try XCTUnwrap(CGDataConsumer(data: data))
        var box = CGRect(x: 0, y: 0, width: 600, height: 900)
        let context = try XCTUnwrap(CGContext(consumer: consumer, mediaBox: &box, nil))
        for index in 0..<pages {
            context.beginPDFPage(nil)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
            ("Page \(index)" as NSString).draw(at: CGPoint(x: 60, y: 800),
                                               withAttributes: [.font: NSFont.systemFont(ofSize: 16)])
            NSGraphicsContext.restoreGraphicsState()
            context.endPDFPage()
        }
        context.closePDF()
        return try XCTUnwrap(PDFDocument(data: data as Data))
    }

    private func makeWindow(size: CGSize = CGSize(width: 400, height: 600)) -> NSWindow {
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.alphaValue = 0
        window.ignoresMouseEvents = true
        window.hasShadow = false
        windows.append(window)
        return window
    }

    /// A thumbnail strip occupying the left 220pt of a 400 × 600 window, with its document loaded.
    private func makeThumbnail(in window: NSWindow) throws -> ReaderThumbnailView {
        let pdfView = PDFView(frame: CGRect(x: 0, y: 0, width: 600, height: 500))
        pdfView.document = try makeDocument()
        let container = NSView(frame: CGRect(origin: .zero, size: window.frame.size))
        let thumbnail = ReaderThumbnailView(frame: CGRect(x: 0, y: 0, width: 220, height: 600))
        thumbnail.thumbnailSize = CGSize(width: 180, height: 220)
        thumbnail.pdfView = pdfView
        container.addSubview(thumbnail)
        window.contentView = container
        container.layoutSubtreeIfNeeded()
        return thumbnail
    }

    private func mouseDown(at point: CGPoint, in window: NSWindow) throws -> NSEvent {
        try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: point,
                                         modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                         windowNumber: window.windowNumber, context: nil,
                                         eventNumber: 1, clickCount: 1, pressure: 1))
    }

    // MARK: - Reporting

    func testClickOnTheThumbnailIsReported() throws {
        let window = makeWindow()
        let thumbnail = try makeThumbnail(in: window)
        var reports = 0
        thumbnail.userInteractionHandler = { reports += 1 }

        thumbnail.noteMouseDown(try mouseDown(at: CGPoint(x: 110, y: 300), in: window))

        XCTAssertEqual(reports, 1)
    }

    func testClickOutsideTheThumbnailIsNotReported() throws {
        let window = makeWindow()
        let thumbnail = try makeThumbnail(in: window)
        var reports = 0
        thumbnail.userInteractionHandler = { reports += 1 }

        // The window is wider than the strip: x = 300 is the reading area's side of the divider.
        thumbnail.noteMouseDown(try mouseDown(at: CGPoint(x: 300, y: 300), in: window))

        XCTAssertEqual(reports, 0)
    }

    func testClickOnSomethingCoveringTheThumbnailIsNotReported() throws {
        let window = makeWindow()
        let thumbnail = try makeThumbnail(in: window)
        var reports = 0
        thumbnail.userInteractionHandler = { reports += 1 }
        // A popover-like view in front of the strip's lower half.
        let overlay = NSView(frame: CGRect(x: 0, y: 0, width: 220, height: 200))
        window.contentView?.addSubview(overlay)

        thumbnail.noteMouseDown(try mouseDown(at: CGPoint(x: 110, y: 100), in: window))
        XCTAssertEqual(reports, 0, "The click hit the overlay, not the thumbnails")

        thumbnail.noteMouseDown(try mouseDown(at: CGPoint(x: 110, y: 400), in: window))
        XCTAssertEqual(reports, 1, "The uncovered part of the strip still reports")
    }

    func testClickInAnotherWindowIsNotReported() throws {
        let window = makeWindow()
        let thumbnail = try makeThumbnail(in: window)
        let other = makeWindow()
        other.contentView = NSView(frame: CGRect(x: 0, y: 0, width: 400, height: 600))
        var reports = 0
        thumbnail.userInteractionHandler = { reports += 1 }

        thumbnail.noteMouseDown(try mouseDown(at: CGPoint(x: 110, y: 300), in: other))

        XCTAssertEqual(reports, 0)
    }

    // MARK: - Monitor lifecycle

    func testMonitorReportsWhileAttachedAndStopsAfterDetaching() throws {
        let window = makeWindow()
        let thumbnail = try makeThumbnail(in: window)
        var reports = 0
        thumbnail.userInteractionHandler = { reports += 1 }
        let click = try mouseDown(at: CGPoint(x: 110, y: 300), in: window)

        NSApp.sendEvent(click)
        XCTAssertEqual(reports, 1, "Attached to a window: the local monitor reports the click")

        thumbnail.removeFromSuperview()
        NSApp.sendEvent(click)
        XCTAssertEqual(reports, 1, "Detached: no monitor is left behind")
    }

    func testReattachingDoesNotDoubleReport() throws {
        let window = makeWindow()
        let thumbnail = try makeThumbnail(in: window)
        var reports = 0
        thumbnail.userInteractionHandler = { reports += 1 }
        let container = try XCTUnwrap(window.contentView)

        thumbnail.removeFromSuperview()
        container.addSubview(thumbnail)
        thumbnail.frame = CGRect(x: 0, y: 0, width: 220, height: 600)
        NSApp.sendEvent(try mouseDown(at: CGPoint(x: 110, y: 300), in: window))

        XCTAssertEqual(reports, 1, "One click, one report — the old monitor must be gone")
    }

    func testReplacingTheWindowContentRemovesTheMonitor() throws {
        // The window-teardown path: the thumbnail is never removed from its superview explicitly,
        // its whole tree just leaves the window.
        let window = makeWindow()
        let thumbnail = try makeThumbnail(in: window)
        var reports = 0
        thumbnail.userInteractionHandler = { reports += 1 }

        window.contentView = NSView(frame: CGRect(x: 0, y: 0, width: 400, height: 600))
        NSApp.sendEvent(try mouseDown(at: CGPoint(x: 110, y: 300), in: window))

        XCTAssertEqual(reports, 0)
        XCTAssertNil(thumbnail.window)
    }
}
