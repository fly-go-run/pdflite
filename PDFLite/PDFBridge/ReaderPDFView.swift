import AppKit
import PDFKit

/// PDFView subclass that adds Command + scroll-wheel zoom and a right-click context menu for
/// our highlight annotations. Everything else (touchpad pinch, regular scroll, text selection,
/// most links) goes through PDFKit unchanged.
final class ReaderPDFView: PDFView {
    /// How aggressive Cmd+scroll zoom is. 0.0025 → ~1.4x per 100 px of wheel travel.
    var commandScrollZoomSensitivity: CGFloat = 0.0025
    var commandScrollZoomMin: CGFloat = 0.25
    var commandScrollZoomMax: CGFloat = 8.0

    /// Right-click on an annotation owned by us -> caller provides the menu (delete, copy text...).
    var annotationContextMenuProvider: ((PDFAnnotation) -> NSMenu?)?
    /// PDFKit performs internal link jumps itself. This hook lets the session record history
    /// immediately before PDFKit handles the click.
    var internalLinkNavigationHandler: ((PDFDestination) -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        unregisterDraggedTypes()
        // Match Skim: stay on the traditional NSView drawing path. Forcing layer-backed
        // here makes every internal PDFPageView allocate its own backing store, which
        // hurts fast-scroll throughput more than it helps.
        interpolationQuality = .low
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        unregisterDraggedTypes()
        interpolationQuality = .low
    }

    func clearTextSelection() {
        setCurrentSelection(nil, animate: false)
    }

    var scrollViewForObservation: NSScrollView? {
        documentScrollView
    }

    override func scrollWheel(with event: NSEvent) {
        // Command + scroll → zoom around the cursor. Otherwise hand back to PDFKit so
        // touchpad pinch and trackpad/wheel scrolling keep working.
        guard event.modifierFlags.contains(.command) else {
            super.scrollWheel(with: event)
            return
        }
        applyCommandScrollZoom(event)
    }

    override func mouseDown(with event: NSEvent) {
        if let destination = internalLinkDestination(at: event) {
            internalLinkNavigationHandler?(destination)
            super.mouseDown(with: event)
            return
        }

        super.mouseDown(with: event)
    }

    override func rightMouseDown(with event: NSEvent) {
        if let (_, annotation) = ourAnnotation(at: event),
           let menu = annotationContextMenuProvider?(annotation) {
            let viewPoint = convert(event.locationInWindow, from: nil)
            menu.popUp(positioning: nil, at: viewPoint, in: self)
            return
        }
        super.rightMouseDown(with: event)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        if let (_, annotation) = ourAnnotation(at: event),
           let menu = annotationContextMenuProvider?(annotation) {
            return menu
        }
        return super.menu(for: event)
    }

    /// Look up the closest annotation owned by us under the click point.
    /// Returns the page and the topmost matching annotation.
    private func ourAnnotation(at event: NSEvent) -> (PDFPage, PDFAnnotation)? {
        let viewPoint = convert(event.locationInWindow, from: nil)
        guard let page = page(for: viewPoint, nearest: true) else { return nil }
        let pagePoint = convert(viewPoint, to: page)

        if let annotation = page.annotation(at: pagePoint),
           isPDFLiteAnnotation(annotation) {
            return (page, annotation)
        }

        // PDFKit's point hit-testing is unreliable for text markup annotations with tight
        // per-line bounds. Scan nearby annotation bounds so clicks on the yellow painted area
        // still resolve to our sidecar-backed record instead of PDFKit's default menu.
        let toleranceInView: CGFloat = 10
        let offsetPoint = NSPoint(x: viewPoint.x + toleranceInView, y: viewPoint.y + toleranceInView)
        let offsetPagePoint = convert(offsetPoint, to: page)
        let toleranceX = max(abs(offsetPagePoint.x - pagePoint.x), 1)
        let toleranceY = max(abs(offsetPagePoint.y - pagePoint.y), 1)
        let searchRect = CGRect(
            x: pagePoint.x - toleranceX,
            y: pagePoint.y - toleranceY,
            width: toleranceX * 2,
            height: toleranceY * 2
        )

        for annotation in page.annotations.reversed() {
            guard isPDFLiteAnnotation(annotation) else { continue }
            if annotation.bounds.insetBy(dx: -toleranceX, dy: -toleranceY).contains(pagePoint)
                || annotation.bounds.intersects(searchRect) {
                return (page, annotation)
            }
        }

        return nil
    }

    private func isPDFLiteAnnotation(_ annotation: PDFAnnotation) -> Bool {
        AnnotationService.persistedID(from: annotation) != nil
    }

    private func internalLinkDestination(at event: NSEvent) -> PDFDestination? {
        let viewPoint = convert(event.locationInWindow, from: nil)
        guard let page = page(for: viewPoint, nearest: true) else { return nil }
        let pagePoint = convert(viewPoint, to: page)
        guard let annotation = page.annotation(at: pagePoint),
              annotation.type == "Link" else { return nil }

        if let destination = annotation.destination {
            return destination
        }

        return (annotation.action as? PDFActionGoTo)?.destination
    }

    private func applyCommandScrollZoom(_ event: NSEvent) {
        autoScales = false

        let delta = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.deltaY * 6
        guard delta != 0 else { return }

        let factor = exp(delta * commandScrollZoomSensitivity)
        let target = max(commandScrollZoomMin, min(commandScrollZoomMax, scaleFactor * factor))

        let cursorView = convert(event.locationInWindow, from: nil)
        let pageBefore = page(for: cursorView, nearest: true)
        let pagePoint = pageBefore.map { convert(cursorView, to: $0) }

        scaleFactor = target

        // Best-effort: try to keep the same page point under the cursor after zooming.
        if let page = pageBefore, let pagePoint {
            let newCursorView = convert(pagePoint, from: page)
            if let scrollView = documentScrollView {
                let dx = newCursorView.x - cursorView.x
                let dy = newCursorView.y - cursorView.y
                var origin = scrollView.contentView.bounds.origin
                origin.x += dx
                origin.y += dy
                scrollView.contentView.scroll(to: origin)
                scrollView.reflectScrolledClipView(scrollView.contentView)
            }
        }
    }

    private var documentScrollView: NSScrollView? {
        subviews.first { $0 is NSScrollView } as? NSScrollView
    }
}
