import AppKit
import Observation
import os.log
import PDFKit
import SwiftUI
import UniformTypeIdentifiers

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

    // MARK: - Translation
    var translation = TranslationService()

    // MARK: - Selection & annotations
    private(set) var selection: SelectionSnapshot?
    private(set) var selectionRevision: Int = 0
    private(set) var annotationService: AnnotationService?

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
    private let pageWarmup = PDFPageWarmupService.shared
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
        search.clear()
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
        selection = nil
        search.clear()
        translation.reset()
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

    func goToPage(_ index: Int) {
        guard let document, let pdfView,
              index >= 0, index < document.pageCount,
              let page = document.page(at: index) else { return }
        pdfView.go(to: page)
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
        guard let document, let pdfView, let page = document.page(at: 0) else { return }
        pdfView.go(to: page)
    }

    func goToLastPage() {
        guard let document, let pdfView,
              document.pageCount > 0,
              let page = document.page(at: document.pageCount - 1) else { return }
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
        // Drop the selection so the user gets visual confirmation that the highlight committed.
        pdfView?.clearTextSelection()
        selection = nil
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
        if !isScrollActive {
            isScrollActive = true
        }
        pageWarmup.cancelPending()
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

    private func schedulePageWarmup(direction: PDFPageWarmupDirection,
                                    delayMilliseconds: Int) {
        guard let fileURL, pageCount > 0 else { return }
        guard isScrollActive == false else {
            pageWarmup.cancelPending()
            return
        }
        pageWarmup.schedule(
            url: fileURL,
            currentPageIndex: currentPageIndex,
            pageCount: pageCount,
            displayMode: displayMode,
            scaleFactor: scaleFactor,
            direction: direction,
            delayMilliseconds: delayMilliseconds
        )
    }
}
