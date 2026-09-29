import AppKit
import PDFKit
import XCTest

/// Reading order of `SelectionService`: pages ascending, but *within* a page whatever order
/// PDFKit reports (which follows columns) — never a geometric top-first re-sort.
@MainActor
final class SelectionOrderingTests: XCTestCase {
    // MARK: - Pure ordering rule

    func testOrderingIsByPageOnlyAndStableWithinAPage() {
        // (page, y): the page-1 entries mimic column 1 (bottom) followed by column 2 (top).
        let items: [(page: Int, y: CGFloat, name: String)] = [
            (1, 100, "p1 col1 bottom"),
            (0, 700, "p0 col2 top"),
            (1, 800, "p1 col2 top"),
            (0, 100, "p0 col1 bottom"),
            (1, 90, "p1 col1 lowest")
        ]
        let ordered = SelectionService.inDocumentOrder(items) { $0.page }
        XCTAssertEqual(ordered.map(\.name), [
            "p0 col2 top", "p0 col1 bottom",
            "p1 col1 bottom", "p1 col2 top", "p1 col1 lowest"
        ])
    }

    func testOrderingKeepsAlreadySortedInputAndHandlesEmpty() {
        XCTAssertEqual(SelectionService.inDocumentOrder([0, 0, 1, 2, 2]) { $0 }, [0, 0, 1, 2, 2])
        XCTAssertEqual(SelectionService.inDocumentOrder([Int]()) { $0 }, [])
    }

    // MARK: - Two-column page

    /// Two 10-line columns. Column 1 is written first, so the stream (and PDFKit's text order)
    /// reads down the left column, then down the right one.
    private func twoColumnDocument() throws -> PDFDocument {
        let data = NSMutableData()
        let consumer = try XCTUnwrap(CGDataConsumer(data: data))
        var box = CGRect(x: 0, y: 0, width: 600, height: 900)
        let context = try XCTUnwrap(CGContext(consumer: consumer, mediaBox: &box, nil))
        context.beginPDFPage(nil)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        for (name, x) in [("Left", 50), ("Right", 330)] {
            for row in 0..<10 {
                ("\(name) column line \(row)" as NSString).draw(
                    at: CGPoint(x: x, y: 800 - row * 40),
                    withAttributes: [.font: NSFont.systemFont(ofSize: 16)]
                )
            }
        }
        NSGraphicsContext.restoreGraphicsState()
        context.endPDFPage()
        context.closePDF()
        return try XCTUnwrap(PDFDocument(data: data as Data))
    }

    func testParagraphRunningFromColumnOneIntoColumnTwoKeepsPDFKitOrder() throws {
        let document = try twoColumnDocument()
        let page = try XCTUnwrap(document.page(at: 0))
        let text = try XCTUnwrap(page.string as NSString?)

        // From the end of the left column to the start of the right one.
        let start = text.range(of: "Left column line 8")
        let end = text.range(of: "Right column line 1")
        XCTAssertNotEqual(start.location, NSNotFound)
        XCTAssertNotEqual(end.location, NSNotFound)
        let range = NSRange(location: start.location, length: NSMaxRange(end) - start.location)
        let selection = try XCTUnwrap(page.selection(for: range))

        let view = PDFView(frame: CGRect(x: 0, y: 0, width: 600, height: 500))
        view.document = document
        view.currentSelection = selection

        // What PDFKit itself reports, line by line.
        let pdfKitLines = selection.selectionsByLine().compactMap {
            $0.string?.trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty }
        let rects = selection.selectionsByLine().map { $0.bounds(for: page) }

        // Fixture sanity: the selection really crosses columns, i.e. a geometric top-first sort
        // would reorder it (a later line sits higher on the page than an earlier one).
        XCTAssertTrue(zip(rects, rects.dropFirst()).contains { $1.maxY > $0.maxY },
                      "Fixture must contain a column jump; got lines \(pdfKitLines)")

        let snapshot = try XCTUnwrap(SelectionService.snapshot(from: view))
        let emitted = snapshot.rawText.split(whereSeparator: \.isNewline).map(String.init)
        XCTAssertEqual(emitted, pdfKitLines, "Lines must come out in PDFKit's reading order")

        let leftEnd = try XCTUnwrap(emitted.firstIndex { $0.contains("Left column line 9") })
        let rightStart = try XCTUnwrap(emitted.firstIndex { $0.contains("Right column line 0") })
        XCTAssertLessThan(leftEnd, rightStart, "Column 1 must be read before column 2")
    }

    func testHighlightRectsStayPerLineAndUnsorted() throws {
        let document = try twoColumnDocument()
        let page = try XCTUnwrap(document.page(at: 0))
        let text = try XCTUnwrap(page.string as NSString?)
        let start = text.range(of: "Left column line 8")
        let end = text.range(of: "Right column line 1")
        let selection = try XCTUnwrap(page.selection(for: NSRange(location: start.location,
                                                                  length: NSMaxRange(end) - start.location)))
        let view = PDFView(frame: CGRect(x: 0, y: 0, width: 600, height: 500))
        view.document = document
        view.currentSelection = selection

        let snapshot = try XCTUnwrap(SelectionService.snapshot(from: view))
        let expected = selection.selectionsByLine().map { $0.bounds(for: page) }
            .filter { $0.width > 0.5 && $0.height > 0.5 }

        XCTAssertEqual(snapshot.pages.count, 1)
        XCTAssertEqual(snapshot.lineRects, expected, "Annotation rects are the per-line bounds, in PDFKit order")
        XCTAssertGreaterThan(snapshot.lineRects.count, 2)
        for rect in snapshot.lineRects {
            XCTAssertLessThan(rect.width, 300, "No rect may span both columns")
        }
    }
}
