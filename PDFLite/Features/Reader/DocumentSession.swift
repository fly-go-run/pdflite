import AppKit
import Observation
import os.log
import PDFKit
import SwiftUI
import UniformTypeIdentifiers

/// Snapshot of the bibliography entry being previewed plus the on-screen anchor used to position
/// the floating panel. `destination` is the original link destination (when known); we use it for
/// the "jump" button so the user lands at the exact entry instead of the top of the page.
/// Equality intentionally ignores `destination` since `PDFDestination` doesn't conform to
/// `Equatable`, and the entry+anchor pair is enough to detect "is this the same preview".
struct ReferencePreviewState {
    let entry: ReferenceEntry
    let anchor: NSRect
    let destination: PDFDestination?
}

extension ReferencePreviewState: Equatable {
    static func == (lhs: ReferencePreviewState, rhs: ReferencePreviewState) -> Bool {
        lhs.entry == rhs.entry && lhs.anchor == rhs.anchor
    }
}

enum SidebarTab: String, CaseIterable, Identifiable {
    case outline
    case thumbnails

    var id: String { rawValue }
    var label: String {
        switch self {
        case .outline: return "Outline"
        case .thumbnails: return "Thumbnails"
        }
    }
    var systemImage: String {
        switch self {
        case .outline: return "list.bullet.indent"
        case .thumbnails: return "rectangle.grid.2x2"
        }
    }
}

@MainActor
@Observable
final class DocumentSession {
    private let logger = Logger(subsystem: "com.pdflite.app", category: "DocumentSession")

    // MARK: - Document state
    private(set) var fileURL: URL?
    private(set) var document: PDFDocument?
    private(set) var documentId: Int64?
    private(set) var pageCount: Int = 0
    private(set) var currentPageIndex: Int = 0
    private(set) var loadError: String?

    // MARK: - View state
    var displayMode: PDFDisplayMode = .singlePageContinuous {
        didSet {
            if oldValue != displayMode {
                scheduleSave()
                schedulePageWarmup(direction: .both, delayMilliseconds: 250)
            }
        }
    }
    private(set) var scaleFactor: CGFloat = 1.0
    var isSidebarVisible: Bool = false
    var sidebarTab: SidebarTab = .outline
    var isSearchVisible: Bool = false
    var isTranslationInspectorVisible: Bool = false

    // MARK: - Outline & search
    private(set) var outlineRoot: OutlineItem?
    var search = SearchService()

    // MARK: - Navigation history (Smart Jump v0)
    var navigation = NavigationHistoryService()

    // MARK: - Translation
    var translation = TranslationService()

    // MARK: - Settings
    @ObservationIgnored let readerSettings = ReaderSettings.shared

    // MARK: - Selection & annotations
    private(set) var selection: SelectionSnapshot?
    private(set) var selectionRevision: Int = 0
    private(set) var annotationService: AnnotationService?

    // MARK: - Reference preview (Phase 4 v0)
    private(set) var referencePreview: ReferencePreviewState?
    @ObservationIgnored private var referenceIndex: ReferenceIndex?
    @ObservationIgnored private var referenceIndexPrepareTask: Task<Void, Never>?

    // MARK: - PDFView ref
    weak var pdfView: ReaderPDFView?

    // MARK: - Pending state to apply after the bridge attaches
    /// True when a fresh document was just loaded and the bridge needs to restore reading
    /// state + annotations on the next updateNSView pass.
    private(set) var needsBridgeRestore: Bool = false
    fileprivate var pendingAnnotationRecords: [AnnotationRecord] = []
    fileprivate var pendingScrollToPage: Int = 0
    fileprivate var pendingScale: CGFloat?

    // Debounced reading-state save.
    private var saveTask: Task<Void, Never>?
    private var openTask: Task<Void, Never>?
    private let saveDebounce: Duration = .milliseconds(500)
    private let pageWarmup = PDFPageWarmupService()
    @ObservationIgnored private var scrollIdleTask: Task<Void, Never>?
    @ObservationIgnored private var isScrollActive = false
    @ObservationIgnored private var lastWarmupDirection: PDFPageWarmupDirection = .both

