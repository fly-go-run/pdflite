import PDFKit
import SwiftUI

struct ReaderWindowView: View {
    @State private var session = DocumentSession()
    @State private var panelController = SelectionPanelController()
    @State private var refPanel = ReferencePreviewPanelController()
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        // Keep NavigationSplitView, .toolbar and .navigationTitle at the persistent root so
        // the window's NSToolbar / title binding is established at window creation. Swapping
        // these via a conditional Group lets a Finder-launched cold start build the window
        // around `EmptyDocumentView` (no toolbar) and then fail to attach the toolbar when
        // the document loads in — symptom: a chrome-only window with no toolbar buttons and
        // a stale "PDFLite" title.
        splitView
            .toolbar { toolbarContent }
            .focusedSceneValue(\.documentSession, session)
            .background(WindowFocusBridge(session: session,
                                          title: session.title,
                                          fileURL: session.fileURL))
            // Deep links (pdflite://open?url=…) are claimed at the view level so an EXISTING
            // window handles them — without this, every browser-extension click would conjure
            // a fresh ghost window (SwiftUI swallows the URL event entirely; it never reaches
            // AppDelegate.application(_:open:), so scene/view matching is the only routing).
            // pdflite://reader deliberately stays unclaimed: the bootstrap lever must keep
            // creating windows.
            .handlesExternalEvents(preferring: ["pdflite://open"], allowing: ["pdflite://open"])
            .onOpenURL { url in
                RemoteOpenPanelController.handleDeepLink(url)
            }
            .onAppear {
                // spawnWindow must be wired before register(): register may need to spawn
                // follow-up windows when multiple documents queued before any window existed.
                DocumentOpener.spawnWindow = { openWindow(id: "reader") }
                DocumentOpener.register(session)
                wirePanelActions()
                wireRefPanelActions()
            }
            .onDisappear {
                session.flushReadingState()
                panelController.dismiss()
                refPanel.dismiss()
            }
            .onChange(of: session.selectionRevision) { _, _ in refreshPanel() }
            .onChange(of: session.translation.current) { old, new in
                handleTranslationChange(old: old, new: new)
            }
            // Scrolling: hide the selection panel while the viewport moves, then re-present it
            // at the selection's new screen position once scrolling settles.
            .onChange(of: session.isViewportScrolling) { _, scrolling in
                if scrolling {
                    panelController.dismiss()
                } else {
                    refreshPanel()
                }
            }
            // Inspector toggling alone changes the panel's compact/full layout — refresh so the
            // floating panel re-renders without waiting for a new selection or stream tick.
            .onChange(of: session.isTranslationInspectorVisible) { _, _ in refreshPanel() }
            .onChange(of: session.referencePreview) { _, _ in refreshRefPanel() }
            .alert("无法打开 PDF",
                   isPresented: loadErrorBinding,
                   actions: { Button("OK") { session.clearLoadError() } },
                   message: { Text(session.loadError ?? "") })
    }

    private var splitView: some View {
        NavigationSplitView(columnVisibility: sidebarVisibility) {
            sidebarColumn
                .navigationSplitViewColumnWidth(min: 180, ideal: 240, max: 420)
        } detail: {
            detailColumn
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        // Always emit. Conditionally inserting the items (e.g. `if session.hasDocument`)
        // produces an empty NSToolbar at window creation; macOS SwiftUI doesn't reliably
        // re-add items after the conditional flips, leaving Finder-cold-started windows
        // with no toolbar buttons. ReaderToolbar's individual items are no-ops / disabled
        // when no document is loaded, so showing them on the bookshelf is harmless.
        ReaderToolbar(session: session)
    }

    @ViewBuilder
    private var sidebarColumn: some View {
        if session.hasDocument {
            SidebarView(session: session)
        } else {
            // Empty placeholder so the split view structure stays stable even before a doc loads.
            Color.clear
        }
    }

    @ViewBuilder
    private var detailColumn: some View {
        if session.hasDocument {
            ReaderView(session: session)
        } else {
            EmptyDocumentView(session: session)
        }
    }

    private var sidebarVisibility: Binding<NavigationSplitViewVisibility> {
        Binding<NavigationSplitViewVisibility>(
            get: {
                let shown = session.hasDocument && session.isSidebarVisible
                return shown ? .all : .detailOnly
            },
            set: { newValue in
                session.isSidebarVisible = (newValue != .detailOnly)
            }
        )
    }

    private var loadErrorBinding: Binding<Bool> {
        Binding(
            get: { session.loadError != nil },
            set: { if !$0 { session.clearLoadError() } }
        )
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
        panelController.onRetry = {
            session.retryTranslation()
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

    /// Streaming ticks only grow `partial`; the panel's geometry inputs (anchor rect, size mode)
    /// are unchanged. A full refreshPanel per token would re-derive the selection screen rect and
    /// re-clamp/setFrame hundreds of times per translation — swap the hosted view instead, and in
    /// compact mode (inspector open, partial not rendered) skip the update entirely.
    private func handleTranslationChange(old: TranslationOutput?, new: TranslationOutput?) {
        if let old, let new,
           old.isStreaming, new.isStreaming,
           old.sourceText == new.sourceText,
           panelController.isVisible {
            if !session.isTranslationInspectorVisible {
                panelController.update(
                    translation: session.translationMatchingCurrentSelection,
                    figureReference: session.currentFigureReference,
                    inspectorOpen: false
                )
            }
            return
        }
        refreshPanel()
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
        // Selection scrolled out of the viewport → keep the panel hidden instead of clamping it
        // to a screen edge over unrelated content.
        if let viewport = session.pdfViewScreenFrame(), !viewport.intersects(rect) {
            panelController.dismiss()
            return
        }
        panelController.present(
            near: rect,
            translation: session.translationMatchingCurrentSelection,
            figureReference: session.currentFigureReference,
            inspectorOpen: session.isTranslationInspectorVisible,
            selectionTooLong: session.isSelectionTooLong,
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
    /// Pushed through here (instead of `.navigationTitle`) because on macOS the SwiftUI
    /// title binding snapshots at window creation: a Finder-launched cold start builds the
    /// window with an empty session (title "PDFLite") and never re-binds when the doc loads.
    let title: String
    /// Backs the title-bar proxy icon (⌘-click path menu, draggable). WindowGroup scenes
    /// don't manage representedURL, so nothing fights this the way the title gets fought.
    let fileURL: URL?

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
        if let window = view.window, window.title != title {
            window.title = title
        }
        if let window = view.window, window.representedURL != fileURL {
            window.representedURL = fileURL
        }
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
        private var titleObservation: NSKeyValueObservation?
        private var toolbarSwapObservation: NSKeyValueObservation?

        init(session: DocumentSession) {
            self.session = session
        }

        func attach(to newWindow: NSWindow?) {
            guard window !== newWindow else { return }
            detach()
            window = newWindow
            session?.hostWindow = newWindow
            guard let newWindow else { return }
            configureChrome(for: newWindow)

            // One runloop later, after SwiftUI has finished applying its own frame (it re-applies
            // a remembered per-group size on top of anything set synchronously here):
            // 1. enlarge the window to a comfortable reading size, 2. join the reader tab group.
            // Both exactly once, at first attach, so user resizes and dragged-out tabs aren't
            // fought afterwards.
            DispatchQueue.main.async { [weak self, weak newWindow] in
                guard let newWindow else { return }
                Self.applyDefaultReadingSize(to: newWindow)
                Self.mergeIntoReaderTabGroup(newWindow)
                // A tab spawned into an already-fullscreen group attaches with .fullScreen
                // set and never receives willEnterFullScreen.
                self?.syncToolbarVisibility()
            }

            // SwiftUI occasionally re-asserts the scene's static title ("PDFLite") on layout
            // passes (sidebar toggles, navigation), clobbering the document title we set in
            // updateNSView. Watch the title and put ours back whenever that happens.
            titleObservation = newWindow.observe(\.title) { [weak self] window, _ in
                MainActor.assumeIsolated {
                    guard let session = self?.session else { return }
                    let desired = session.title
                    if window.title != desired {
                        window.title = desired
                    }
                }
            }

            // SwiftUI occasionally swaps the window's NSToolbar instance; a fresh toolbar
            // arrives visible, which would resurrect the toolbar row mid-fullscreen.
            toolbarSwapObservation = newWindow.observe(\.toolbar) { [weak self] _, _ in
                MainActor.assumeIsolated {
                    self?.syncToolbarVisibility()
                }
            }

            // Fullscreen hides the toolbar row so only the native tab bar strip remains
            // (Terminal-style). Measured 2026-07: the autoHideToolbar presentation option
            // hides the ENTIRE titlebar strip including the tab bar, so toggling
            // toolbar.isVisible is the only mechanism that keeps tabs persistent. will*
            // notifications make the transition clean; didEnter re-asserts after it.
            let center = NotificationCenter.default
            tokens.append(center.addObserver(
                forName: NSWindow.willCloseNotification, object: newWindow, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let session = self?.session else { return }
                    session.closeDocument()
                    DocumentOpener.unregister(session)
                }
            })
            tokens.append(center.addObserver(
                forName: NSWindow.willEnterFullScreenNotification,
                object: newWindow,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.syncToolbarVisibility(fullScreen: true) }
            })
            tokens.append(center.addObserver(
                forName: NSWindow.didEnterFullScreenNotification,
                object: newWindow,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.syncToolbarVisibility(fullScreen: true) }
            })
            tokens.append(center.addObserver(
                forName: NSWindow.willExitFullScreenNotification,
                object: newWindow,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.syncToolbarVisibility(fullScreen: false) }
            })

            // didBecomeKey is enough — didBecomeMain almost always rides along, and app-level
            // didBecomeActive is already handled by AppDelegate. Doubles as the self-heal pass
            // for toolbar state on tabs that missed a fullscreen notification while unselected.
            tokens.append(center.addObserver(
                forName: NSWindow.didBecomeKeyNotification,
                object: newWindow,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    self?.activateSession(restoreKeyboardFocus: true)
                    self?.syncToolbarVisibility()
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
            titleObservation?.invalidate()
            titleObservation = nil
            toolbarSwapObservation?.invalidate()
            toolbarSwapObservation = nil
            window = nil
        }

        // NOTE: do NOT set titleVisibility = .hidden to dedupe the title against the tab bar.
        // Measured 2026-07: in unifiedCompact the flexible space pinning .primaryAction items
        // to the trailing edge rides on the title item — hiding the title collapses the whole
        // trailing cluster to the leading edge (picker at x≈265-380 in a 1348pt window).

        /// Fullscreen: toolbar row hidden, native tab bar kept (Terminal-style). Windowed:
        /// toolbar always shown. Pass `fullScreen:` from will* notifications, where styleMask
        /// still reflects the state being left rather than the one being entered.
        private func syncToolbarVisibility(fullScreen: Bool? = nil) {
            guard let window else { return }
            let isFullScreen = fullScreen ?? window.styleMask.contains(.fullScreen)
            if let toolbar = window.toolbar, toolbar.isVisible == isFullScreen {
                toolbar.isVisible = !isFullScreen
            }
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

        private static func mergeIntoReaderTabGroup(_ window: NSWindow) {
            // Already sharing a tab bar with someone → nothing to do.
            if let group = window.tabGroup, group.windows.count > 1 { return }

            let candidates = NSApp.windows.filter {
                $0 !== window
                    && !($0 is NSPanel)
                    && $0.tabbingIdentifier == "PDFLiteReader"
                    && $0.isVisible
            }
            // Land the tab where the user is looking: prefer the last-active reader window.
            let preferred = AppFocusState.shared.activeSession?.hostWindow
            let target = candidates.first { $0 === preferred } ?? candidates.first
            guard let target else { return }
            target.addTabbedWindow(window, ordered: .above)
            window.makeKeyAndOrderFront(nil)
        }

        private func configureChrome(for window: NSWindow) {
            window.styleMask.insert(.fullSizeContentView)
            window.titlebarAppearsTransparent = true
            window.titlebarSeparatorStyle = .none
            window.toolbar?.showsBaselineSeparator = false
            window.backgroundColor = .controlBackgroundColor
            // Native window tabbing: every reader window joins one tab group, so opening
            // multiple papers stacks them as tabs (Safari-style). Dragging a tab out still
            // gives a standalone window for side-by-side reading.
            window.tabbingMode = .preferred
            window.tabbingIdentifier = "PDFLiteReader"
            // macOS state restoration can't restore our documents (it just resurrects empty
            // bookshelf windows, one per window of the previous session, polluting the tab bar).
            // Reading position is restored from our own DB on open, so opt out entirely.
            window.isRestorable = false

        }

        /// Size new windows for comfortable paper reading: full visible height (menu bar to
        /// Dock, Safari-style), capped width, horizontally centered. SwiftUI's own default is
        /// barely above the 720×480 minimum (and it re-applies the previous session's small
        /// size), so enlarge anything below target.
        private static func applyDefaultReadingSize(to window: NSWindow) {
            guard let visible = (window.screen ?? NSScreen.main)?.visibleFrame else { return }
            let target = NSSize(width: min(visible.width * 0.72, 1280),
                                height: visible.height)
            guard window.frame.width < target.width || window.frame.height < target.height else {
                return
            }
            let origin = NSPoint(x: visible.midX - target.width / 2,
                                 y: visible.minY)
            window.setFrame(NSRect(origin: origin, size: target), display: true)
        }
    }
}
