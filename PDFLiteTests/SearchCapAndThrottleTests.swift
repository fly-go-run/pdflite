import AppKit
import PDFKit
import XCTest

/// Bounded, throttled in-document search: the result cap, the streaming flush policy, and the
/// incremental bridge tinting (`SearchTintPlanner`). Temp PDFs only, no window, no real data dir.
@MainActor
final class SearchCapAndThrottleTests: XCTestCase {
    private var directory: URL!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try FileManager.default.removeItem(at: directory)
    }

    // MARK: - Fixtures

    private func makeDocument(_ name: String, pages: Int, lines: Int, text: (Int, Int) -> String) throws -> PDFDocument {
        let data = NSMutableData()
        let consumer = try XCTUnwrap(CGDataConsumer(data: data))
        var box = CGRect(x: 0, y: 0, width: 600, height: 900)
        let context = try XCTUnwrap(CGContext(consumer: consumer, mediaBox: &box, nil))
        for page in 0..<pages {
            context.beginPDFPage(nil)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
            for row in 0..<lines {
                (text(page, row) as NSString).draw(
                    at: CGPoint(x: 40, y: 880 - row * 12),
                    withAttributes: [.font: NSFont.systemFont(ofSize: 8)]
                )
            }
            NSGraphicsContext.restoreGraphicsState()
            context.endPDFPage()
        }
        context.closePDF()
        let url = directory.appendingPathComponent(name + ".pdf")
        try (data as Data).write(to: url)
        return try XCTUnwrap(PDFDocument(url: url))
    }

    /// 3 pages x 12 lines "Anchor page P line L": "Anchor" matches exactly 36 times.
    private func makeSmallDocument() throws -> PDFDocument {
        try makeDocument("small", pages: 3, lines: 12) { page, row in "Anchor page \(page) line \(row)" }
    }

    /// 6 pages x 70 lines x 8 tokens: "zeta" matches 3360 times, well past the 2000 cap.
    private func makeCommonWordDocument() throws -> PDFDocument {
        let line = Array(repeating: "zeta", count: 8).joined(separator: " ")
        return try makeDocument("common", pages: 6, lines: 70) { _, _ in line }
    }

    private func waitUntil(_ predicate: () -> Bool, timeout: Duration = .seconds(15)) async throws {
        let deadline = ContinuousClock.now + timeout
        while !predicate(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(predicate(), "Timed out waiting for search state")
    }

    private func searched(_ query: String, in document: PDFDocument,
                          limit: Int = SearchService.resultLimit) async throws -> SearchService {
        let search = SearchService(resultLimit: limit)
        search.query = query
        search.search(in: document)
        try await waitUntil { !search.isSearching }
        return search
    }

    // MARK: - Cap

    func testCommonWordStopsAtTheCapAndCancelsTheFind() async throws {
        let document = try makeCommonWordDocument()
        let search = SearchService()
        search.query = "zeta"
        var resultsAtFirstNavigation: Int?
        search.onNavigate = { _ in
            if resultsAtFirstNavigation == nil { resultsAtFirstNavigation = search.totalResults }
        }
        search.search(in: document)
        try await waitUntil { !search.isSearching }

        XCTAssertEqual(SearchService.resultLimit, 2000)
        XCTAssertEqual(search.totalResults, 2000, "Results stop at the cap however many matches exist")
        XCTAssertTrue(search.isCapped)
        XCTAssertEqual(search.totalResultsLabel, "2000+")
        XCTAssertEqual(search.currentNumber, 1)
        XCTAssertEqual(resultsAtFirstNavigation, 1, "The first match still lands alone and immediately")
        try await waitUntil { !document.isFinding }

        // Nothing queued from the cancelled find may leak into the list afterwards.
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(search.totalResults, 2000)
        XCTAssertFalse(search.isSearching)
    }

    func testNavigationWrapsWithinTheCappedSet() async throws {
        let document = try makeCommonWordDocument()
        let search = try await searched("zeta", in: document)
        XCTAssertEqual(search.totalResults, 2000)

        search.previous()
        XCTAssertEqual(search.currentNumber, 2000, "Backwards from the first match wraps to the last capped one")
        search.next()
        XCTAssertEqual(search.currentNumber, 1, "Forwards past the last capped match wraps to the first")
        XCTAssertNotNil(search.currentSelection())
    }

    func testFewerMatchesThanTheCapAreExactAndNotCapped() async throws {
        let document = try makeSmallDocument()
        let search = try await searched("Anchor", in: document)
        XCTAssertEqual(search.totalResults, 36)
        XCTAssertFalse(search.isCapped)
        XCTAssertEqual(search.totalResultsLabel, "36")
    }

    func testExactlyTheLimitIsNotCappedButOneMoreIs() async throws {
        let document = try makeSmallDocument()

        let exact = try await searched("Anchor", in: document, limit: 36)
        XCTAssertEqual(exact.totalResults, 36)
        XCTAssertFalse(exact.isCapped, "36 matches with a limit of 36 all fit")

        let over = try await searched("Anchor", in: document, limit: 35)
        XCTAssertEqual(over.totalResults, 35)
        XCTAssertTrue(over.isCapped, "The 36th match proves more exist")
        XCTAssertEqual(over.totalResultsLabel, "35+")
        try await waitUntil { !document.isFinding }
    }

    func testSmallLimitWrapsAndClearResetsCappedState() async throws {
        let document = try makeSmallDocument()
        let search = try await searched("Anchor", in: document, limit: 10)
        for _ in 0..<9 { search.next() }
        XCTAssertEqual(search.currentNumber, 10)
        search.next()
        XCTAssertEqual(search.currentNumber, 1)
        search.previous()
        XCTAssertEqual(search.currentNumber, 10)

        let epoch = search.resultsEpoch
        search.clear()
        XCTAssertFalse(search.isCapped)
        XCTAssertEqual(search.totalResultsLabel, "0")
        XCTAssertGreaterThan(search.resultsEpoch, epoch, "Clearing replaces the result set")
    }

    func testReturnStepsThroughCappedResultsInsteadOfRescanning() async throws {
        let document = try makeSmallDocument()
        let search = try await searched("Anchor", in: document, limit: 10)
        XCTAssertTrue(search.isCapped)

        search.submit(in: document)
        XCTAssertEqual(search.currentNumber, 2, "Return with an unchanged query steps forward")
        search.submit(in: document, backwards: true)
        search.submit(in: document, backwards: true)
        XCTAssertEqual(search.currentNumber, 10, "Shift-Return wraps back to the last capped match")
        XCTAssertEqual(search.totalResults, 10)
        XCTAssertTrue(search.isCapped, "No fresh search ran")
    }

    // MARK: - Throttle

    func testStreamingFlushCountIsBounded() async throws {
        let document = try makeCommonWordDocument()
        let search = try await searched("zeta", in: document)

        // The old fixed batch of 25 flushed 2000 / 25 = 80 times. A fast find like this one is
        // over within a flush interval, so it publishes just the first match and the final list.
        XCTAssertGreaterThanOrEqual(search.flushCount, 2)
        XCTAssertLessThanOrEqual(search.flushCount, 12)
    }

    /// Worst case for the policy: a find slow enough that the interval never holds a flush back,
    /// matches arriving one at a time. Batches still double, so flushes stay logarithmic.
    func testSlowFindFlushesLogarithmically() {
        let limit = SearchService.resultLimit
        var delivered = 0
        var pending = 0
        var flushes = 0
        for _ in 0..<limit {
            pending += 1
            if SearchService.shouldFlush(pending: pending, delivered: delivered, sinceLastFlush: .seconds(1)) {
                delivered += pending
                pending = 0
                flushes += 1
            }
        }
        XCTAssertEqual(delivered + pending, limit)
        XCTAssertLessThanOrEqual(flushes, 10, "Fixed batches of 25 would flush 80 times")
    }

    func testFlushPolicy() {
        let interval = SearchService.minFlushInterval
        let late = interval + .milliseconds(1)
        // The first match is never held back.
        XCTAssertTrue(SearchService.shouldFlush(pending: 1, delivered: 0, sinceLastFlush: .zero))
        XCTAssertFalse(SearchService.shouldFlush(pending: 0, delivered: 0, sinceLastFlush: .zero))
        // Below the minimum batch: wait, however long it has been.
        XCTAssertFalse(SearchService.shouldFlush(pending: 24, delivered: 1, sinceLastFlush: late))
        XCTAssertTrue(SearchService.shouldFlush(pending: 25, delivered: 1, sinceLastFlush: late))
        // Batches grow with the list: 100 delivered needs 100 pending, not 25.
        XCTAssertFalse(SearchService.shouldFlush(pending: 99, delivered: 100, sinceLastFlush: late))
        XCTAssertTrue(SearchService.shouldFlush(pending: 100, delivered: 100, sinceLastFlush: late))
        // ...and never more often than the interval, however big the batch.
        XCTAssertFalse(SearchService.shouldFlush(pending: 5000, delivered: 100, sinceLastFlush: interval - .milliseconds(1)))
        XCTAssertTrue(SearchService.shouldFlush(pending: 5000, delivered: 100, sinceLastFlush: interval))
    }

    // MARK: - Stale notifications

    func testStaleEndNotificationsAreIgnored() async throws {
        let document = try makeCommonWordDocument()
        let search = SearchService()
        search.query = "zeta"
        search.search(in: document)
        let generation = search.findGeneration

        search.findDidEnd(generation: generation - 1, documentIsFinding: false)
        XCTAssertTrue(search.isSearching, "An end notification from an older find must not finish this one")
        search.findDidEnd(generation: generation, documentIsFinding: true)
        XCTAssertTrue(search.isSearching, "An end notification while the document is still finding is stale")

        try await waitUntil { !search.isSearching }
        XCTAssertEqual(search.totalResults, 2000)
    }

    func testCancelledEarlierFindDoesNotDisturbTheNextOne() async throws {
        let document = try makeSmallDocument()
        let search = SearchService()
        search.query = "Anchor"
        search.search(in: document)
        // Retype before the first find finishes: it is cancelled and may still post DidEndFind.
        search.query = "line 3"
        search.search(in: document)
        XCTAssertEqual(search.searchedQuery, "line 3")

        try await waitUntil { !search.isSearching }
        XCTAssertEqual(search.totalResults, 3, "Only the second query's matches, complete")
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(search.totalResults, 3, "Late matches from the cancelled find are dropped")
        XCTAssertEqual(search.searchedQuery, "line 3")
    }
}

