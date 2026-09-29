import AppKit
import PDFKit
import XCTest

/// `AnnotationService.createHighlight` refuses oversized snapshots on its own — `DocumentSession`
/// gates its entry points, but a future caller must not be able to create thousands of
/// annotations. Synthetic PDFs only; nothing is persisted.
@MainActor
final class AnnotationLimitTests: XCTestCase {
    /// `pages` pages of `lines` lines, each `lineLength` characters of small text (an 85 × 80 page
    /// holds ≈ 6900 characters, ~75 of its lines fit under `SelectionLimits.maxCharacters`).
    private func makeDocument(pages: Int, lines: Int, lineLength: Int = 80,
                              fontSize: CGFloat = 7, spacing: CGFloat = 10) throws -> PDFDocument {
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
                    at: CGPoint(x: 30, y: 880 - CGFloat(row) * spacing),
                    withAttributes: [.font: NSFont.systemFont(ofSize: fontSize)]
                )
            }
            NSGraphicsContext.restoreGraphicsState()
            context.endPDFPage()
        }
        context.closePDF()
        return try XCTUnwrap(PDFDocument(data: data as Data))
    }

    /// What a selection of the first `characters` characters of each page in `pages` looks like
    /// once flattened to per-line rects — built straight from PDFKit, bypassing
    /// `SelectionService`'s size gate, which is exactly the situation the service must survive.
    private func snapshot(of document: PDFDocument, pages: Range<Int>,
                          characters: Int? = nil) throws -> SelectionSnapshot {
        var parts: [PageSelection] = []
        for index in pages {
            let page = try XCTUnwrap(document.page(at: index))
            let length = characters ?? (page.string ?? "").utf16.count
            let selection = try XCTUnwrap(page.selection(for: NSRange(location: 0, length: length)))
            var rects: [CGRect] = []
            var text = ""
            for line in selection.selectionsByLine() {
                let rect = line.bounds(for: page)
                guard rect.width > 0.5, rect.height > 0.5 else { continue }
                rects.append(rect)
                text += (text.isEmpty ? "" : "\n") + (line.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            }
            parts.append(PageSelection(pageIndex: index, page: page, lineRects: rects, text: text))
        }
        return SelectionSnapshot(pages: parts, rawText: parts.map(\.text).joined(separator: "\n\n"))
    }

    private func synthetic(pages: Int = 1, rectsPerPage: Int, textLength: Int = 10) -> SelectionSnapshot {
        let parts = (0..<pages).map { index in
            PageSelection(
                pageIndex: index,
                page: PDFPage(),
                lineRects: (0..<rectsPerPage).map { CGRect(x: 10, y: 10 + CGFloat($0) * 0.5, width: 100, height: 8) },
                text: String(repeating: "x", count: textLength)
            )
        }
        return SelectionSnapshot(pages: parts, rawText: parts.map(\.text).joined(separator: "\n\n"))
    }

    private func service(for document: PDFDocument = PDFDocument()) -> AnnotationService {
        AnnotationService(document: document)
    }

    private func annotationCount(_ snapshot: SelectionSnapshot) -> Int {
        snapshot.pages.reduce(0) { $0 + $1.page.annotations.count }
    }

    // MARK: - Real selections

    func testARealSelectionAtTheGateLimitStillBecomesHighlights() throws {
        let document = try makeDocument(pages: 1, lines: 85)
        let page = try XCTUnwrap(document.page(at: 0))
        let view = PDFView(frame: CGRect(x: 0, y: 0, width: 600, height: 500))
        view.document = document
        view.setCurrentSelection(page.selection(for: NSRange(location: 0, length: SelectionLimits.maxCharacters)),
                                 animate: false)
        let admitted = try XCTUnwrap(SelectionService.snapshot(from: view))
        XCTAssertFalse(admitted.isTooLong, "Fixture sanity: the gate admits this selection")
        XCTAssertGreaterThan(admitted.lineRects.count, 40)

        let records = service(for: document).createHighlight(snapshot: admitted, documentId: 1)

        XCTAssertEqual(records.count, 1, "One record per page touched")
        XCTAssertEqual(annotationCount(admitted), admitted.lineRects.count, "One annotation per line")
    }

    func testAMultiPageSelectionWithinTheGateStillBecomesHighlights() throws {
        let document = try makeDocument(pages: 3, lines: 20)
        let multi = try snapshot(of: document, pages: 0..<3)
        XCTAssertEqual(multi.pages.count, 3)

        let records = service(for: document).createHighlight(snapshot: multi, documentId: 1)

        XCTAssertEqual(records.count, 3)
        XCTAssertEqual(Set(records.map(\.groupId)).count, 1, "One group across pages")
    }

    // MARK: - Refusals

    func testTooManyLineRectsFromARealDocumentAreRefusedAndNothingIsAdded() throws {
        // 12 pages (the widest span the gate examines) of ~135 short lines: ≈ 1600 rects but only
        // ≈ 10k characters, so it is the rect count that trips.
        let document = try makeDocument(pages: SelectionLimits.maxPageSpan, lines: 135, lineLength: 5,
                                        fontSize: 6, spacing: 6.5)
        let big = try snapshot(of: document, pages: 0..<SelectionLimits.maxPageSpan)
        let rects = big.pages.reduce(0) { $0 + $1.lineRects.count }
        XCTAssertGreaterThan(rects, AnnotationService.maxHighlightLineRects, "Fixture sanity: \(rects) rects")

        let records = service(for: document).createHighlight(snapshot: big, documentId: 1)

        XCTAssertTrue(records.isEmpty)
        XCTAssertEqual(annotationCount(big), 0, "A refused snapshot must not leave annotations behind")
    }

    func testTooMuchTextFromARealDocumentIsRefusedAndNothingIsAdded() throws {
        // Three dense pages ≈ 20k characters, ~250 rects: the text length is what trips.
        let document = try makeDocument(pages: 3, lines: 85)
        let big = try snapshot(of: document, pages: 0..<3)
        let characters = big.pages.reduce(0) { $0 + $1.text.utf16.count }
        XCTAssertGreaterThan(characters, AnnotationService.maxHighlightCharacters, "Fixture sanity: \(characters)")
        XCTAssertLessThan(big.pages.reduce(0) { $0 + $1.lineRects.count }, AnnotationService.maxHighlightLineRects)

        let records = service(for: document).createHighlight(snapshot: big, documentId: 1)

        XCTAssertTrue(records.isEmpty)
        XCTAssertEqual(annotationCount(big), 0)
    }

    func testTheOversizeFlagAloneIsEnoughToRefuse() {
        let flagged = SelectionSnapshot(
            pages: [PageSelection(pageIndex: 0, page: PDFPage(),
                                  lineRects: [CGRect(x: 10, y: 10, width: 500, height: 700)], text: "")],
            rawText: "", isTooLong: true)

        XCTAssertTrue(service().createHighlight(snapshot: flagged, documentId: 1).isEmpty)
        XCTAssertEqual(annotationCount(flagged), 0)
    }

    // MARK: - Boundaries

    func testLineRectBoundary() {
        let atLimit = synthetic(rectsPerPage: AnnotationService.maxHighlightLineRects)
        XCTAssertEqual(service().createHighlight(snapshot: atLimit, documentId: 1).count, 1)
        XCTAssertEqual(annotationCount(atLimit), AnnotationService.maxHighlightLineRects)

        let over = synthetic(rectsPerPage: AnnotationService.maxHighlightLineRects + 1)
        XCTAssertTrue(service().createHighlight(snapshot: over, documentId: 1).isEmpty)
        XCTAssertEqual(annotationCount(over), 0)
    }

    func testRectsAreCountedAcrossPagesNotPerPage() {
        // Each page is small, the total is not.
        let perPage = AnnotationService.maxHighlightLineRects / SelectionLimits.maxPageSpan + 1
        let spread = synthetic(pages: SelectionLimits.maxPageSpan, rectsPerPage: perPage)
        XCTAssertGreaterThan(perPage * SelectionLimits.maxPageSpan, AnnotationService.maxHighlightLineRects)

        XCTAssertTrue(service().createHighlight(snapshot: spread, documentId: 1).isEmpty)
        XCTAssertEqual(annotationCount(spread), 0)
    }

    func testCharacterBoundaryUsesUTF16LengthLikeTheGate() {
        let atLimit = synthetic(rectsPerPage: 3, textLength: AnnotationService.maxHighlightCharacters)
        XCTAssertEqual(service().createHighlight(snapshot: atLimit, documentId: 1).count, 1)

        let over = synthetic(rectsPerPage: 3, textLength: AnnotationService.maxHighlightCharacters + 1)
        XCTAssertTrue(service().createHighlight(snapshot: over, documentId: 1).isEmpty)
        XCTAssertEqual(annotationCount(over), 0)
    }

    func testPageSpanBoundary() {
        let atLimit = synthetic(pages: AnnotationService.maxHighlightPages, rectsPerPage: 2)
        XCTAssertEqual(service().createHighlight(snapshot: atLimit, documentId: 1).count, AnnotationService.maxHighlightPages)

        let over = synthetic(pages: AnnotationService.maxHighlightPages + 1, rectsPerPage: 2)
        XCTAssertTrue(service().createHighlight(snapshot: over, documentId: 1).isEmpty)
        XCTAssertEqual(annotationCount(over), 0)
    }

    func testLimitsAreDerivedFromTheSelectionGate() {
        // One notion of "too much selection": the gate's own constants, only ever looser.
        XCTAssertEqual(AnnotationService.maxHighlightPages, SelectionLimits.maxPageSpan)
        XCTAssertGreaterThanOrEqual(AnnotationService.maxHighlightCharacters, SelectionLimits.maxCharacters)
        XCTAssertLessThanOrEqual(AnnotationService.maxHighlightLineRects, SelectionLimits.maxCharacters)
    }
}
