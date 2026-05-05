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
                view.go(to: current)
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
        private var lastScrollOrigin: CGPoint?

        init(session: DocumentSession) {
            self.session = session
        }

        func attach(view: ReaderPDFView) {
            self.view = view
            attachScrollObserver(to: view)
        }

        func detachScrollObserver() {
            if let observedClipView {
                NotificationCenter.default.removeObserver(
                    self,
                    name: NSView.boundsDidChangeNotification,
                    object: observedClipView
                )
            }
            observedClipView = nil
            lastScrollOrigin = nil
        }

        private func attachScrollObserver(to view: ReaderPDFView) {
            guard let clipView = view.scrollViewForObservation?.contentView,
                  observedClipView !== clipView else { return }

            detachScrollObserver()
            observedClipView = clipView
            lastScrollOrigin = clipView.bounds.origin
            clipView.postsBoundsChangedNotifications = true
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(scrollBoundsChanged(_:)),
                name: NSView.boundsDidChangeNotification,
                object: clipView
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

        @objc private func scrollBoundsChanged(_ notification: Notification) {
            guard let clipView = notification.object as? NSClipView else { return }
            let origin = clipView.bounds.origin
            defer { lastScrollOrigin = origin }

            guard let previous = lastScrollOrigin else { return }
            let moved = abs(origin.x - previous.x) + abs(origin.y - previous.y)
            guard moved > 0.5 else { return }

            session?.handleScrollActivity()
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
