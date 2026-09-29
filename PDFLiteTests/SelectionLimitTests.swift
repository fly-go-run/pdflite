import AppKit
import PDFKit
import XCTest

/// The size cap on selections (`SelectionLimits`): ⌘A or a huge drag must neither stall the main
/// thread building a snapshot, nor auto-upload the document to DeepSeek, nor auto-highlight every
/// line. Synthetic PDFs, temp databases, a stubbed endpoint — no real key, no real network, no
/// user data.
@MainActor
final class SelectionLimitTests: XCTestCase {
    private var directory: URL!
    private var sessions: [DocumentSession] = []
    private var savedAutoAction: SelectionAutoAction!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        savedAutoAction = ReaderSettings.shared.selectionAutoAction
    }

    override func tearDown() async throws {
        ReaderSettings.shared.selectionAutoAction = savedAutoAction
        for session in sessions {
            session.translation.reset()
            session.closeDocument()
            DocumentOpener.unregister(session)
        }
        sessions = []
        try FileManager.default.removeItem(at: directory)
    }

    // MARK: - Fixtures

    /// `pages` pages of `lines` lines each; every line is `lineLength` characters of small text,
    /// so a page's text length is easy to steer (85 × 80 ≈ 6900 characters per dense page).
    private func makeDocument(pages: Int, lines: Int, lineLength: Int = 80, fontSize: CGFloat = 7,
                              spacing: CGFloat = 10) throws -> PDFDocument {
        let data = NSMutableData()
        let consumer = try XCTUnwrap(CGDataConsumer(data: data))
        var box = CGRect(x: 0, y: 0, width: 600, height: 900)
        let context = try XCTUnwrap(CGContext(consumer: consumer, mediaBox: &box, nil))
        for page in 0..<pages {
            context.beginPDFPage(nil)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
            for row in 0..<lines {
                var text = "p\(page) l\(row) "
                while text.count < lineLength { text += "lorem ipsum " }
                (String(text.prefix(lineLength)) as NSString).draw(
                    at: CGPoint(x: 30, y: 870 - CGFloat(row) * spacing),
                    withAttributes: [.font: NSFont.systemFont(ofSize: fontSize)]
                )
            }
            NSGraphicsContext.restoreGraphicsState()
            context.endPDFPage()
        }
        context.closePDF()
        return try XCTUnwrap(PDFDocument(data: data as Data))
    }

    private func writePDF(_ document: PDFDocument, name: String = "doc") throws -> URL {
        let url = directory.appendingPathComponent(name + ".pdf")
        XCTAssertTrue(document.write(to: url))
        return url
    }

    private func view(showing document: PDFDocument, selecting selection: PDFSelection?) -> PDFView {
        let view = PDFView(frame: CGRect(x: 0, y: 0, width: 600, height: 500))
        view.document = document
        view.setCurrentSelection(selection, animate: false)
        return view
    }

    /// A view inside a (never shown) window, laid out, so `go(to:)` / `currentPage` behave.
    private func hostedView(showing document: PDFDocument) -> (PDFView, NSWindow) {
        let view = PDFView(frame: CGRect(x: 0, y: 0, width: 600, height: 500))
        let window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        view.document = document
        view.displayMode = .singlePageContinuous
        view.autoScales = true
        view.layoutSubtreeIfNeeded()
        return (view, window)
    }

    /// Sum of PDFKit text-range lengths — the quantity the gate measures.
    private func characterCount(of selection: PDFSelection) -> Int {
        var total = 0
        for page in selection.pages {
            for index in 0..<selection.numberOfTextRanges(on: page) {
                total += selection.range(at: index, on: page).length
            }
        }
        return total
    }

    // MARK: - Boundary at the character limit

    func testSelectionAtTheLimitIsAllowedAndOneCharacterOverIsTooLong() throws {
        let document = try makeDocument(pages: 1, lines: 85)
        let page = try XCTUnwrap(document.page(at: 0))
        XCTAssertGreaterThan(page.string?.count ?? 0, SelectionLimits.maxCharacters + 50,
                             "Fixture page must hold more text than the limit")

        let atLimit = try XCTUnwrap(page.selection(for: NSRange(location: 0, length: SelectionLimits.maxCharacters)))
        XCTAssertEqual(characterCount(of: atLimit), SelectionLimits.maxCharacters, "Fixture sanity")
        XCTAssertEqual(SelectionService.size(of: atLimit), .withinLimit)
        let allowed = try XCTUnwrap(SelectionService.snapshot(from: view(showing: document, selecting: atLimit)))
        XCTAssertFalse(allowed.isTooLong)
        XCTAssertFalse(allowed.rawText.isEmpty)
        XCTAssertGreaterThan(allowed.lineRects.count, 10, "A normal selection still gets per-line rects")

        let over = try XCTUnwrap(page.selection(for: NSRange(location: 0, length: SelectionLimits.maxCharacters + 1)))
        XCTAssertEqual(characterCount(of: over), SelectionLimits.maxCharacters + 1, "Fixture sanity")
        XCTAssertEqual(SelectionService.size(of: over), .tooLong)
        let refused = try XCTUnwrap(SelectionService.snapshot(from: view(showing: document, selecting: over)))
        XCTAssertTrue(refused.isTooLong)
    }

    func testTooLongSnapshotCarriesNoTextAndOnlyOneAnchorRect() throws {
        let document = try makeDocument(pages: 1, lines: 85)
        let page = try XCTUnwrap(document.page(at: 0))
        let selection = try XCTUnwrap(page.selection(for: NSRange(location: 0, length: SelectionLimits.maxCharacters + 500)))

        let snapshot = try XCTUnwrap(SelectionService.snapshot(from: view(showing: document, selecting: selection)))
        XCTAssertTrue(snapshot.isTooLong)
        XCTAssertEqual(snapshot.rawText, "", "No text may be assembled for an oversized selection")
        XCTAssertEqual(snapshot.pages.count, 1)
        XCTAssertEqual(snapshot.pages[0].text, "")
        XCTAssertEqual(snapshot.lineRects, [selection.bounds(for: page)],
                       "Exactly one rect, the page bounds of the selection — no per-line rects")
        XCTAssertFalse(snapshot.spansMultiplePages)
    }

    // MARK: - Cheap gate

    func testManyPageSelectionReturnsBeforeAnyPerLineWork() throws {
        let document = try makeDocument(pages: 300, lines: 6)
        let everything = try XCTUnwrap(document.selectionForEntireDocument)
        XCTAssertEqual(everything.pages.count, 300)
        let view = view(showing: document, selecting: everything)

        let passesBefore = SelectionService.linePassCount
        let clock = ContinuousClock()
        var snapshot: SelectionSnapshot?
        let elapsed = clock.measure { snapshot = SelectionService.snapshot(from: view) }

        let result = try XCTUnwrap(snapshot)
        XCTAssertTrue(result.isTooLong)
        XCTAssertEqual(SelectionService.linePassCount, passesBefore,
                       "The O(lines) pass (selectionsByLine + per-line extraction) must not run")
        XCTAssertEqual(result.pages.count, 1)
        XCTAssertEqual(result.lineRects.count, 1)
        XCTAssertEqual(result.rawText, "")
        // Generous bound only as a smoke alarm; the counter above is the real assertion.
        XCTAssertLessThan(elapsed, .seconds(1))
    }

    func testAnchorPageIsTheOneTheReaderIsLookingAt() throws {
        let document = try makeDocument(pages: 30, lines: 6)
        let (view, window) = hostedView(showing: document)
        defer { window.close() }
        view.setCurrentSelection(document.selectionForEntireDocument, animate: false)
        let target = try XCTUnwrap(document.page(at: 17))
        view.go(to: target)
        view.layoutSubtreeIfNeeded()
        XCTAssertEqual(view.currentPage, target, "Fixture sanity")

        let snapshot = try XCTUnwrap(SelectionService.snapshot(from: view))
        XCTAssertTrue(snapshot.isTooLong)
        XCTAssertEqual(snapshot.pageIndex, 17,
                       "The hint card must sit on the page in view, not on page 1 of a 30-page selection")
    }

    func testPageSpanLimitBoundary() throws {
        // One short line per page: the text is far below the character limit, so only the page
        // span can make these selections too long.
        let twelve = try makeDocument(pages: SelectionLimits.maxPageSpan, lines: 1)
        let selectedTwelve = try XCTUnwrap(twelve.selectionForEntireDocument)
        XCTAssertEqual(selectedTwelve.pages.count, SelectionLimits.maxPageSpan)
        XCTAssertEqual(SelectionService.size(of: selectedTwelve), .withinLimit)
        let allowed = try XCTUnwrap(SelectionService.snapshot(from: view(showing: twelve, selecting: selectedTwelve)))
        XCTAssertFalse(allowed.isTooLong)
        XCTAssertEqual(allowed.pages.count, SelectionLimits.maxPageSpan, "Cross-page selections at the limit stay whole")
        XCTAssertTrue(allowed.spansMultiplePages)
        XCTAssertEqual(allowed.pages.map(\.pageIndex), Array(0..<SelectionLimits.maxPageSpan))

        let thirteen = try makeDocument(pages: SelectionLimits.maxPageSpan + 1, lines: 1)
        let selectedThirteen = try XCTUnwrap(thirteen.selectionForEntireDocument)
        XCTAssertEqual(SelectionService.size(of: selectedThirteen), .tooLong)
    }

    func testFewPagesOfDenseTextAreTooLongByCharacterCount() throws {
        // 5 pages is within the page span, so this exercises the running-total path.
        let document = try makeDocument(pages: 5, lines: 85)
        let everything = try XCTUnwrap(document.selectionForEntireDocument)
        XCTAssertLessThanOrEqual(everything.pages.count, SelectionLimits.maxPageSpan)

        let passesBefore = SelectionService.linePassCount
        let snapshot = try XCTUnwrap(SelectionService.snapshot(from: view(showing: document, selecting: everything)))
        XCTAssertTrue(snapshot.isTooLong)
        XCTAssertEqual(SelectionService.linePassCount, passesBefore)
    }

    func testCrossPageSelectionBelowTheLimitKeepsEachPagesText() throws {
        let document = try makeDocument(pages: 3, lines: 12)
        let first = try XCTUnwrap(document.page(at: 0))
        let second = try XCTUnwrap(document.page(at: 1))
        let selection = try XCTUnwrap(first.selection(for: NSRange(location: 0, length: 60)))
        selection.add(try XCTUnwrap(second.selection(for: NSRange(location: 0, length: 90))))

        let passesBefore = SelectionService.linePassCount
        let snapshot = try XCTUnwrap(SelectionService.snapshot(from: view(showing: document, selecting: selection)))
        XCTAssertFalse(snapshot.isTooLong)
        XCTAssertEqual(SelectionService.linePassCount, passesBefore + 1)
        XCTAssertEqual(snapshot.pages.map(\.pageIndex), [0, 1])
        XCTAssertTrue(snapshot.pages[0].text.contains("p0"))
        XCTAssertFalse(snapshot.pages[0].text.contains("p1"))
        XCTAssertTrue(snapshot.pages[1].text.contains("p1"))
        XCTAssertTrue(snapshot.spansMultiplePages)
    }

    func testSelectionWithoutDrawableBoundsProducesNoSnapshot() throws {
        // A page with no text at all: an oversized selection has nothing to anchor a card on and
        // nothing to act on, the same as an empty selection today.
        let document = PDFDocument()
        for index in 0..<(SelectionLimits.maxPageSpan + 3) { document.insert(PDFPage(), at: index) }
        let everything = try XCTUnwrap(document.selectionForEntireDocument)
        XCTAssertNil(SelectionService.snapshot(from: view(showing: document, selecting: everything)))
    }

    func testRefusalMessageNamesTheActionAndTheLimit() {
        let translate = SelectionLimits.tooLongMessage(for: "翻译")
        XCTAssertEqual(translate, "选区过长（超过约 \(SelectionLimits.maxCharacters) 字），请缩小范围后再翻译")
        XCTAssertTrue(SelectionLimits.tooLongMessage(for: "高亮").hasSuffix("再高亮"))
    }

    // MARK: - DocumentSession

    private struct StubbedTranslation {
        let endpoint: URL
    }

    /// A session whose translation service talks to a stubbed endpoint with a temp config/DB.
    private func session() throws -> (DocumentSession, StubbedTranslation) {
        let database = Database(url: directory.appendingPathComponent(UUID().uuidString + ".sqlite"))
        let reader = DocumentSession(documentRepository: DocumentRepository(database: database),
                                     annotationRepository: AnnotationRepository(database: database),
                                     didOpenDocument: { _ in })
        sessions.append(reader)

        let endpoint = StubURLProtocol.register(.init(chunks: [SSE.delta("译文"), SSE.finish("stop"), SSE.done]))
        let configURL = directory.appendingPathComponent(UUID().uuidString + ".json")
        try ConfigLoader.save(TranslationConfig(apiKey: "sk-test", endpoint: endpoint, model: "test-model"),
                              to: configURL)
        reader.translation = TranslationService(session: StubURLProtocol.makeSession(),
                                                repository: TranslationRepository(database: database),
                                                configURL: configURL)
        return (reader, StubbedTranslation(endpoint: endpoint))
    }

    /// What `SelectionService` really produces has no text. Tests that want the *flag* to be the
    /// thing that blocks an action (not merely the absence of text) pass `carryingText`.
    private func tooLongSnapshot(on page: PDFPage, carryingText text: String = "") -> SelectionSnapshot {
        SelectionSnapshot(
            pages: [PageSelection(pageIndex: 0, page: page,
                                  lineRects: [CGRect(x: 30, y: 100, width: 500, height: 700)], text: text)],
            rawText: text,
            isTooLong: true
        )
    }

    private func normalSnapshot(on page: PDFPage, text: String = "Attention is all you need.") -> SelectionSnapshot {
        SelectionSnapshot(
            pages: [PageSelection(pageIndex: 0, page: page,
                                  lineRects: [CGRect(x: 30, y: 800, width: 200, height: 10)], text: text)],
            rawText: text
        )
    }

    func testAutoTranslateIsSkippedForTooLongSelectionButStillRunsForANormalOne() async throws {
        let (reader, stub) = try session()
        ReaderSettings.shared.selectionAutoAction = .translate
        let page = PDFPage()

        // Both the real shape (no text) and one that would otherwise pass the "long enough" test:
        // the flag alone must be enough to stop the auto-action.
        for text in ["", "Attention is all you need."] {
            reader.handleSelectionChanged(tooLongSnapshot(on: page, carryingText: text))
            XCTAssertTrue(reader.hasSelection, "The selection is still there (the card explains why nothing happens)")
            XCTAssertTrue(reader.isSelectionTooLong)
            // Well past the 350ms auto-action debounce.
            try await Task.sleep(for: .milliseconds(600))
            XCTAssertTrue(StubURLProtocol.requests(for: stub.endpoint).isEmpty,
                          "Nothing may be sent for an oversized selection (text: \"\(text)\")")
            XCTAssertNil(reader.translation.current)
            XCTAssertFalse(reader.isTranslationInspectorVisible)
        }

        // Control: the same setup does translate a normal selection, so the silence above is the
        // gate's doing and not a broken harness.
        reader.handleSelectionChanged(normalSnapshot(on: page))
        try await pollUntil { StubURLProtocol.requests(for: stub.endpoint).count == 1 }
        XCTAssertEqual(StubURLProtocol.requests(for: stub.endpoint).count, 1)
    }

    func testAutoTranslatePendingForANormalSelectionIsCancelledByAnOversizedOne() async throws {
        let (reader, stub) = try session()
        ReaderSettings.shared.selectionAutoAction = .translate
        let page = PDFPage()

        reader.handleSelectionChanged(normalSnapshot(on: page))
        reader.handleSelectionChanged(tooLongSnapshot(on: page)) // ⌘A inside the debounce window
        try await Task.sleep(for: .milliseconds(800))
        XCTAssertTrue(StubURLProtocol.requests(for: stub.endpoint).isEmpty)
    }

    func testManualTranslateIsRefusedWithAnExplanationAndNothingIsSent() async throws {
        let (reader, stub) = try session()
        ReaderSettings.shared.selectionAutoAction = .none
        reader.handleSelectionChanged(tooLongSnapshot(on: PDFPage(), carryingText: "Attention is all you need."))

        reader.translateCurrentSelection()

        XCTAssertNil(reader.translation.current, "No partial state, no error card")
        XCTAssertFalse(reader.isTranslationInspectorVisible, "The Inspector must not pop open for a refused request")
        XCTAssertEqual(reader.persistenceNotice, .transient(SelectionLimits.tooLongMessage(for: "翻译")))
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertTrue(StubURLProtocol.requests(for: stub.endpoint).isEmpty)

        // Control: a normal selection goes through the same entry point.
        reader.handleSelectionChanged(normalSnapshot(on: PDFPage()))
        reader.translateCurrentSelection()
        try await pollUntil { StubURLProtocol.requests(for: stub.endpoint).count == 1 }
        XCTAssertEqual(StubURLProtocol.requests(for: stub.endpoint).count, 1)
        XCTAssertTrue(reader.isTranslationInspectorVisible)
    }

    func testHighlightIsUnavailableAndRefusedForTooLongSelection() async throws {
        let (reader, _) = try session()
        ReaderSettings.shared.selectionAutoAction = .none
        let url = try writePDF(try makeDocument(pages: 1, lines: 20))
        reader.openDocument(url: url)
        try await pollUntil { reader.annotationsReady }
        XCTAssertTrue(reader.annotationsReady)
        let page = try XCTUnwrap(reader.document?.page(at: 0))

        // Control: the highlight command is available for a normal selection…
        reader.handleSelectionChanged(normalSnapshot(on: page))
        XCTAssertTrue(reader.canHighlight)
        XCTAssertEqual(reader.highlightHelp, "高亮选区")

        // …and not for an oversized one.
        reader.handleSelectionChanged(tooLongSnapshot(on: page))
        XCTAssertFalse(reader.canHighlight)
        XCTAssertEqual(reader.highlightHelp, SelectionLimits.tooLongMessage(for: "高亮"))
        reader.highlightSelection()
        XCTAssertTrue(page.annotations.isEmpty, "No annotation for an oversized selection")
        XCTAssertTrue(reader.hasSelection, "A refused highlight leaves the selection alone")
        XCTAssertEqual(reader.persistenceNotice, .transient(SelectionLimits.tooLongMessage(for: "高亮")))
    }

    func testAutoHighlightIsSkippedForTooLongSelectionButStillRunsForANormalOne() async throws {
        let (reader, _) = try session()
        ReaderSettings.shared.selectionAutoAction = .highlight
        let url = try writePDF(try makeDocument(pages: 1, lines: 20))
        reader.openDocument(url: url)
        try await pollUntil { reader.annotationsReady }
        XCTAssertTrue(reader.annotationsReady)
        let page = try XCTUnwrap(reader.document?.page(at: 0))

        for text in ["", "Anchor page 0 line 0"] {
            reader.handleSelectionChanged(tooLongSnapshot(on: page, carryingText: text))
            try await Task.sleep(for: .milliseconds(600))
            XCTAssertTrue(page.annotations.isEmpty, "Auto-highlight must not fire for an oversized selection")
        }

        reader.handleSelectionChanged(normalSnapshot(on: page))
        try await pollUntil { !page.annotations.isEmpty }
        XCTAssertEqual(page.annotations.count, 1, "Control: the auto-highlight harness does work")
    }

    func testDerivedSelectionStateIsInertForTooLongSelection() throws {
        let (reader, _) = try session()
        reader.handleSelectionChanged(tooLongSnapshot(on: PDFPage()))
        XCTAssertNil(reader.currentFigureReference)
        XCTAssertNil(reader.translationMatchingCurrentSelection)
        XCTAssertNil(reader.selectionScreenRect(), "No view attached, so no card position; must not crash")
    }
}
