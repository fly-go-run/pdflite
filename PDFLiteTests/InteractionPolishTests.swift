import AppKit
import PDFKit
import XCTest

/// Notice banner lifecycle, ⌘F focus handoff and the missing-API-key error. Temp databases and
/// in-memory views only; nothing here reads the user's config or reading data.
@MainActor
final class InteractionPolishTests: XCTestCase {
    private var directory: URL!
    private var sessions: [DocumentSession] = []

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        for session in sessions {
            session.closeDocument()
            DocumentOpener.unregister(session)
        }
        sessions = []
        try FileManager.default.removeItem(at: directory)
    }

    private func session(database: Database? = nil) -> DocumentSession {
        let database = database ?? Database(url: directory.appendingPathComponent(UUID().uuidString + ".sqlite"))
        let session = DocumentSession(documentRepository: DocumentRepository(database: database),
                                      annotationRepository: AnnotationRepository(database: database),
                                      didOpenDocument: { _ in })
        sessions.append(session)
        return session
    }

    private func waitUntil(_ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !predicate(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(predicate(), "Timed out waiting for state")
    }

    // MARK: - NoticeBoard

    func testTransientNoticeAutoClearsButPersistentNoticeStays() async throws {
        let board = NoticeBoard()
        board.transientLifetime = .milliseconds(60)

        board.post(.transient("无法删除高亮"))
        XCTAssertEqual(board.current?.message, "无法删除高亮")
        try await waitUntil { board.current == nil }

        board.post(.persistent("无法确认文档内容"))
        try await Task.sleep(for: .milliseconds(250)) // several lifetimes
        XCTAssertEqual(board.current, .persistent("无法确认文档内容"),
                       "A notice describing an ongoing condition must not time out")
    }

    func testTransientNoticeDoesNotEvictPersistentOne() async throws {
        let board = NoticeBoard()
        board.transientLifetime = .milliseconds(60)
        board.post(.persistent("数据库不可用"))
        board.post(.transient("无法读取高亮原文"))
        XCTAssertEqual(board.current?.message, "无法读取高亮原文", "The newest failure is shown on top")

        try await waitUntil { board.transient == nil }
        XCTAssertEqual(board.current?.message, "数据库不可用", "...and the standing warning is still there afterwards")
    }

    func testDismissHidesShownNoticeAndCancelsItsTimer() async throws {
        let board = NoticeBoard()
        board.transientLifetime = .milliseconds(80)
        board.post(.transient("A"))
        board.dismiss()
        XCTAssertNil(board.current)

        // A timer left over from "A" must not clear a later notice early.
        board.post(.transient("B"))
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(board.current?.message, "B")
        try await waitUntil { board.current == nil }
    }

    func testDismissedPersistentNoticeStaysHiddenWhenRepeated() {
        let board = NoticeBoard()
        let saveFailed = SessionNotice.persistent("无法保存阅读进度：disk full")
        board.post(saveFailed)
        board.dismiss()
        XCTAssertNil(board.current)

        // e.g. the next debounced progress save fails with the same error.
        board.post(saveFailed)
        XCTAssertNil(board.current, "The ✕ must not be undone by the same condition re-posting")

        board.post(.persistent("无法保存阅读进度：another error"))
        XCTAssertNotNil(board.current, "A different condition is still reported")
    }

    func testRepeatedTransientFailureIsShownAgainAfterDismiss() {
        let board = NoticeBoard()
        let failed = SessionNotice.transient("无法删除高亮，原标注已保留：busy")
        board.post(failed)
        board.dismiss()
        board.post(failed)
        XCTAssertEqual(board.current, failed, "A new user action failing must be reported even with identical text")
    }

    func testResolveRemovesOnlyThatCondition() {
        let board = NoticeBoard()
        board.post(.preparingAnnotations)
        board.resolve(.annotationsNotSaved)
        XCTAssertEqual(board.current, .preparingAnnotations)
        board.resolve(.preparingAnnotations)
        XCTAssertNil(board.current)
        XCTAssertFalse(SessionNotice.preparingAnnotations.isTransient)
        XCTAssertFalse(SessionNotice.annotationsNotSaved.isTransient)
    }

    func testResetCancelsStaleTimerAndDropsAllNotices() async throws {
        let board = NoticeBoard()
        board.transientLifetime = .milliseconds(200)
        board.post(.persistent("old document"))
        board.post(.transient("old failure"))
        board.reset()
        XCTAssertNil(board.current)

        try await Task.sleep(for: .milliseconds(120))
        board.post(.transient("new document failure")) // posted 120ms in; old timer fires at 200ms
        try await Task.sleep(for: .milliseconds(130))
        XCTAssertEqual(board.current?.message, "new document failure",
                       "A timer from before reset() must not clear the new document's notice")
        try await waitUntil { board.current == nil }
    }

    // MARK: - DocumentSession integration

    func testSessionPersistenceNoticeFollowsBoardAndDismissesViaBoard() {
        let reader = session()
        XCTAssertNil(reader.persistenceNotice)
        reader.notices.post(.transient("无法保存高亮"))
        XCTAssertEqual(reader.persistenceNotice?.message, "无法保存高亮")
        reader.notices.dismiss()
        XCTAssertNil(reader.persistenceNotice)
    }

    func testClosingDocumentDropsNoticesAndTimers() async throws {
        let reader = session()
        reader.notices.transientLifetime = .milliseconds(100)
        reader.notices.post(.persistent("standing"))
        reader.notices.post(.transient("passing"))
        reader.closeDocument()
        XCTAssertNil(reader.persistenceNotice)

        reader.notices.post(.transient("after close"))
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertNotNil(reader.persistenceNotice, "The old timer is gone; this notice runs its own lifetime")
        try await waitUntil { reader.persistenceNotice == nil }
    }

    func testOpeningDocumentClearsNoticesFromPreviousDocument() throws {
        let reader = session()
        reader.notices.post(.persistent("previous document"))
        let missing = directory.appendingPathComponent("missing.pdf")
        reader.openDocument(url: missing) // fails fast (file not found) before reaching reset
        XCTAssertNotNil(reader.persistenceNotice, "A rejected open leaves the current state alone")

        let url = directory.appendingPathComponent("blank.pdf")
        let document = PDFDocument()
        document.insert(PDFPage(), at: 0)
        XCTAssertTrue(document.write(to: url))
        reader.openDocument(url: url)
        XCTAssertNil(reader.persistenceNotice, "Starting an open must reset the banner")
    }

    func testBlockedHighlightPostsPersistentNoticeThatDoesNotTimeOut() async throws {
        // A directory as the database path forces the ephemeral (non-persistent) fallback.
        let reader = session(database: Database(url: directory))
        reader.notices.transientLifetime = .milliseconds(40)
        let page = PDFPage()
        reader.handleSelectionChanged(SelectionSnapshot(pages: [PageSelection(
            pageIndex: 0, page: page, lineRects: [CGRect(x: 0, y: 0, width: 10, height: 10)], text: "x"
        )], rawText: "x"))
        reader.highlightSelection()
        XCTAssertEqual(reader.persistenceNotice, .annotationsNotSaved)

        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(reader.persistenceNotice, .annotationsNotSaved)
    }

    // MARK: - Search bar focus handoff

    func testFindRequestsFocusEveryTimeEvenWhenBarIsOpen() {
        let reader = session()
        let start = reader.searchFocusRequest
        reader.toggleSearch(open: true)
        XCTAssertTrue(reader.isSearchVisible)
        XCTAssertEqual(reader.searchFocusRequest, start + 1)
        reader.toggleSearch(open: true) // ⌘F again with the bar already open
        XCTAssertEqual(reader.searchFocusRequest, start + 2)
        XCTAssertTrue(reader.isSearchVisible)
    }

    func testClosingSearchReturnsKeyboardFocusToPDFView() throws {
        let reader = session()
        let view = ReaderPDFView(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        let window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        defer { window.close() }
        let field = NSTextField(frame: CGRect(x: 0, y: 0, width: 120, height: 22))
        view.addSubview(field)
        reader.pdfView = view

        reader.toggleSearch(open: true)
        XCTAssertTrue(window.makeFirstResponder(field))
        XCTAssertTrue(window.firstResponder is NSTextView, "Editing a field puts the field editor in the responder chain")

        reader.toggleSearch(open: false)
        XCTAssertFalse(window.firstResponder is NSTextView, "The field editor must not keep the keyboard after close")
        XCTAssertTrue((window.firstResponder as? NSView)?.isDescendant(of: view) == true)
        XCTAssertFalse(reader.isSearchVisible)
    }

    // MARK: - Missing API key

    func testMissingConfigErrorsAreOneLineAndSayWhatToDo() {
        let url = directory.appendingPathComponent("config.json")
        for error in [TranslationConfigError.missingAPIKey, .fileMissing(url)] {
            let message = error.errorDescription ?? ""
            XCTAssertEqual(message, "尚未配置 DeepSeek API Key")
            XCTAssertFalse(message.contains("\n"))
            XCTAssertFalse(message.contains("{"), "The JSON sample lives in Settings, not in the error")
        }
        XCTAssertTrue(TranslationConfig.fileFormatSample.contains("\"apiKey\""))
    }

    func testTranslationOutputErrorKindDefaultsToNone() {
        let output = TranslationOutput(sourceText: "a", cleanedText: "a", pageIndex: 0, partial: "",
                                       isStreaming: false, fromCache: false, errorMessage: "network down",
                                       startedAt: Date(), completedAt: Date())
        XCTAssertNil(output.errorKind, "Only config problems carry a kind; other errors show no settings button")
        var configFailure = output
        configFailure.errorKind = .needsConfiguration
        XCTAssertNotEqual(output, configFailure)
    }
}