/// Incremental bridge tinting: which selections get recoloured, and when the PDFView's
/// `highlightedSelections` is re-assigned.
@MainActor
final class SearchTintPlannerTests: XCTestCase {
    typealias Recolor = SearchTintPlanner.Recolor

    func testFirstPassTintsEverythingAndMarksTheCurrentOne() {
        var planner = SearchTintPlanner()
        let plan = planner.plan(epoch: 1, resultsRevision: 1, count: 5, currentIndex: 0)
        XCTAssertEqual(plan.tint, 0..<5)
        XCTAssertEqual(plan.recolor, [Recolor(index: 0, isCurrent: true)])
        XCTAssertTrue(plan.reassign)
        XCTAssertFalse(plan.clear)
    }

    func testNothingChangedDoesNothing() {
        var planner = SearchTintPlanner()
        _ = planner.plan(epoch: 1, resultsRevision: 1, count: 5, currentIndex: 0)
        XCTAssertTrue(planner.plan(epoch: 1, resultsRevision: 1, count: 5, currentIndex: 0).isEmpty,
                      "Unrelated updateNSView passes (page turns, zoom) must be free")
    }

    func testNavigationRecoloursTwoSelectionsAndNeverReassigns() {
        var planner = SearchTintPlanner()
        _ = planner.plan(epoch: 1, resultsRevision: 1, count: 2000, currentIndex: 0)

        let step = planner.plan(epoch: 1, resultsRevision: 1, count: 2000, currentIndex: 1)
        XCTAssertEqual(step.recolor, [Recolor(index: 0, isCurrent: false), Recolor(index: 1, isCurrent: true)])
        XCTAssertTrue(step.tint.isEmpty)
        XCTAssertFalse(step.reassign, "highlightedSelections is not re-assigned on navigation")

        let wrapBack = planner.plan(epoch: 1, resultsRevision: 1, count: 2000, currentIndex: 1999)
        XCTAssertEqual(wrapBack.recolor, [Recolor(index: 1, isCurrent: false), Recolor(index: 1999, isCurrent: true)])
        XCTAssertFalse(wrapBack.reassign)
    }

