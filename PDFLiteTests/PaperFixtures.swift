import AppKit
import PDFKit
import XCTest

/// Synthetic text PDFs for the paper-heuristics tests (FigureReference / FigureJump /
/// ReferenceIndex). Each page is a list of lines drawn top-to-bottom, so PDFKit's text layer sees
/// one visual line per entry — the same shape `page.string` has for a real single-column paper.
/// Nothing here is downloaded or bundled; every PDF is generated in-process into `directory`.
enum PaperFixtures {
    @MainActor
    static func makePDF(pages: [[String]], in directory: URL, name: String = UUID().uuidString) throws -> URL {
        let data = NSMutableData()
        let consumer = try XCTUnwrap(CGDataConsumer(data: data))
        var box = CGRect(x: 0, y: 0, width: 600, height: 900)
        let context = try XCTUnwrap(CGContext(consumer: consumer, mediaBox: &box, nil))
        for lines in pages {
            context.beginPDFPage(nil)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
            for (row, line) in lines.enumerated() {
                (line as NSString).draw(
                    at: CGPoint(x: 40, y: 860 - row * 14),
                    withAttributes: [.font: NSFont.systemFont(ofSize: 10)]
                )
            }
            NSGraphicsContext.restoreGraphicsState()
            context.endPDFPage()
        }
        context.closePDF()
        let url = directory.appendingPathComponent(name + ".pdf")
        try (data as Data).write(to: url)
        return url
    }

    @MainActor
    static func makeDocument(pages: [[String]], in directory: URL, name: String = UUID().uuidString) throws -> PDFDocument {
        try XCTUnwrap(PDFDocument(url: makePDF(pages: pages, in: directory, name: name)))
    }

    static func makeTempDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
