import AppKit
import PDFKit
import XCTest

/// Caption-vs-mention selection for the Figure/Table jump, on plain page texts and on synthetic
/// PDFs, plus the async contract: the scan doesn't hold the main actor, and a cancelled or
/// superseded jump never navigates.
@MainActor
final class FigureJumpTests: XCTestCase {
    private var directory: URL!
    private var sessions: [DocumentSession] = []

    override func setUp() async throws { directory = try PaperFixtures.makeTempDirectory() }

    override func tearDown() async throws {
        for session in sessions {
            session.closeDocument()
            DocumentOpener.unregister(session)
        }
        sessions = []
        try FileManager.default.removeItem(at: directory)
    }

    private let figure3 = FigureReference(kind: .figure, number: 3)

    private func hit(_ texts: [String], _ reference: FigureReference? = nil, source: Int? = nil) -> FigureJumpService.Hit? {
        FigureJumpService.bestHit(forPageTexts: texts, reference: reference ?? figure3, sourcePage: source)
    }

    private func matchedText(_ hit: FigureJumpService.Hit?, in texts: [String]) -> String? {
        guard let hit else { return nil }
        return (texts[hit.pageIndex] as NSString).substring(with: hit.range)
    }

    // MARK: - Pure selection over page texts

    func testCaptionBeatsAnEarlierInlineMention() {
        let texts = [
            "Introduction\nOur model is described in detail, as shown in Figure 3.",
            "More text\nFigure 3. Overview of the model.",
        ]
        for source in [nil, 0, 1] as [Int?] {
            let found = hit(texts, source: source)
            XCTAssertEqual(found?.pageIndex, 1, "source=\(String(describing: source))")
            XCTAssertEqual(matchedText(found, in: texts), "Figure 3.")
        }
    }

    func testEveryCaptionStyleWinsOverMentions() {
        let styles = [
            "Figure 3: Overview", "Fig. 3. Overview", "Fig. 3 | Overview", "Fig. 3 Overview of the model",
        ]
        for caption in styles {
            let texts = ["See Figure 3. Next\nas shown in Fig. 3.", "text\n\(caption)"]
            XCTAssertEqual(hit(texts)?.pageIndex, 1, caption)
        }
    }

    func testLowercaseContinuationAtLineStartIsAMentionNotACaption() {
        // A wrapped sentence can open a line with "Figure 3" — but it goes on in lowercase.
        let texts = [
            "as can be seen in\nFigure 3 shows the effect of depth",
            "text\nFigure 3. Overview of the model.",
        ]
        XCTAssertEqual(hit(texts)?.pageIndex, 1)
    }

    func testCaptionOnAnotherPageBeatsCaptionOnTheSourcePage() {
        // The user clicked on page 0; "advance to the caption, not where you clicked" still holds.
        let texts = ["Figure 3. Overview\n", "filler", "Figure 3. Overview (appendix copy)"]
        XCTAssertEqual(hit(texts, source: 0)?.pageIndex, 2)
        XCTAssertEqual(hit(texts, source: nil)?.pageIndex, 0)
    }

    func testCaptionOnTheSourcePageStillBeatsMentionsElsewhere() {
        // Figure and its first mention share a page: clicking that mention lands on the caption
        // beside it rather than wandering off to an earlier mention.
        let texts = [
            "Intro\nwe show this in Figure 3.",
            "Figure 3. Overview of the model.\nAs Figure 3 shows",
        ]
        XCTAssertEqual(hit(texts, source: 1)?.pageIndex, 1)
    }

    func testMentionIsTheFallbackWhenThereIsNoCaption() {
        let texts = ["as in Figure 3.", "filler", "see Fig. 3 for details"]
        XCTAssertEqual(hit(texts, source: nil)?.pageIndex, 0)
        XCTAssertEqual(hit(texts, source: 0)?.pageIndex, 2, "prefer a mention away from the click")
        XCTAssertEqual(hit(["only here Figure 3 appears"], source: 0)?.pageIndex, 0, "source page is the last resort")
    }