    var hasDocument: Bool { document != nil }
    var canAcceptOpen: Bool { document == nil && fileURL == nil }
    var canGoNext: Bool { hasDocument && currentPageIndex < pageCount - 1 }
    var canGoPrevious: Bool { hasDocument && currentPageIndex > 0 }
    var hasSelection: Bool { selection != nil }

    var title: String {
        fileURL?.deletingPathExtension().lastPathComponent ?? "PDFLite"
    }

    // MARK: - Open

    func presentOpenPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType.pdf]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in
                self?.openDocument(url: url)
            }
        }
    }

    func openDocument(url: URL) {
        loadError = nil

        guard FileManager.default.fileExists(atPath: url.path) else {
            loadError = "文件不存在：\(url.path)"
            return
        }

        openTask?.cancel()
        openTask = Task { [weak self] in
            let standardizedURL = url.standardizedFileURL
            let hashResult: Result<String, Error> = await Task.detached(priority: .utility) {
                Result { try FileHash.sha256(of: standardizedURL) }
            }.value

            if Task.isCancelled { return }

            await MainActor.run {
                self?.finishOpenDocument(url: standardizedURL, hashResult: hashResult)
            }
        }
    }

    private func finishOpenDocument(url: URL, hashResult: Result<String, Error>) {
        guard let doc = PDFDocument(url: url) else {
            loadError = "无法打开 PDF：\(url.lastPathComponent)"
            return
        }

        if doc.isLocked {
            loadError = "PDFLite 第一版暂不支持加密 PDF"
            return
        }

        // Compute hash + upsert + load reading state. SQLite failure should not block reading,
        // it just disables persistence for this session (per §8 reading > persistence).
        let hash: String?
        switch hashResult {
        case .success(let value):
            hash = value
        case .failure(let error):
            logger.error("Failed to hash \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
            hash = nil
        }

        var record: DocumentRecord?
        var annotations: [AnnotationRecord] = []
        if let hash {
            do {
                let upserted = try DocumentRepository.shared.upsert(
                    fileHash: hash,
                    fileURL: url,
                    title: url.deletingPathExtension().lastPathComponent,
                    pageCount: doc.pageCount
                )
                record = upserted
                if let id = upserted.id {
                    annotations = (try? AnnotationRepository.shared.list(forDocumentId: id)) ?? []
                }
            } catch {
                logger.error("DocumentRepository upsert failed: \(error.localizedDescription, privacy: .public)")
                loadError = "数据库写入失败，本次阅读状态和高亮不会被保存：\(error.localizedDescription)"
            }
        }

        fileURL = url
        document = doc
        documentId = record?.id
        pageCount = doc.pageCount
        currentPageIndex = max(0, min(doc.pageCount - 1, record?.lastPage ?? 0))
        outlineRoot = doc.outlineRoot.flatMap { OutlineItem(outline: $0) }
        annotationService = AnnotationService(document: doc)
        let newReferenceIndex = ReferenceIndex(document: doc)
        referenceIndex = newReferenceIndex
        referencePreview = nil
        referenceIndexPrepareTask?.cancel()
        // Build the bibliography index off the click path. Wait a couple of seconds so we don't
        // pile onto the page warmup queue while the user is still seeing the first page render.
        referenceIndexPrepareTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(2))
            if Task.isCancelled { return }
            guard let self, self.referenceIndex === newReferenceIndex else { return }
            await newReferenceIndex.prepare()
        }
        search.clear()
        navigation.clear()
        selection = nil
        translation.reset()
        if let documentId = record?.id,
           let history = try? TranslationRepository.shared.list(forDocumentId: documentId) {
            translation.setHistory(history)
        }

        // Reading state from DB
        if let savedMode = record?.displayMode {
            displayMode = PDFDisplayMode.from(dbValue: savedMode)
        }
        scaleFactor = CGFloat(record?.lastZoom ?? 1.0)

        pendingAnnotationRecords = annotations
        pendingScrollToPage = currentPageIndex
        pendingScale = record?.lastZoom.map { CGFloat($0) }
        needsBridgeRestore = true

        // Hand the live PDFDocument to the warmup service. Sharing the same instance lets
        // page.thumbnail() prime the very same per-document caches PDFView reads from when it
        // rasterizes pages on screen — that's what makes neighbouring pages feel instant.
        pageWarmup.attach(document: doc)

        RecentFilesService.shared.add(url)
        schedulePageWarmup(direction: .forward, delayMilliseconds: 500)
    }

    func closeDocument() {
        openTask?.cancel()
        openTask = nil
        scrollIdleTask?.cancel()
        scrollIdleTask = nil
        isScrollActive = false
        lastWarmupDirection = .both
        pageWarmup.reset()
        flushSave()
        fileURL = nil
        document = nil
        documentId = nil
        pageCount = 0
        currentPageIndex = 0
        outlineRoot = nil
        annotationService = nil
        referenceIndexPrepareTask?.cancel()
        referenceIndexPrepareTask = nil
        referenceIndex = nil
        referencePreview = nil
        selection = nil
        search.clear()
        translation.reset()
        navigation.clear()
        isTranslationInspectorVisible = false
    }

    func flushReadingState() {
        flushSave()
    }

    func clearLoadError() {
        loadError = nil
    }

    // MARK: - Bridge handshake

    func consumeBridgeRestore() -> (page: Int, scale: CGFloat?, annotations: [AnnotationRecord])? {
        guard needsBridgeRestore else { return nil }
        let payload = (page: pendingScrollToPage, scale: pendingScale, annotations: pendingAnnotationRecords)
        pendingAnnotationRecords = []
        pendingScale = nil
        pendingScrollToPage = 0
        needsBridgeRestore = false
        return payload
    }

    // MARK: - Navigation
    //
    // Public goTo* are user-perceived jumps and push the current location onto the back stack.
    // nextPage/previousPage are continuous reading and do NOT push. goBack/goForward swap entries
    // between back and forward stacks without ever pushing — that's what keeps Cmd-[ / Cmd-]
    // cycles stable.

    func goToPage(_ index: Int) {
        guard let document, let pdfView,
              index >= 0, index < document.pageCount,
              let page = document.page(at: index),
              index != currentPageIndex else { return }
        recordCurrentForHistory()
        pdfView.go(to: page)
    }

    func goToDestination(_ destination: PDFDestination) {
        guard let pdfView else { return }
        recordCurrentForHistory()
        pdfView.go(to: destination)
    }

    func goToSelection(_ selection: PDFSelection) {
        guard let pdfView else { return }
        recordCurrentForHistory()
        pdfView.go(to: selection)
    }

    func recordInternalLinkNavigation(to destination: PDFDestination) {
        guard let document, let targetPage = destination.page else { return }
        let targetIndex = document.index(for: targetPage)
        guard targetIndex != NSNotFound,
              targetIndex != currentPageIndex else { return }
        recordCurrentForHistory()
    }

    func nextPage() {
        guard canGoNext, let pdfView else { return }
        pdfView.goToNextPage(nil)
    }

    func previousPage() {
        guard canGoPrevious, let pdfView else { return }
        pdfView.goToPreviousPage(nil)
    }

    func goToFirstPage() {
        guard let document, let pdfView,
              let page = document.page(at: 0),
              currentPageIndex != 0 else { return }
        recordCurrentForHistory()
        pdfView.go(to: page)
    }

    func goToLastPage() {
        guard let document, let pdfView,
              document.pageCount > 0,
              let page = document.page(at: document.pageCount - 1),
              currentPageIndex != document.pageCount - 1 else { return }
        recordCurrentForHistory()
        pdfView.go(to: page)
    }

    func goBack() {
        guard let entry = navigation.goBack(saving: currentNavigationEntry()) else { return }
        applyNavigationEntry(entry)
    }

    func goForward() {
        guard let entry = navigation.goForward(saving: currentNavigationEntry()) else { return }
        applyNavigationEntry(entry)
    }

    private func currentNavigationEntry() -> NavigationEntry? {
        guard hasDocument else { return nil }
        return NavigationEntry(pageIndex: currentPageIndex)
    }

    private func recordCurrentForHistory() {
        navigation.recordJump(from: currentNavigationEntry())
    }

    private func applyNavigationEntry(_ entry: NavigationEntry) {
        guard let pdfView, let document,
              entry.pageIndex >= 0, entry.pageIndex < document.pageCount,
              let page = document.page(at: entry.pageIndex) else { return }
        pdfView.go(to: page)
    }

    // MARK: - Zoom

    func zoomIn() {
        guard let pdfView else { return }
        pdfView.autoScales = false
        pdfView.zoomIn(nil)
    }

    func zoomOut() {
        guard let pdfView else { return }
        pdfView.autoScales = false
        pdfView.zoomOut(nil)
    }

    func actualSize() {
        guard let pdfView else { return }
        pdfView.autoScales = false
        pdfView.scaleFactor = 1.0
    }

    func fitWidth() {
        guard let pdfView else { return }
        pdfView.autoScales = true
    }

    // MARK: - Search

    func toggleSearch(open: Bool? = nil) {
        let target = open ?? !isSearchVisible
        isSearchVisible = target
        if !target { search.clear() }
    }

    // MARK: - Annotation

    /// Highlight the current selection. No-op if there's no selection or no document record.
    /// When the auto-translate-on-highlight setting is on, also kicks off a translation and
    /// writes the resulting translation row id back onto the annotation when the request lands.
    func highlightSelection() {
        guard let snapshot = selection,
              let documentId,
              let service = annotationService,
              let record = service.createHighlight(snapshot: snapshot, documentId: documentId)
        else { return }

        do {
            try AnnotationRepository.shared.insert(record)
        } catch {
            // Roll back the runtime annotations so DB and UI stay consistent (§5.4).
            service.removeRuntimeAnnotations(id: record.id)
            logger.error("Failed to persist annotation: \(error.localizedDescription, privacy: .public)")
            loadError = "无法保存高亮：\(error.localizedDescription)"
            return
        }

        if readerSettings.autoTranslateOnHighlight {
            isTranslationInspectorVisible = true
            let annotationId = record.id
            translation.translate(snapshot: snapshot, documentId: documentId) { [weak self] saved in
                guard let self, let translationId = saved.id else { return }
                do {
                    try AnnotationRepository.shared.updateTranslationId(
                        annotationId: annotationId,
                        translationId: translationId
                    )
                } catch {
                    self.logger.error(
                        "Failed to bind translation to highlight: \(error.localizedDescription, privacy: .public)"
                    )
                }
            }
        }

        // Drop the selection so the user gets visual confirmation that the highlight committed.
        pdfView?.clearTextSelection()
        selection = nil
    }

    // MARK: - Reference preview

    /// Try to show a reference preview for `[number]`. Returns true when an entry was found and
    /// the preview state was updated; false means the bibliography didn't have this number and
    /// the caller should fall back to plain navigation.
    @discardableResult
    func requestReferencePreview(number: Int, anchor: NSRect, destination: PDFDestination?) -> Bool {
        guard let entry = referenceIndex?.entry(forNumber: number) else { return false }
        referencePreview = ReferencePreviewState(entry: entry, anchor: anchor, destination: destination)
        // PDFKit normally clears the selection on link-click via super.mouseDown; we swallow the
        // event when previewing, so do it ourselves. Selection panel auto-dismisses through the
        // PDFViewSelectionChanged → handleSelectionChanged → selectionRevision chain.
        pdfView?.clearTextSelection()
        return true
    }

    func dismissReferencePreview() {
        referencePreview = nil
    }

    /// Jump to the bibliography entry currently being previewed. Uses the link's destination when
    /// available so the user lands at the exact entry, not just the page top.
    func jumpToReferencePreview() {
        guard let preview = referencePreview else { return }
        referencePreview = nil
        if let destination = preview.destination {
            goToDestination(destination)
        } else {
            goToPage(preview.entry.pageIndex)
        }
    }

    func copyReferencePreviewEntry() {
        guard let preview = referencePreview else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString("[\(preview.entry.number)] \(preview.entry.text)", forType: .string)
    }

    // MARK: - Figure / Table jump

    /// Parsed `Figure 3` / `Table 2` reference derived from the current selection text. nil when
    /// the selection isn't shaped like a figure/table mention. Kept as a derived computed value
    /// so we don't need to keep state in sync — it tracks `selection` automatically.
    var currentFigureReference: FigureReference? {
        guard let snapshot = selection else { return nil }
        return FigureReference.parse(snapshot.rawText)
    }

    /// Search the document for the figure/table caption matching the current selection and jump
    /// to it. Records nav history via goToSelection so Cmd-[ returns to the inline mention.
    func jumpToCurrentFigure() {
        guard let document,
              let reference = currentFigureReference,
              let snapshot = selection,
              let target = FigureJumpService.locate(
                reference,
                in: document,
                excluding: snapshot.pageIndex
              )
        else { return }
        // Drop selection first so the floating panel dismisses; then jump.
        pdfView?.clearTextSelection()
        selection = nil
        goToSelection(target)
    }

    // MARK: - Translation

    /// Translate the current selection. No-op if there is no selection.
    func translateCurrentSelection() {
        guard let snapshot = selection else { return }
        isTranslationInspectorVisible = true
        translation.translate(snapshot: snapshot, documentId: documentId)
    }

    func cancelTranslation() {
        translation.cancelInFlight()
    }

    func copyCurrentSelection() {
        guard let snapshot = selection else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(snapshot.rawText, forType: .string)
    }

    var shouldDismissSelectionPanelForCompletedTranslation: Bool {
        guard let current = translation.current,
              let snapshot = selection,
              isSameSelectionAsCurrentTranslation(snapshot),
              !current.isStreaming,
              current.errorMessage == nil,
              !current.partial.isEmpty else {
            return false
        }
        return true
    }

    /// Selection rect in screen coordinates, or nil if no usable selection / no window.
    func selectionScreenRect() -> NSRect? {
        guard let snapshot = selection,
              let pdfView,
              let window = pdfView.window else { return nil }

        // Union of every line rect, in page coords.
        let union = snapshot.lineRects.reduce(snapshot.lineRects.first ?? .zero) { $0.union($1) }
        guard !union.isEmpty else { return nil }

        // page → view → window → screen
        let inView = pdfView.convert(union, from: snapshot.page)
        let inWindow = pdfView.convert(inView, to: nil)
        return window.convertToScreen(inWindow)
    }

    func deleteAnnotation(id: String) {
        do {
            try AnnotationRepository.shared.delete(id: id)
            annotationService?.removeRuntimeAnnotations(id: id)
        } catch {
            logger.error("Failed to delete annotation: \(error.localizedDescription, privacy: .public)")
            loadError = "无法删除高亮：\(error.localizedDescription)"
        }
    }

    // MARK: - Bridge callbacks (called from PDFKitRepresentable)

    func handlePageChanged(to index: Int) {
        guard index != currentPageIndex else { return }
        let direction: PDFPageWarmupDirection = index > currentPageIndex ? .forward : .backward
        currentPageIndex = index
        lastWarmupDirection = direction
        scheduleSave()
        schedulePageWarmup(direction: direction, delayMilliseconds: 160)
    }

    func handleScaleChanged(_ factor: CGFloat) {
        scaleFactor = factor
        scheduleSave()
        schedulePageWarmup(direction: .both, delayMilliseconds: 250)
    }

    func handleScrollActivity() {
        guard document != nil else { return }
        isScrollActive = true
        // We do NOT cancel pending warmup here. Boundschange fires continuously during inertial
        // momentum; cancelling would also kill the warmup DidEndLiveScroll just scheduled, which
        // is the one we most want to run. Warmup is on a background QoS queue and won't fight
        // PDFView's main-thread rendering.
        scrollIdleTask?.cancel()
        scrollIdleTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(220))
            if Task.isCancelled { return }
            self?.handleScrollIdle()
        }
    }

    func handleSelectionChanged(_ snapshot: SelectionSnapshot?) {
        let streaming = translation.current?.isStreaming == true
        let shouldRestartStreamingTranslation = streaming
            && snapshot != nil
            && !isSameSelectionAsCurrentTranslation(snapshot)

        selection = snapshot
        selectionRevision += 1

        if shouldRestartStreamingTranslation, let snapshot {
            isTranslationInspectorVisible = true
            translation.translate(snapshot: snapshot, documentId: documentId)
        }
    }

    private func isSameSelectionAsCurrentTranslation(_ snapshot: SelectionSnapshot?) -> Bool {
        guard let snapshot, let current = translation.current else { return false }
        return current.pageIndex == snapshot.pageIndex
            && current.sourceText == snapshot.rawText
    }

    // MARK: - Persistence

    private func scheduleSave() {
        guard let documentId else { return }
        let snapshot = (page: currentPageIndex,
                        zoom: Double(scaleFactor),
                        mode: displayMode.dbValue)
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            if Task.isCancelled { return }
            guard self != nil else { return }
            do {
                try DocumentRepository.shared.updateReadingState(
                    documentId: documentId,
                    lastPage: snapshot.page,
                    lastZoom: snapshot.zoom,
                    displayMode: snapshot.mode
                )
            } catch {
                self?.logger.error("Reading-state save failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func flushSave() {
        saveTask?.cancel()
        saveTask = nil
        guard let documentId else { return }
        do {
            try DocumentRepository.shared.updateReadingState(
                documentId: documentId,
                lastPage: currentPageIndex,
                lastZoom: Double(scaleFactor),
                displayMode: displayMode.dbValue
            )
        } catch {
            logger.error("Reading-state flush failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func handleScrollIdle() {
        isScrollActive = false
        schedulePageWarmup(direction: lastWarmupDirection, delayMilliseconds: 100)
    }

    /// Public warmup entry point used by the bridge layer (LiveScroll notifications).
    func requestPageWarmup(direction: PDFPageWarmupDirection, delayMilliseconds: Int) {
        lastWarmupDirection = direction
        schedulePageWarmup(direction: direction, delayMilliseconds: delayMilliseconds)
    }

    private func schedulePageWarmup(direction: PDFPageWarmupDirection,
                                    delayMilliseconds: Int) {
        guard pageCount > 0, document != nil else { return }
        let size = warmupThumbnailSize()
        guard size.width > 0, size.height > 0 else { return }
        pageWarmup.schedule(
            currentPageIndex: currentPageIndex,
            pageCount: pageCount,
            displayMode: displayMode,
            thumbnailSize: size,
            direction: direction,
            delayMilliseconds: delayMilliseconds
        )
    }

    /// Size to ask PDFKit for when pre-rasterizing neighbouring pages. We aim for the actual
    /// pixel footprint the page would occupy if it were on screen right now (visible width ×
    /// scaleFactor × backingScale), so the bitmap PDFKit caches matches the size it'll need to
    /// blit when the user scrolls there. Falls back to conservative defaults until layout settles.
    private func warmupThumbnailSize() -> CGSize {
        let backingScale = pdfView?.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        let viewWidth = pdfView?.bounds.width ?? 800
        let effectiveScale = max(scaleFactor, 0.5)
        let width = max(viewWidth * effectiveScale * backingScale, 600)

        // Use the current page's aspect ratio when available so the size we pass roughly matches
        // the page PDFView is about to draw. PDFKit clamps to the page's own aspect anyway, but
        // a closer hint avoids wasted work on portrait/landscape mismatches.
        let aspect: CGFloat
        if let document, let page = document.page(at: currentPageIndex) {
            let bounds = page.bounds(for: .cropBox)
            aspect = bounds.width > 0 ? bounds.height / bounds.width : 1.4
        } else {
            aspect = 1.4
        }
        return CGSize(width: width, height: width * aspect)
    }
}
