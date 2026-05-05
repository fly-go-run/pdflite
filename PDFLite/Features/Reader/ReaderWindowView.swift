import PDFKit
import SwiftUI

struct ReaderWindowView: View {
    @State private var session = DocumentSession()
    @State private var panelController = SelectionPanelController()
    @State private var refPanel = ReferencePreviewPanelController()

    var body: some View {
        Group {
            if session.hasDocument {
                ReaderView(session: session)
            } else {
                EmptyDocumentView(session: session)
            }
        }
        .focusedSceneValue(\.documentSession, session)
        .background(WindowFocusBridge(session: session))
        .onAppear {
            DocumentOpener.register(session)
            wirePanelActions()
            wireRefPanelActions()
        }
        .onDisappear {
            session.flushReadingState()
            panelController.dismiss()
            refPanel.dismiss()
        }
        .onChange(of: session.selectionRevision) { _, _ in
            refreshPanel()
        }
        .onChange(of: session.translation.current) { _, _ in
            refreshPanel()
        }
        .onChange(of: session.isTranslationInspectorVisible) { _, _ in
            // Inspector toggling alone changes the panel's compact/full layout — refresh so the
            // floating panel re-renders without waiting for a new selection or stream tick.
            refreshPanel()
        }
        .onChange(of: session.referencePreview) { _, _ in
            refreshRefPanel()
        }
        .navigationTitle(session.title)
        .alert("无法打开 PDF",
               isPresented: Binding(
                   get: { session.loadError != nil },
                   set: { if !$0 { session.clearLoadError() } }
               ),
               actions: { Button("OK") { session.clearLoadError() } },
               message: { Text(session.loadError ?? "") })
    }

    private func wirePanelActions() {
        panelController.onTranslate = {
            session.translateCurrentSelection()
        }
        panelController.onHighlight = {
            session.highlightSelection()
        }
        panelController.onCopy = {
            session.copyCurrentSelection()
        }
        panelController.onCancel = {
            session.cancelTranslation()
        }
        panelController.onJumpToFigure = {
            session.jumpToCurrentFigure()
        }
    }

    private func wireRefPanelActions() {
        refPanel.onJump = {
            session.jumpToReferencePreview()
        }
        refPanel.onCopy = {
            session.copyReferencePreviewEntry()
        }
        refPanel.onClose = {
            session.dismissReferencePreview()
        }
    }

    private func refreshPanel() {
        guard session.hasSelection,
              let rect = session.selectionScreenRect() else {
            panelController.dismiss()
            return
        }
        if session.shouldDismissSelectionPanelForCompletedTranslation {
            panelController.dismiss()
            return
        }
        panelController.present(
            near: rect,
            translation: session.translation.current,
            figureReference: session.currentFigureReference,
            inspectorOpen: session.isTranslationInspectorVisible,
            ownerWindow: session.pdfView?.window
        )
    }

    private func refreshRefPanel() {
        guard let preview = session.referencePreview else {
            refPanel.dismiss()
            return
        }
        refPanel.present(
            near: preview.anchor,
            entry: preview.entry,
            ownerWindow: session.pdfView?.window
        )
    }
}

private struct WindowFocusBridge: NSViewRepresentable {
    let session: DocumentSession

    func makeCoordinator() -> Coordinator {
        Coordinator(session: session)
    }

    func makeNSView(context: Context) -> FocusProbeView {
        let view = FocusProbeView()
        view.onWindowChanged = { [weak coordinator = context.coordinator] window in
            coordinator?.attach(to: window)
        }
        return view
    }

    func updateNSView(_ view: FocusProbeView, context: Context) {
        context.coordinator.session = session
        context.coordinator.attach(to: view.window)
    }

    static func dismantleNSView(_ view: FocusProbeView, coordinator: Coordinator) {
        coordinator.detach()
        view.onWindowChanged = nil
    }

    final class FocusProbeView: NSView {
        var onWindowChanged: ((NSWindow?) -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            onWindowChanged?(window)
        }
    }

    @MainActor
    final class Coordinator {
        weak var session: DocumentSession?
        private weak var window: NSWindow?
        private var tokens: [NSObjectProtocol] = []

        init(session: DocumentSession) {
            self.session = session
        }

        func attach(to newWindow: NSWindow?) {
            guard window !== newWindow else { return }
            detach()
            window = newWindow
            guard let newWindow else { return }

            // didBecomeKey is enough — didBecomeMain almost always rides along, and app-level
            // didBecomeActive is already handled by AppDelegate.
            let center = NotificationCenter.default
            tokens.append(center.addObserver(
                forName: NSWindow.didBecomeKeyNotification,
                object: newWindow,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    self?.activateSession(restoreKeyboardFocus: true)
                }
            })

            if newWindow.isKeyWindow {
                activateSession(restoreKeyboardFocus: false)
            }
        }

        func detach() {
            let center = NotificationCenter.default
            for token in tokens {
                center.removeObserver(token)
            }
            tokens = []
            window = nil
        }

        private func activateSession(restoreKeyboardFocus: Bool) {
            guard let session,
                  let window,
                  window.isVisible,
                  !(window is NSPanel) else { return }
            AppFocusState.shared.activate(session)
            if restoreKeyboardFocus {
                session.restoreReaderKeyboardFocusIfAppropriate()
            }
        }
    }
}