    func testNoMatchAndCloseLookalikesReturnNil() {
        XCTAssertNil(hit([]))
        XCTAssertNil(hit(["nothing relevant here", "Table 3. Not a figure"]))
        // Figure 30 / Figure 3.2 / prefigure are different things.
        XCTAssertNil(hit(["Figure 30. Something else", "Figure 3.2 A chapter figure\nsee Figure 30."]))
        XCTAssertNil(hit(["a prefigure 3 wording"]))
    }

    func testTablesAndSupplementaryLabels() {
        let table2 = FigureReference(kind: .table, number: 2)
        let texts = ["as reported in Table 2.", "Table 2. Results on the test set."]
        XCTAssertEqual(hit(texts, table2)?.pageIndex, 1)

        let supp = FigureReference(kind: .figure, number: 3, isSupplementary: true)
        let mixed = ["Figure 3. Main caption", "Figure S3. Supplementary caption"]
        XCTAssertEqual(hit(mixed, supp)?.pageIndex, 1, "S3 must not resolve to Figure 3")
        XCTAssertEqual(hit(mixed, figure3)?.pageIndex, 0, "3 must not resolve to Figure S3")
    }

    // MARK: - End to end on synthetic PDFs

    private func threePageDocument() throws -> PDFDocument {
        try PaperFixtures.makeDocument(pages: [
            ["Introduction", "Our model is described in detail, as shown in Figure 3."],
            ["Some text on page two", "Figure 3. Overview of the model."],
            ["Results", "Table 2. Results on the test set.", "as reported in Table 2."],
        ], in: directory)
    }

    func testLocateReturnsTheCaptionSelectionNotTheMention() async throws {
        let document = try threePageDocument()
        let selection = await FigureJumpService.locate(figure3, in: document, excluding: nil)
        let found = try XCTUnwrap(selection)
        XCTAssertEqual(found.pages.first.map { document.index(for: $0) }, 1)
        XCTAssertTrue(found.string?.hasPrefix("Figure 3") == true, "selection text: \(found.string ?? "nil")")

        // Clicking the mention on page 0 gets the same answer.
        let fromMention = await FigureJumpService.locate(figure3, in: document, excluding: 0)
        XCTAssertEqual(fromMention?.pages.first.map { document.index(for: $0) }, 1)

        let table = await FigureJumpService.locate(FigureReference(kind: .table, number: 2), in: document, excluding: 2)
        XCTAssertEqual(table?.pages.first.map { document.index(for: $0) }, 2, "caption on the source page beats its own mention")
    }

    func testLocateFindsNothingForAMissingFigure() async throws {
        let document = try threePageDocument()
        let missing = await FigureJumpService.locate(FigureReference(kind: .figure, number: 9), in: document, excluding: nil)
        XCTAssertNil(missing)
    }

    func testLocateFallsBackToAMentionWhenNoCaptionIsRecognised() async throws {
        let document = try PaperFixtures.makeDocument(pages: [["Results"], ["and Figure 3 illustrates the trend"]], in: directory)
        let selection = await FigureJumpService.locate(figure3, in: document, excluding: nil)
        XCTAssertEqual(selection?.pages.first.map { document.index(for: $0) }, 1)
    }

    // MARK: - Async contract

    func testACancelledLocateReturnsNil() async throws {
        let document = try threePageDocument()
        // Page index rather than the selection: PDFSelection isn't Sendable, so it can't leave a Task.
        let task = Task { () -> Int? in
            let selection = await FigureJumpService.locate(self.figure3, in: document, excluding: nil)
            return selection?.pages.first.map { document.index(for: $0) }
        }
        task.cancel()
        let result = await task.value
        XCTAssertNil(result, "a cancelled jump must not produce a target")
    }

    func testTheScanDoesNotHoldTheMainActor() async throws {
        // No hit anywhere: the whole document is scanned. The old code ran up to 12 synchronous
        // findString passes on the main thread for this; now the main actor keeps ticking.
        let pages = (0..<300).map { page in (0..<40).map { "Filler sentence number \($0) on page \(page) of the paper." } }
        let document = try PaperFixtures.makeDocument(pages: pages, in: directory)

        var finished = false
        let scan = Task { () -> Int? in
            let result = await FigureJumpService.locate(self.figure3, in: document, excluding: nil)
            finished = true
            return result?.pages.first.map { document.index(for: $0) }
        }
        var ticks = 0
        while !finished, ticks < 10_000 {
            try await Task.sleep(for: .milliseconds(1))
            ticks += 1
        }
        let result = await scan.value
        XCTAssertNil(result)
        XCTAssertGreaterThanOrEqual(ticks, 3, "the main actor was blocked for the whole scan")
    }