    func testFlushTintsOnlyTheNewTailAndReassignsOnce() {
        var planner = SearchTintPlanner()
        _ = planner.plan(epoch: 1, resultsRevision: 1, count: 1, currentIndex: 0)
        let flush = planner.plan(epoch: 1, resultsRevision: 2, count: 26, currentIndex: 0)
        XCTAssertEqual(flush.tint, 1..<26)
        XCTAssertTrue(flush.recolor.isEmpty, "The current match did not move")
        XCTAssertTrue(flush.reassign)
    }

    func testNewResultSetStartsFromScratch() {
        var planner = SearchTintPlanner()
        _ = planner.plan(epoch: 1, resultsRevision: 1, count: 40, currentIndex: 7)
        // The bridge may never see the empty in-between state of a restarted search.
        let plan = planner.plan(epoch: 2, resultsRevision: 3, count: 3, currentIndex: 0)
        XCTAssertEqual(plan.tint, 0..<3)
        XCTAssertEqual(plan.recolor, [Recolor(index: 0, isCurrent: true)],
                       "Old selections are gone; nothing to reset")
        XCTAssertTrue(plan.reassign)
    }

    func testClearingDropsHighlightsOnceThenIdles() {
        var planner = SearchTintPlanner()
        XCTAssertTrue(planner.plan(epoch: 0, resultsRevision: 0, count: 0, currentIndex: 0).isEmpty)
        _ = planner.plan(epoch: 1, resultsRevision: 1, count: 4, currentIndex: 0)

        XCTAssertTrue(planner.plan(epoch: 2, resultsRevision: 2, count: 0, currentIndex: 0).clear)
        XCTAssertTrue(planner.plan(epoch: 2, resultsRevision: 2, count: 0, currentIndex: 0).isEmpty)

        let again = planner.plan(epoch: 3, resultsRevision: 3, count: 4, currentIndex: 0)
        XCTAssertEqual(again.tint, 0..<4)
        XCTAssertTrue(again.reassign)
    }

