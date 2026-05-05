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

        // First-time-after-open hand-off: restore annotations + jump to last page + scale.
        if let payload = session.consumeBridgeRestore() {
            session.annotationService?.restore(records: payload.annotations)

            if let scale = payload.scale, scale > 0 {
                view.autoScales = false
                view.scaleFactor = scale
            }

            if let document = view.document,
               payload.page >= 0,
               payload.page < document.pageCount,
               let page = document.page(at: payload.page) {
                view.go(to: page)
            }
        }

        // Search highlights — driven by SearchService state.
        let highlighted = session.search.results
        if !highlighted.isEmpty {
            for sel in highlighted { sel.color = .yellow }
            if context.coordinator.lastAppliedSearchRevision != session.search.navigationRevision,
               let current = session.search.currentSelection() {
                context.coordinator.lastAppliedSearchRevision = session.search.navigationRevision
                current.color = .orange
                view.setCurrentSelection(current, animate: false)
                // Route through session.goToSelection so the pre-jump location goes onto the
                // back stack — Cmd-[ then returns to where the user was before searching.
                session.goToSelection(current)
            }
            view.highlightedSelections = highlighted
        } else {
            context.coordinator.lastAppliedSearchRevision = session.search.navigationRevision
            view.highlightedSelections = nil
        }
    }

    static func dismantleNSView(_ view: ReaderPDFView, coordinator: Coordinator) {
        coordinator.detachScrollObserver()
        NotificationCenter.default.removeObserver(coordinator)
    }

    @MainActor
    final class Coordinator: NSObject, PDFViewDelegate {
        weak var session: DocumentSession?
        weak var view: ReaderPDFView?
        var lastAppliedSearchRevision: Int = -1
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
            guard let view, let session else { return }
            session.handleSelectionChanged(SelectionService.snapshot(from: view))
        }

        func handleLinkClick(_ context: LinkClickContext) -> LinkClickDecision {
            guard let session else { return .passThrough }
            // First chance: numeric reference like "[12]" — show a preview instead of jumping.
            if let number = referenceNumber(in: context.linkText),
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

        /// Pull the first plausible reference number out of the link's text. PDF link annotations
        /// often wrap only the digits ("12") rather than the visible "[12]", and grouped citations
        /// can be "[12, 13]" or "12, 13". Take the first number we find. False positives (page-number
        /// links, TOC links) are harmless: ReferenceIndex returns nil for them, and the caller
        /// falls through to .jumpAndRecord.
        private func referenceNumber(in text: String?) -> Int? {
            guard let text, !text.isEmpty else { return nil }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            let range = NSRange(location: 0, length: (trimmed as NSString).length)
            guard let match = Coordinator.referencePattern.firstMatch(in: trimmed, range: range) else {
                return nil
            }
            let numberRange = match.range(at: 1)
            guard numberRange.location != NSNotFound else { return nil }
            return Int((trimmed as NSString).substring(with: numberRange))
        }

        // First number found anywhere in the text. Matches "[12]", "12", "[12, 13]", "12-15"
        // alike — we only care about the first integer. Keep the digit cap small (1-3) so we
        // don't try to look up a 5-digit page anchor.
        // swiftlint:disable:next force_try
        private static let referencePattern = try! NSRegularExpression(pattern: #"(\d{1,3})"#)

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
            // Finger just touched the trackpad. Direction unknown — warmup both sides at low priority.
            session?.requestPageWarmup(direction: .both, delayMilliseconds: 60)
        }

        @objc private func didEndLiveScroll(_ notification: Notification) {
            // Finger lifted; momentum begins. Prefetch aggressively in the known direction so the
            // pages momentum is about to reveal are already cached before they enter the viewport.
            session?.requestPageWarmup(direction: lastScrollDirection, delayMilliseconds: 0)
        }

        func makeAnnotationContextMenu(for annotation: PDFAnnotation) -> NSMenu? {
            guard let session,
                  let id = session.annotationService?.id(for: annotation) else { return nil }
            let menu = NSMenu(title: "Annotation")
            let deleteItem = NSMenuItem(
                title: "删除高亮",
                action: #selector(handleDelete(_:)),
                keyEquivalent: ""
            )
            deleteItem.target = self
            deleteItem.representedObject = id
            menu.addItem(deleteItem)

            let copyItem = NSMenuItem(
                title: "复制原文",
                action: #selector(handleCopyText(_:)),
                keyEquivalent: ""
            )
            copyItem.target = self
            copyItem.representedObject = id
            menu.addItem(copyItem)

            return menu
        }

        @objc private func handleDelete(_ sender: NSMenuItem) {
            guard let id = sender.representedObject as? String, let session else { return }
            session.deleteAnnotation(id: id)
        }

        @objc private func handleCopyText(_ sender: NSMenuItem) {
            guard let id = sender.representedObject as? String,
                  let session,
                  let documentId = session.documentId else { return }
            let records = (try? AnnotationRepository.shared.list(forDocumentId: documentId)) ?? []
            guard let record = records.first(where: { $0.id == id }),
                  let text = record.selectedText, !text.isEmpty else { return }
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setString(text, forType: .string)
        }
    }
}