    // MARK: - Session: superseded jumps

    private func openedSession(_ document: PDFDocument) async throws -> (DocumentSession, ReaderPDFView, NSWindow) {
        let database = Database(url: directory.appendingPathComponent(UUID().uuidString + ".sqlite"))
        let session = DocumentSession(documentRepository: DocumentRepository(database: database),
                                      annotationRepository: AnnotationRepository(database: database),
                                      didOpenDocument: { _ in })
        sessions.append(session)
        let url = try XCTUnwrap(document.documentURL)
        session.openDocument(url: url)
        let deadline = ContinuousClock.now + .seconds(5)
        while !session.hasDocument, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(session.hasDocument)

        let view = ReaderPDFView(frame: CGRect(x: 0, y: 0, width: 600, height: 500))
        let window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        view.document = try XCTUnwrap(session.document)
        view.displayMode = .singlePageContinuous
        view.autoScales = false
        view.scaleFactor = 1.0
        view.layoutSubtreeIfNeeded()
        session.pdfView = view
        session.restoreBridgeIfNeeded(in: view)
        return (session, view, window)
    }

    private func select(_ text: String, on pageIndex: Int, in session: DocumentSession) throws {
        let page = try XCTUnwrap(session.document?.page(at: pageIndex))
        session.handleSelectionChanged(SelectionSnapshot(pages: [PageSelection(
            pageIndex: pageIndex, page: page, lineRects: [CGRect(x: 40, y: 800, width: 80, height: 12)], text: text
        )], rawText: text))
    }

    func testClickingAFigureReferenceJumpsToTheCaption() async throws {
        let (session, view, window) = try await openedSession(try threePageDocument())
        defer { window.close() }
        try select("Figure 3", on: 0, in: session)
        XCTAssertEqual(session.currentFigureReference, figure3)

        session.jumpToCurrentFigure()
        let deadline = ContinuousClock.now + .seconds(5)
        while view.currentPage.flatMap({ view.document?.index(for: $0) }) != 1, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(view.currentPage.flatMap { view.document?.index(for: $0) }, 1)
        XCTAssertNil(session.selection, "the floating panel's selection is dropped when the jump lands")
    }

    func testASupersededJumpNeverNavigates() async throws {
        let (session, view, window) = try await openedSession(try threePageDocument())
        defer { window.close() }
        var visited: [Int] = []
        let observer = NotificationCenter.default.addObserver(forName: .PDFViewPageChanged, object: view, queue: .main) { _ in
            MainActor.assumeIsolated {
                if let page = view.currentPage, let index = view.document?.index(for: page) { visited.append(index) }
            }
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        try select("Figure 3", on: 0, in: session)
        session.jumpToCurrentFigure()
        // Before the first scan can land, the user asks for Table 2 instead.
        try select("Table 2", on: 0, in: session)
        session.jumpToCurrentFigure()

        let deadline = ContinuousClock.now + .seconds(5)
        while view.currentPage.flatMap({ view.document?.index(for: $0) }) != 2, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        try await Task.sleep(for: .milliseconds(300)) // room for a wrongly-surviving first jump
        XCTAssertEqual(view.currentPage.flatMap { view.document?.index(for: $0) }, 2)
        XCTAssertFalse(visited.contains(1), "the superseded Figure 3 jump navigated: \(visited)")
    }

    func testAJumpFinishingAfterTheDocumentClosedDoesNotNavigate() async throws {
        let (session, view, window) = try await openedSession(try threePageDocument())
        defer { window.close() }
        try select("Figure 3", on: 0, in: session)
        session.jumpToCurrentFigure()
        session.closeDocument()
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertNotEqual(view.currentPage.flatMap { view.document?.index(for: $0) }, 1)
    }
}