    /// The point of the whole exercise: over a streaming search plus a long stretch of ⌘G,
    /// every selection is tinted once and navigation costs two recolours, not n.
    func testTotalTintWorkIsLinear() {
        var planner = SearchTintPlanner()
        var tinted = 0
        var reassigns = 0
        var count = 0
        var revision = 0
        while count < 2000 {
            count = min(2000, count + (count == 0 ? 1 : max(25, count)))
            revision += 1
            let plan = planner.plan(epoch: 1, resultsRevision: revision, count: count, currentIndex: 0)
            tinted += plan.tint.count
            reassigns += plan.reassign ? 1 : 0
        }
        XCTAssertEqual(tinted, 2000, "Each selection is tinted exactly once")
        XCTAssertLessThanOrEqual(reassigns, 12)

        var recolors = 0
        for step in 1...2500 {
            let plan = planner.plan(epoch: 1, resultsRevision: revision, count: 2000, currentIndex: step % 2000)
            recolors += plan.recolor.count
            XCTAssertFalse(plan.reassign)
        }
        XCTAssertEqual(recolors, 2 * 2500)
    }
}

/// `SearchTintPlanner.sync` end to end against a real PDFView and real selections.
@MainActor
final class SearchTintSyncTests: XCTestCase {
    private var directory: URL!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try FileManager.default.removeItem(at: directory)
    }

    /// Counts how often `highlightedSelections` is assigned.
    private final class CountingPDFView: PDFView {
        var assignCount = 0
        override var highlightedSelections: [PDFSelection]? {
            didSet { assignCount += 1 }
        }
    }

    private func makeDocument() throws -> PDFDocument {
        let data = NSMutableData()
        let consumer = try XCTUnwrap(CGDataConsumer(data: data))
        var box = CGRect(x: 0, y: 0, width: 600, height: 900)
        let context = try XCTUnwrap(CGContext(consumer: consumer, mediaBox: &box, nil))
        for page in 0..<3 {
            context.beginPDFPage(nil)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
            for row in 0..<12 {
                ("Anchor page \(page) line \(row)" as NSString).draw(
                    at: CGPoint(x: 60, y: 800 - row * 40),
                    withAttributes: [.font: NSFont.systemFont(ofSize: 16)]
                )
            }
            NSGraphicsContext.restoreGraphicsState()
            context.endPDFPage()
        }
        context.closePDF()
        let url = directory.appendingPathComponent("tint.pdf")
        try (data as Data).write(to: url)
        return try XCTUnwrap(PDFDocument(url: url))
    }

    private func waitUntil(_ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while !predicate(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(predicate(), "Timed out waiting for search state")
    }

    /// Indices of the results currently coloured orange.
    private func currentColoured(_ search: SearchService) -> [Int] {
        search.results.indices.filter { search.results[$0].color == .orange }
    }

    func testNavigationRecoloursInPlaceWithoutReassigningHighlights() async throws {
        let document = try makeDocument()
        let view = CountingPDFView(frame: CGRect(x: 0, y: 0, width: 600, height: 500))
        view.document = document
        let search = SearchService()
        search.query = "Anchor"
        search.search(in: document)
        try await waitUntil { !search.isSearching && search.totalResults == 36 }

        var planner = SearchTintPlanner()
        planner.sync(with: search, to: view)
        XCTAssertEqual(view.assignCount, 1)
        XCTAssertEqual(view.highlightedSelections?.count, 36)
        XCTAssertEqual(currentColoured(search), [0])
        XCTAssertTrue(search.results.dropFirst().allSatisfy { $0.color == .yellow },
                      "Every non-current match keeps the normal colour")

        planner.sync(with: search, to: view)
        XCTAssertEqual(view.assignCount, 1, "An unrelated updateNSView pass changes nothing")

        for expected in 1...40 {
            search.next()
            planner.sync(with: search, to: view)
            XCTAssertEqual(currentColoured(search), [expected % 36], "Exactly the new current match is orange")
        }
        XCTAssertEqual(view.assignCount, 1, "40 navigations, still the one assignment from the result flush")

        search.previous()
        planner.sync(with: search, to: view)
        XCTAssertEqual(currentColoured(search), [3])
        XCTAssertEqual(view.assignCount, 1)
    }

    func testNewSearchAndClearReassignAndReset() async throws {
        let document = try makeDocument()
        let view = CountingPDFView(frame: CGRect(x: 0, y: 0, width: 600, height: 500))
        view.document = document
        let search = SearchService()
        search.query = "Anchor"
        search.search(in: document)
        try await waitUntil { !search.isSearching && search.totalResults == 36 }
        var planner = SearchTintPlanner()
        planner.sync(with: search, to: view)
        search.next()
        planner.sync(with: search, to: view)

        search.query = "line 3"
        search.search(in: document)
        try await waitUntil { !search.isSearching && search.totalResults == 3 }
        planner.sync(with: search, to: view)
        XCTAssertEqual(view.assignCount, 2, "A new result set is assigned once")
        XCTAssertEqual(view.highlightedSelections?.count, 3)
        XCTAssertEqual(currentColoured(search), [0])
        XCTAssertTrue(search.results.dropFirst().allSatisfy { $0.color == .yellow })

        search.clear()
        planner.sync(with: search, to: view)
        XCTAssertNil(view.highlightedSelections)
        XCTAssertEqual(view.assignCount, 3)
        planner.sync(with: search, to: view)
        XCTAssertEqual(view.assignCount, 3, "Nothing left to clear")
    }
}
