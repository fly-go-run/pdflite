import AppKit
import PDFKit
import SwiftUI

struct PDFKitRepresentable: NSViewRepresentable {
    @Bindable var session: DocumentSession

    func makeCoordinator() -> Coordinator {
        Coordinator(session: session)
    }

    func makeNSView(context: Context) -> ReaderPDFView {
        let view = ReaderPDFView()
        view.autoScales = true
        view.displayMode = session.displayMode
        view.displayDirection = .vertical
        view.displaysPageBreaks = true
        view.pageBreakMargins = NSEdgeInsets(top: 8, left: 6, bottom: 8, right: 6)
        view.backgroundColor = NSColor.windowBackgroundColor
        view.delegate = context.coordinator

        if let document = session.document {
            view.document = document
        }

        let center = NotificationCenter.default
        center.addObserver(context.coordinator,
                           selector: #selector(Coordinator.pageChanged(_:)),
                           name: .PDFViewPageChanged,
                           object: view)
        center.addObserver(context.coordinator,
                           selector: #selector(Coordinator.scaleChanged(_:)),
                           name: .PDFViewScaleChanged,
                           object: view)
        center.addObserver(context.coordinator,
                           selector: #selector(Coordinator.selectionChanged(_:)),
                           name: .PDFViewSelectionChanged,
                           object: view)

        view.annotationContextMenuProvider = { [weak coordinator = context.coordinator] annotation in
            coordinator?.makeAnnotationContextMenu(for: annotation)
        }
        view.linkClickHandler = { [weak coordinator = context.coordinator] linkContext in
            coordinator?.handleLinkClick(linkContext) ?? .passThrough
        }
        view.plainMouseDownHandler = { [weak coordinator = context.coordinator] in
            coordinator?.session?.dismissReferencePreview()
        }
        view.userInteractionHandler = { [weak coordinator = context.coordinator] in
            coordinator?.session?.noteUserNavigation()
        }
        // SwiftUI hands over the view unsized; a pending reading-location restore waits for
        // the first real size (see DocumentSession.restoreBridgeIfNeeded).
        view.sizeBecameUsableHandler = { [weak coordinator = context.coordinator, weak view] in
            guard let view else { return }
            coordinator?.session?.restoreBridgeIfNeeded(in: view)
        }

        session.pdfView = view
        context.coordinator.attach(view: view)
        return view
    }

    func updateNSView(_ view: ReaderPDFView, context: Context) {
        context.coordinator.attach(view: view)

        // Swap document only when the underlying PDFDocument actually changed.
        if view.document !== session.document {
            view.document = session.document
        }

        if view.displayMode != session.displayMode {
            view.displayMode = session.displayMode
        }

        session.restoreBridgeIfNeeded(in: view)

        // Search highlights — driven by SearchService state. updateNSView runs on every observed
        // session change (page turns, zoom ticks, streaming translation), so the planner does the
        // work incrementally: new results get tinted once, ⌘G recolours two selections, and
        // highlightedSelections is only re-assigned when the result set itself changed.
        context.coordinator.searchTint.sync(with: session.search, to: view)
    }

    static func dismantleNSView(_ view: ReaderPDFView, coordinator: Coordinator) {
        coordinator.cancelPendingSelectionSnapshot()
        coordinator.detachScrollObserver()
        NotificationCenter.default.removeObserver(coordinator)
    }

    @MainActor
    final class Coordinator: NSObject, PDFViewDelegate {
        weak var session: DocumentSession?
        weak var view: ReaderPDFView?
        var searchTint = SearchTintPlanner()
        private let selectionDebouncer = TrailingDebouncer()
        private weak var observedClipView: NSClipView?
        private weak var observedScrollView: NSScrollView?
        private var lastScrollOrigin: CGPoint?
        private var lastScrollDirection: PDFPageWarmupDirection = .both

        init(session: DocumentSession) {
            self.session = session
        }

        func attach(view: ReaderPDFView) {
            self.view = view
            attachScrollObserver(to: view)
        }

        func detachScrollObserver() {
            let center = NotificationCenter.default
            if let observedClipView {
                center.removeObserver(
                    self,
                    name: NSView.boundsDidChangeNotification,
                    object: observedClipView
                )
            }
            if let observedScrollView {
                center.removeObserver(
                    self,
                    name: NSScrollView.willStartLiveScrollNotification,
                    object: observedScrollView
                )
                center.removeObserver(
                    self,
                    name: NSScrollView.didEndLiveScrollNotification,
                    object: observedScrollView
                )
            }
            observedClipView = nil
            observedScrollView = nil
            lastScrollOrigin = nil
            lastScrollDirection = .both
        }

        private func attachScrollObserver(to view: ReaderPDFView) {
            guard let scrollView = view.scrollViewForObservation else { return }
            let clipView = scrollView.contentView
            guard observedClipView !== clipView else { return }

            detachScrollObserver()
            observedClipView = clipView
            observedScrollView = scrollView
            lastScrollOrigin = clipView.bounds.origin
            clipView.postsBoundsChangedNotifications = true

            let center = NotificationCenter.default
            center.addObserver(
                self,
                selector: #selector(scrollBoundsChanged(_:)),
                name: NSView.boundsDidChangeNotification,
                object: clipView
            )
            // LiveScroll lifecycle: WillStart fires when finger first touches the trackpad,
            // DidEnd fires the moment the finger lifts (right before momentum kicks in).
            // DidEnd is the prime moment to prefetch — momentum still has 1-2s to fly,
            // and we want the rasters ready before pages reach the viewport.
            center.addObserver(
                self,
                selector: #selector(willStartLiveScroll(_:)),
                name: NSScrollView.willStartLiveScrollNotification,
                object: scrollView
            )
            center.addObserver(
                self,
                selector: #selector(didEndLiveScroll(_:)),
                name: NSScrollView.didEndLiveScrollNotification,
                object: scrollView
            )
        }

