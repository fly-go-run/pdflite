import AppKit
import PDFKit
import XCTest

/// Return / ⇧Return in the search field (`SearchService.submit`). Uses a temp PDF only.
@MainActor
final class SearchSubmitTests: XCTestCase {
    private var directory: URL!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try FileManager.default.removeItem(at: directory)
    }

    /// 3 pages x 12 lines "Anchor page P line L": "Anchor" matches 36 times, "line 3" 3 times.
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
        let url = directory.appendingPathComponent("search.pdf")
        try (data as Data).write(to: url)
        return try XCTUnwrap(PDFDocument(url: url))
    }

    private func waitUntil(_ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !predicate(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(predicate(), "Timed out waiting for search state")
    }

    /// A service that has finished searching "Anchor" and sits on match 1 of 36.
    private func searchedService(_ document: PDFDocument) async throws -> SearchService {
        let search = SearchService()
        search.query = "Anchor"
        search.submit(in: document) // no results yet -> fresh search
        try await waitUntil { !search.isSearching && search.totalResults == 36 }
        XCTAssertEqual(search.currentNumber, 1)
        return search
    }

    func testReturnAdvancesThenWrapsInsteadOfRestarting() async throws {
        let document = try makeDocument()
        let search = try await searchedService(document)
        var navigations = 0
        search.onNavigate = { _ in navigations += 1 }

        search.submit(in: document)
        XCTAssertEqual(search.currentNumber, 2, "Return with an unchanged query must step forward, not jump back to 1")
        XCTAssertEqual(search.totalResults, 36, "Results must not be cleared and rescanned")
        search.submit(in: document)
        XCTAssertEqual(search.currentNumber, 3)
        XCTAssertEqual(navigations, 2)

        for _ in 0..<33 { search.submit(in: document) }
        XCTAssertEqual(search.currentNumber, 36)
        search.submit(in: document)
        XCTAssertEqual(search.currentNumber, 1, "Advancing past the last match wraps to the first")
    }

    func testShiftReturnGoesBackAndWraps() async throws {
        let document = try makeDocument()
        let search = try await searchedService(document)

        search.submit(in: document, backwards: true)
        XCTAssertEqual(search.currentNumber, 36, "Backwards from the first match wraps to the last")
        search.submit(in: document, backwards: true)
        XCTAssertEqual(search.currentNumber, 35)
        search.submit(in: document)
        XCTAssertEqual(search.currentNumber, 36, "Forward after backward returns to where we were")
        XCTAssertEqual(search.totalResults, 36)
    }

    func testChangedQueryStartsFreshSearchAtFirstMatch() async throws {
        let document = try makeDocument()
        let search = try await searchedService(document)
        for _ in 0..<4 { search.submit(in: document) }
        XCTAssertEqual(search.currentNumber, 5)

        // Typed but not yet debounced: the results still belong to the old query.
        search.query = "line 3"
        XCTAssertEqual(search.searchedQuery, "Anchor")
        search.submit(in: document)
        try await waitUntil { !search.isSearching && search.totalResults == 3 }
        XCTAssertEqual(search.searchedQuery, "line 3")
        XCTAssertEqual(search.currentNumber, 1, "A new query restarts at match 1")

        search.submit(in: document)
        XCTAssertEqual(search.currentNumber, 2, "...and Return then steps through the new results")
    }

    func testNoResultsRunsFreshSearchEachSubmit() async throws {
        let document = try makeDocument()
        let search = SearchService()
        search.query = "no such text"
        search.submit(in: document)
        try await waitUntil { !search.isSearching }
        XCTAssertFalse(search.hasResults)
        XCTAssertEqual(search.currentNumber, 0)

        // Nothing to step through, so Return searches again (and picks up a corrected query).
        search.query = "Anchor"
        search.submit(in: document)
        try await waitUntil { !search.isSearching && search.totalResults == 36 }
        XCTAssertEqual(search.currentNumber, 1)
    }

    func testClearForgetsSearchedQuery() async throws {
        let document = try makeDocument()
        let search = try await searchedService(document)
        search.clear()
        XCTAssertNil(search.searchedQuery)
        XCTAssertFalse(search.hasResults)
    }
}
