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

/// Result of parsing a PDF off the main thread: the document plus its pre-built outline tree.
/// @unchecked Sendable is sound here: the worker thread that builds it hands over ownership and
/// never touches the document again — it only ever crosses to the main actor once.
private struct ParsedDocument: @unchecked Sendable {
    let document: PDFDocument
    let outline: OutlineItem?
    /// No extractable text in the sampled pages — likely a scanned PDF. Selection, translation
    /// and search won't work; the reader shows a hint instead of failing silently.
    let isLikelyScanned: Bool

    static func parse(url: URL) -> ParsedDocument? {
        guard let doc = PDFDocument(url: url) else { return nil }
        let outline = doc.outlineRoot.flatMap { OutlineItem(outline: $0) }
        var hasText = false
        for index in 0..<min(5, doc.pageCount) where !hasText {
            if let text = doc.page(at: index)?.string,
               !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                hasText = true
            }
        }
        return ParsedDocument(
            document: doc,
            outline: outline,
            isLikelyScanned: doc.pageCount > 0 && !hasText
        )
    }
}

/// One outline node in document order, used to resolve "which outline entry does the current
/// page belong to" without walking the tree on every page change.
struct FlatOutlineEntry {
    let id: String
    let pageIndex: Int
    let ancestorIDs: [String]
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
    /// Sampled pages had no text layer (likely scanned). Drives a dismissible hint banner.
    private(set) var isLikelyScanned = false
    var scannedHintDismissed = false

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
    /// True while the viewport is actively scrolling (drag or momentum). The floating selection
    /// panel hides during scroll and re-presents at the selection's new position on idle.
    private(set) var isViewportScrolling = false
    var isSidebarVisible: Bool = false
    var sidebarTab: SidebarTab = .outline
    var isSearchVisible: Bool = false
    var isTranslationInspectorVisible: Bool = false

    // MARK: - Outline & search
    private(set) var outlineRoot: OutlineItem?
    /// Outline entry the current page falls under, plus its ancestor chain. The sidebar
    /// highlights the entry, auto-expands the ancestors, and scrolls it into view.
    private(set) var activeOutlineItemID: String?
    private(set) var activeOutlineAncestorIDs: Set<String> = []
    @ObservationIgnored private var outlineFlat: [FlatOutlineEntry] = []
    /// `outlineFlat` re-sorted by pageIndex (stable), so the per-page-turn active-entry lookup
    /// can binary-search instead of scanning the whole outline.
    @ObservationIgnored private var outlineByPage: [FlatOutlineEntry] = []
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
    @ObservationIgnored private var autoSelectionActionTask: Task<Void, Never>?

    // MARK: - PDFView ref
    weak var pdfView: ReaderPDFView?
    /// The NSWindow hosting this session's reader view. Set by WindowFocusBridge; used to focus
    /// the right window when the same file is opened again (works even before a PDF is loaded).
    @ObservationIgnored weak var hostWindow: NSWindow?

    // MARK: - Pending state to apply after the bridge attaches
    /// True when a fresh document was just loaded and the bridge needs to restore reading
    /// state on the next updateNSView pass. (Annotations restore separately, once the file
    /// hash has confirmed document identity.)
    private(set) var needsBridgeRestore: Bool = false
    fileprivate var pendingScrollToPage: Int = 0
    fileprivate var pendingScale: CGFloat?