        @objc func pageChanged(_ notification: Notification) {
            guard let view, let session, let document = view.document,
                  let page = view.currentPage else { return }
            let index = document.index(for: page)
            session.handlePageChanged(to: index)
        }

        @objc func scaleChanged(_ notification: Notification) {
            guard let view, let session else { return }
            session.handleScaleChanged(view.scaleFactor)
        }

        @objc func selectionChanged(_ notification: Notification) {
            if session?.isApplyingSearchSelection == true {
                selectionDebouncer.cancel()
                return
            }
            // PDFKit posts this on every tick of a drag-selection. Building a full snapshot
            // (selectionsByLine + per-line text extraction) each time is wasted main-thread work
            // for intermediate states nobody sees — debounce to the trailing edge and snapshot
            // once, when the selection settles. Downstream auto-actions add their own 350ms.
            selectionDebouncer.call(after: .milliseconds(80)) { [weak self] in
                guard let self, let view = self.view, let session = self.session else { return }
                session.handleSelectionChanged(SelectionService.snapshot(from: view))
            }
        }

        func cancelPendingSelectionSnapshot() {
            selectionDebouncer.cancel()
        }

        func handleLinkClick(_ context: LinkClickContext) -> LinkClickDecision {
            guard let session else { return .passThrough }
            // First chance: numeric reference like "[12]" — show a preview instead of jumping.
            if let number = Self.referenceNumber(in: context.linkText),
               let anchor = context.screenRect,
               session.requestReferencePreview(
                    number: number,
                    anchor: anchor,
                    destination: context.destination
               ) {
                return .preview
            }
            // Otherwise behave like Smart Jump v0: record current page on the back stack and let
            // PDFKit follow the destination.
            session.recordInternalLinkNavigation(to: context.destination)
            return .jumpAndRecord
        }

        /// Whole citation tokens only: numbers inside section titles are ordinary links.
        static func referenceNumber(in text: String?) -> Int? {
            guard let text else { return nil }
            let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
            let range = NSRange(value.startIndex..., in: value)
            guard let match = referencePattern.firstMatch(in: value, range: range) else { return nil }
            let numberRange = match.range(at: 1).location == NSNotFound
                ? match.range(at: 2) : match.range(at: 1)
            return Int((value as NSString).substring(with: numberRange))
        }

        private static let referencePattern = try! NSRegularExpression(
            pattern: #"^(?:\[\s*(\d{1,3})(?:\s*[,–-]\s*\d{1,3})*\s*\]|(\d{1,3})(?:\s*[,–-]\s*\d{1,3})*)$"#
        )

        @objc private func scrollBoundsChanged(_ notification: Notification) {
            guard let clipView = notification.object as? NSClipView else { return }
            let origin = clipView.bounds.origin
            defer { lastScrollOrigin = origin }

            guard let previous = lastScrollOrigin else { return }
            let dy = origin.y - previous.y
            let dx = origin.x - previous.x
            let moved = abs(dx) + abs(dy)
            guard moved > 0.5 else { return }

            // Track direction continuously so DidEndLiveScroll can prefetch the right side.
            if abs(dy) >= abs(dx) {
                lastScrollDirection = dy >= 0 ? .forward : .backward
            }

            session?.handleScrollActivity()
        }

        @objc private func willStartLiveScroll(_ notification: Notification) {
            // Finger just touched the trackpad (or grabbed the scroller): a user-driven scroll,
            // unlike the bounds changes PDFKit makes on its own while laying out.
            session?.noteUserNavigation()
            // Direction unknown — warmup both sides at low priority.
            session?.requestPageWarmup(direction: .both, delayMilliseconds: 60)
        }

        @objc private func didEndLiveScroll(_ notification: Notification) {
            // Finger lifted; momentum begins. Prefetch aggressively in the known direction so the
            // pages momentum is about to reveal are already cached before they enter the viewport.
            session?.requestPageWarmup(direction: lastScrollDirection, delayMilliseconds: 0)
        }

        func makeAnnotationContextMenu(for annotation: PDFAnnotation) -> NSMenu? {
            guard let session,
                  let groupId = session.annotationService?.groupId(for: annotation) else { return nil }
            let menu = NSMenu(title: "Annotation")
            let deleteItem = NSMenuItem(
                title: "删除高亮",
                action: #selector(handleDelete(_:)),
                keyEquivalent: ""
            )
            deleteItem.target = self
            deleteItem.representedObject = groupId
            menu.addItem(deleteItem)

            let copyItem = NSMenuItem(
                title: "复制原文",
                action: #selector(handleCopyText(_:)),
                keyEquivalent: ""
            )
            copyItem.target = self
            copyItem.representedObject = groupId
            menu.addItem(copyItem)

            return menu
        }

        @objc private func handleDelete(_ sender: NSMenuItem) {
            guard let groupId = sender.representedObject as? String, let session else { return }
            session.deleteAnnotation(groupId: groupId)
        }

        @objc private func handleCopyText(_ sender: NSMenuItem) {
            guard let groupId = sender.representedObject as? String else { return }
            session?.copyAnnotationText(groupId: groupId)
        }
    }
}