    // Debounced reading-state save.
    @ObservationIgnored private let saveDebouncer = TrailingDebouncer()
    private var openTask: Task<Void, Never>?
    /// Monotonic counter guarding the async open pipeline: every openDocument/closeDocument bumps
    /// it, and each await-resume point checks it so a superseded open can't apply stale state.
    @ObservationIgnored private var openGeneration = 0
    private let saveDebounce: Duration = .milliseconds(500)
    private let pageWarmup = PDFPageWarmupService()
    @ObservationIgnored private let scrollIdleDebouncer = TrailingDebouncer()
    @ObservationIgnored private let scaleWarmupDebouncer = TrailingDebouncer()
    @ObservationIgnored private var isScrollActive = false
    @ObservationIgnored private var lastWarmupDirection: PDFPageWarmupDirection = .both
    /// FigureReference regex result cached per selection revision — refreshPanel reads
    /// `currentFigureReference` on every panel update, including once per streamed token.
    @ObservationIgnored private var figureReferenceCache: (revision: Int, value: FigureReference?)?

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
        DocumentOpener.presentOpenPanel(preferring: self)
    }

    func openDocument(url: URL) {
        loadError = nil

        guard FileManager.default.fileExists(atPath: url.path) else {
            loadError = "文件不存在：\(url.path)"
            return
        }

        openTask?.cancel()
        openGeneration += 1
        let generation = openGeneration
        let standardizedURL = url.standardizedFileURL

        openTask = Task { [weak self] in
            // Parse the document and build the outline tree off the main thread — nothing else
            // can see this PDFDocument yet, so the worker thread owns it exclusively.
            let parsed: ParsedDocument? = await Task.detached(priority: .userInitiated) {
                ParsedDocument.parse(url: standardizedURL)
            }.value

            guard let self, !Task.isCancelled, self.openGeneration == generation else { return }

            guard let parsed else {
                self.loadError = "无法打开 PDF：\(standardizedURL.lastPathComponent)"
                return
            }
            if parsed.document.isLocked {
                self.loadError = "PDFLite 第一版暂不支持加密 PDF"
                return
            }

            // Fast path: restore reading state by URL so the document opens at the right page
            // immediately. The full-file hash (true identity) runs afterwards, off the render path.
            let provisional = try? await DocumentRepository.shared.find(byURL: standardizedURL)
            guard !Task.isCancelled, self.openGeneration == generation else { return }

            self.presentDocument(parsed, url: standardizedURL, provisional: provisional)

            let hashResult: Result<String, Error> = await Task.detached(priority: .utility) {
                Result { try FileHash.sha256(of: standardizedURL) }
            }.value
            guard !Task.isCancelled, self.openGeneration == generation else { return }

            await self.finishPersistence(url: standardizedURL,
                                         document: parsed.document,
                                         hashResult: hashResult,
                                         provisional: provisional,
                                         generation: generation)
        }
    }

    /// First phase of open: put the document on screen with the best reading state we know so
    /// far (the URL-matched record). Runs before hashing / DB upsert so first render never waits
    /// on a full-file read.
    private func presentDocument(_ parsed: ParsedDocument, url: URL, provisional: DocumentRecord?) {
        let doc = parsed.document
        fileURL = url
        document = doc
        documentId = nil // unknown until the hash confirms identity
        isLikelyScanned = parsed.isLikelyScanned
        scannedHintDismissed = false
        pageCount = doc.pageCount
        currentPageIndex = max(0, min(doc.pageCount - 1, provisional?.lastPage ?? 0))
        outlineRoot = parsed.outline
        outlineFlat = []
        if let children = parsed.outline?.children {
            Self.flattenOutline(children, ancestors: [], into: &outlineFlat)
        }
        // Stable sort: entries sharing a page keep document order, so ties resolve to the last
        // entry in document order — same winner the old linear scan picked.
        outlineByPage = outlineFlat.enumerated()
            .sorted { ($0.element.pageIndex, $0.offset) < ($1.element.pageIndex, $1.offset) }
            .map(\.element)
        updateActiveOutlineItem()
        annotationService = AnnotationService(document: doc)
        let newReferenceIndex = ReferenceIndex(document: doc)
        referenceIndex = newReferenceIndex
        referencePreview = nil
        referenceIndexPrepareTask?.cancel()
        // Build the bibliography index off the click path. A short breather lets the first page
        // render land; prepare() runs the extraction off the main actor entirely.
        referenceIndexPrepareTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            if Task.isCancelled { return }
            guard let self, self.referenceIndex === newReferenceIndex else { return }
            await newReferenceIndex.prepare()
        }
        search.clear()
        navigation.clear()
        selection = nil
        translation.reset()

        if let savedMode = provisional?.displayMode {
            displayMode = PDFDisplayMode.from(dbValue: savedMode)
        }
        scaleFactor = CGFloat(provisional?.lastZoom ?? 1.0)

        pendingScrollToPage = currentPageIndex
        pendingScale = provisional?.lastZoom.map { CGFloat($0) }
        needsBridgeRestore = true

        // Hand the live PDFDocument to the warmup service. Sharing the same instance lets
        // page.thumbnail() prime the very same per-document caches PDFView reads from when it
        // rasterizes pages on screen — that's what makes neighbouring pages feel instant.
        pageWarmup.attach(document: doc)

        RecentFilesService.shared.add(url)
        schedulePageWarmup(direction: .forward, delayMilliseconds: 500)
    }

    /// Second phase of open: hash confirms document identity, then upsert + annotation restore.
    /// SQLite failure doesn't block reading, it just disables persistence for this session
    /// (per §8 reading > persistence).
    private func finishPersistence(url: URL,
                                   document doc: PDFDocument,
                                   hashResult: Result<String, Error>,
                                   provisional: DocumentRecord?,
                                   generation: Int) async {
        let hash: String?
        switch hashResult {
        case .success(let value):
            hash = value
        case .failure(let error):
            logger.error("Failed to hash \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
            hash = nil
        }
        guard let hash else { return }

        let record: DocumentRecord
        do {
            record = try await DocumentRepository.shared.upsert(
                fileHash: hash,
                fileURL: url,
                title: url.deletingPathExtension().lastPathComponent,
                pageCount: doc.pageCount
            )
        } catch {
            logger.error("DocumentRepository upsert failed: \(error.localizedDescription, privacy: .public)")
            loadError = "数据库写入失败，本次阅读状态和高亮不会被保存：\(error.localizedDescription)"
            return
        }
        guard openGeneration == generation, document === doc else { return }

        documentId = record.id

        // The URL row we restored from can turn out to belong to different content (file replaced
        // in place), or the hash may match a record under an old path (file moved). Re-apply the
        // reading state that actually belongs to this content — but only if the user hasn't
        // navigated away from the provisional position yet.
        if record.id != provisional?.id {
            let provisionalIndex = max(0, min(pageCount - 1, provisional?.lastPage ?? 0))
            let target = max(0, min(pageCount - 1, record.lastPage))
            if currentPageIndex == provisionalIndex,
               target != currentPageIndex,
               let page = doc.page(at: target) {
                pdfView?.go(to: page)
            }
            if let savedMode = record.displayMode {
                displayMode = PDFDisplayMode.from(dbValue: savedMode)
            }
        }

        if let id = record.id {
            let annotations = (try? await AnnotationRepository.shared.list(forDocumentId: id)) ?? []
            guard openGeneration == generation, document === doc else { return }
            if !annotations.isEmpty {
                annotationService?.restore(records: annotations)
            }
        }
    }

    func closeDocument() {
        openTask?.cancel()
        openTask = nil
        openGeneration += 1
        scrollIdleDebouncer.cancel()
        scaleWarmupDebouncer.cancel()
        isScrollActive = false
        lastWarmupDirection = .both
        pageWarmup.reset()
        flushSave()
        fileURL = nil
        document = nil
        documentId = nil
        isLikelyScanned = false
        scannedHintDismissed = false
        pageCount = 0
        currentPageIndex = 0
        outlineRoot = nil
        outlineFlat = []
        outlineByPage = []
        activeOutlineItemID = nil
        activeOutlineAncestorIDs = []
        annotationService = nil
        referenceIndexPrepareTask?.cancel()
        referenceIndexPrepareTask = nil
        referenceIndex = nil
        referencePreview = nil
        autoSelectionActionTask?.cancel()
        autoSelectionActionTask = nil
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

    func consumeBridgeRestore() -> (page: Int, scale: CGFloat?)? {
        guard needsBridgeRestore else { return nil }
        let payload = (page: pendingScrollToPage, scale: pendingScale)
        pendingScale = nil
        pendingScrollToPage = 0
        needsBridgeRestore = false
        return payload
    }

    func restoreReaderKeyboardFocusIfAppropriate() {
        guard let pdfView,
              let window = pdfView.window,
              window.isKeyWindow else { return }

        if let responder = window.firstResponder {
            if responder is NSTextView {
                return
            }
            if let responderView = responder as? NSView,
               responderView.isDescendant(of: pdfView) {
                return
            }
        }

        window.makeFirstResponder(pdfView)
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

    // MARK: - Print

    func printDocument() {
        guard let pdfView, pdfView.document != nil else { return }
        pdfView.print(with: .shared, autoRotate: true)
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
              let service = annotationService else { return }

        let records = service.createHighlight(snapshot: snapshot, documentId: documentId)
        guard let groupId = records.first?.groupId, !records.isEmpty else { return }

        Task { [weak self] in
            do {
                try await AnnotationRepository.shared.insertAll(records)
            } catch {
                // Roll back the runtime annotations so DB and UI stay consistent (§5.4).
                guard let self else { return }
                self.annotationService?.removeRuntimeAnnotations(groupId: groupId)
                self.logger.error("Failed to persist annotation: \(error.localizedDescription, privacy: .public)")
                self.loadError = "无法保存高亮：\(error.localizedDescription)"
            }
        }

        if readerSettings.autoTranslateOnHighlight {
            isTranslationInspectorVisible = true
            translation.translate(snapshot: snapshot, documentId: documentId) { [weak self] saved in
                guard let self, let translationId = saved.id else { return }
                Task {
                    do {
                        try await AnnotationRepository.shared.updateTranslationId(
                            groupId: groupId,
                            translationId: translationId
                        )
                    } catch {
                        self.logger.error(
                            "Failed to bind translation to highlight: \(error.localizedDescription, privacy: .public)"
                        )
                    }
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
    /// the selection isn't shaped like a figure/table mention. Derived from `selection` but cached
    /// per selectionRevision — the floating panel asks for it on every refresh, including once per
    /// streamed translation token, and the regex parse only depends on the selection text.
    var currentFigureReference: FigureReference? {
        guard let snapshot = selection else { return nil }
        if let cached = figureReferenceCache, cached.revision == selectionRevision {
            return cached.value
        }
        let value = FigureReference.parse(snapshot.rawText)
        figureReferenceCache = (selectionRevision, value)
        return value
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

    /// Re-run the last translation after an error. Works even if the selection was cleared —
    /// the service keeps the last requested snapshot.
    func retryTranslation() {
        guard translation.canRetry else { return }
        isTranslationInspectorVisible = true
        translation.retryLast()
    }

    func copyCurrentSelection() {
        guard let snapshot = selection else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(snapshot.rawText, forType: .string)
    }

    /// The current translation output, but only when it belongs to the current selection.
    /// The floating panel binds to this so it never shows a previous selection's stream.
    var translationMatchingCurrentSelection: TranslationOutput? {
        guard let snapshot = selection,
              isSameSelectionAsCurrentTranslation(snapshot) else { return nil }
        return translation.current
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

    /// The PDF view's frame in screen coordinates, used to decide whether an anchored panel's
    /// target is still visible in the viewport.
    func pdfViewScreenFrame() -> NSRect? {
        guard let pdfView, let window = pdfView.window else { return nil }
        let inWindow = pdfView.convert(pdfView.bounds, to: nil)
        return window.convertToScreen(inWindow)
    }

    func deleteAnnotation(groupId: String) {
        // Remove from the view immediately for responsive feedback; the DB delete follows. If it
        // fails, surface the error — the highlight will reappear on next open, which matches.
        annotationService?.removeRuntimeAnnotations(groupId: groupId)
        Task { [weak self] in
            do {
                try await AnnotationRepository.shared.delete(groupId: groupId)
            } catch {
                self?.logger.error("Failed to delete annotation: \(error.localizedDescription, privacy: .public)")
                self?.loadError = "无法删除高亮：\(error.localizedDescription)"
            }
        }
    }

    // MARK: - Bridge callbacks (called from PDFKitRepresentable)

    func handlePageChanged(to index: Int) {
        guard index != currentPageIndex else { return }
        let direction: PDFPageWarmupDirection = index > currentPageIndex ? .forward : .backward
        currentPageIndex = index
        lastWarmupDirection = direction
        updateActiveOutlineItem()
        // A reference preview is anchored to a fixed screen point; once the page underneath it
        // changes it's pointing at nothing — dismiss instead of lingering over new content.
        if referencePreview != nil {
            referencePreview = nil
        }
        scheduleSave()
        schedulePageWarmup(direction: direction, delayMilliseconds: 160)
    }

    func handleScaleChanged(_ factor: CGFloat) {
        scaleFactor = factor
        scheduleSave()
        // PDFViewScaleChanged fires continuously during pinch / Cmd-scroll zoom; debounce here
        // instead of re-creating the warmup service's DispatchWorkItem on every tick.
        scaleWarmupDebouncer.call(after: .milliseconds(250)) { [weak self] in
            self?.schedulePageWarmup(direction: .both, delayMilliseconds: 0)
        }
    }

    func handleScrollActivity() {
        guard document != nil else { return }
        isScrollActive = true
        if !isViewportScrolling {
            isViewportScrolling = true
        }
        if referencePreview != nil {
            referencePreview = nil
        }
        // We do NOT cancel pending warmup here. Boundschange fires continuously during inertial
        // momentum; cancelling would also kill the warmup DidEndLiveScroll just scheduled, which
        // is the one we most want to run. Warmup is on a background QoS queue and won't fight
        // PDFView's main-thread rendering.
        scrollIdleDebouncer.call(after: .milliseconds(220)) { [weak self] in
            self?.handleScrollIdle()
        }
    }

    func handleSelectionChanged(_ snapshot: SelectionSnapshot?) {
        // Any pending auto-action belongs to the previous selection — drop it before we even
        // touch state so the closure can't fire against a stale snapshot.
        autoSelectionActionTask?.cancel()
        autoSelectionActionTask = nil

        // Search drives PDFView's currentSelection programmatically (set on every match jump).
        // Those notifications hit this same callback and would otherwise look identical to a
        // user gesture, kicking off auto-translate / auto-highlight. Bail out here, and clear
        // any stale selection so the floating panel doesn't linger over a search hit.
        if isSearchVisible {
            if selection != nil {
                selection = nil
                selectionRevision += 1
            }
            return
        }

        // Note: an in-flight streaming translation for the *previous* selection keeps going —
        // selecting new text (e.g. to copy it) must not burn tokens on an unrequested
        // re-translation. The floating panel only shows a translation that matches the current
        // selection (translationMatchingCurrentSelection), so no stale text is displayed. The
        // auto-action below respects the user's "划词后" setting.
        selection = snapshot
        selectionRevision += 1

        scheduleAutoSelectionActionIfNeeded(for: snapshot)
    }

    /// When the user has set a "划词后" auto-action, debounce it so we only fire once after the
    /// selection settles (i.e. they stopped dragging). The closure re-checks `selection` to
    /// ensure the user hasn't moved on before triggering.
    private func scheduleAutoSelectionActionIfNeeded(for snapshot: SelectionSnapshot?) {
        guard let snapshot,
              snapshot.rawText.trimmingCharacters(in: .whitespacesAndNewlines).count >= 2 else {
            return
        }
        let action = readerSettings.selectionAutoAction
        guard action != .none else { return }

        // For .translate: skip if we're already showing this exact translation, otherwise we'd
        // refire on every settle even when nothing changed.
        if action == .translate, isSameSelectionAsCurrentTranslation(snapshot) { return }

        let pinnedText = snapshot.rawText
        let pinnedPage = snapshot.pageIndex

        autoSelectionActionTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(350))
            if Task.isCancelled { return }
            guard let self,
                  let current = self.selection,
                  current.rawText == pinnedText,
                  current.pageIndex == pinnedPage else { return }

            switch action {
            case .none:
                break
            case .translate:
                self.translateCurrentSelection()
            case .highlight:
                self.highlightSelection()
            }
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
        saveDebouncer.call(after: saveDebounce) { [weak self] in
            Task {
                do {
                    try await DocumentRepository.shared.updateReadingState(
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
    }

    private func flushSave() {
        saveDebouncer.cancel()
        guard let documentId else { return }
        do {
            // Synchronous on purpose: flush runs on window close / app quit, where the write must
            // land before teardown continues.
            try DocumentRepository.shared.updateReadingStateNow(
                documentId: documentId,
                lastPage: currentPageIndex,
                lastZoom: Double(scaleFactor),
                displayMode: displayMode.dbValue
            )
        } catch {
            logger.error("Reading-state flush failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Outline tracking

    private static func flattenOutline(_ items: [OutlineItem],
                                       ancestors: [String],
                                       into result: inout [FlatOutlineEntry]) {
        for item in items {
            if let pageIndex = item.pageIndex {
                result.append(FlatOutlineEntry(id: item.id, pageIndex: pageIndex, ancestorIDs: ancestors))
            }
            if let children = item.children, !children.isEmpty {
                flattenOutline(children, ancestors: ancestors + [item.id], into: &result)
            }
        }
    }

    /// The active entry is the one starting nearest at-or-before the current page — i.e. the
    /// section the reader is currently inside. Binary search over the page-sorted copy, so a
    /// page turn costs O(log n) instead of a scan of the whole outline.
    private func updateActiveOutlineItem() {
        var low = 0
        var high = outlineByPage.count
        while low < high {
            let mid = (low + high) / 2
            if outlineByPage[mid].pageIndex <= currentPageIndex {
                low = mid + 1
            } else {
                high = mid
            }
        }
        let best = low > 0 ? outlineByPage[low - 1] : nil
        let newID = best?.id
        if activeOutlineItemID != newID {
            activeOutlineItemID = newID
            activeOutlineAncestorIDs = Set(best?.ancestorIDs ?? [])
        }
    }

    private func handleScrollIdle() {
        isScrollActive = false
        isViewportScrolling = false
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
        // Cap the effective zoom at 2x: beyond that a neighbouring page never enters the viewport
        // whole, and an 8x warmup would rasterize a five-digit-pixel-wide bitmap (hundreds of MB)
        // for near-zero prefetch value. The absolute width cap is a second safety net.
        let effectiveScale = min(max(scaleFactor, 0.5), 2.0)
        let width = min(max(viewWidth * effectiveScale * backingScale, 600), 4000)

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
