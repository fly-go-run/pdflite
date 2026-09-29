import PDFKit
import XCTest

/// The bibliography index behind `[12]` previews: entry boundaries, the last-entry cap and
/// section stop, header variants, and the bounded header scan. Pure string tests drive the
/// parsing; a few synthetic PDFs cover the extraction path end to end.
@MainActor
final class ReferenceIndexTests: XCTestCase {
    private var directory: URL!

    override func setUp() async throws { directory = try PaperFixtures.makeTempDirectory() }
    override func tearDown() async throws { try FileManager.default.removeItem(at: directory) }

    private func entries(_ text: String) -> [Int: ReferenceEntry] {
        ReferenceIndex.matchEntries(in: text, pageOffsets: [(0, 5)], fallbackPage: 5)
    }

    private func index(pages: [[String]]) async throws -> ReferenceIndex {
        let document = try PaperFixtures.makeDocument(pages: pages, in: directory)
        let index = ReferenceIndex(document: document)
        await index.prepare()
        return index
    }

    // MARK: - Entry boundaries

    func testEntriesEndWhereTheNextMarkerStarts() {
        let found = entries("""
            [1] A. Author. First paper.
            Journal of Things, 2020.
            [2] B. Author. Second paper. Conf, 2021.
            3. C. Author. Third paper, hyphen-
            ated title. 2022.
            """)
        XCTAssertEqual(found.keys.sorted(), [1, 2, 3])
        XCTAssertEqual(found[1]?.text, "A. Author. First paper. Journal of Things, 2020.")
        XCTAssertEqual(found[2]?.text, "B. Author. Second paper. Conf, 2021.")
        XCTAssertEqual(found[3]?.text, "C. Author. Third paper, hyphenated title. 2022.")
        XCTAssertEqual(found[1]?.pageIndex, 5)
    }

    func testFirstOccurrenceOfANumberWins() {
        let found = entries("[1] Real entry. 2020.\n[2] Other. 2021.\n[1] Stray marker in later text.")
        XCTAssertEqual(found[1]?.text, "Real entry. 2020.")
    }

    // MARK: - Last entry: appendix stop and cap

    func testLastEntryStopsAtAStrongSectionHeading() {
        for heading in ["Appendix A", "APPENDIX", "Appendix A: Proofs", "Supplementary Material", "Acknowledgments"] {
            let found = entries("""
                [1] A. Author. First paper. Journal, 2020.
                [2] B. Author. Second paper. Conference, 2021.
                \(heading)
                Proof of Theorem 1. We show that the bound holds for every input.
                """)
            XCTAssertEqual(found[2]?.text, "B. Author. Second paper. Conference, 2021.", heading)
        }
    }

    func testStrongHeadingAlsoStopsAnEntryBeforeALaterListMarker() {
        // The appendix has its own numbered list, so the real last entry is not the last marker.
        let found = entries("""
            [1] A. Author. First paper. 2020.
            [2] B. Author. Second paper. 2021.
            Appendix B
            Some appendix prose.
            1. First step of the procedure
            """)
        XCTAssertEqual(found[2]?.text, "B. Author. Second paper. 2021.")
    }

    func testLastEntryStopsAtWeakHeadingsButMiddleEntriesDoNot() {
        for heading in ["A Proofs", "A. Additional Results", "B.1 Implementation details", "9 Limitations", "ACKNOWLEDGEMENTS"] {
            let found = entries("""
                [1] A. Author. First paper. Journal, 2020.
                [2] B. Author. Second paper. Conference, 2021.
                \(heading)
                Body paragraph of the section that follows the bibliography.
                """)
            XCTAssertEqual(found[2]?.text, "B. Author. Second paper. Conference, 2021.", heading)
        }
        // A wrapped title opening with "A" inside a MIDDLE entry is not a heading.
        let found = entries("""
            [1] K. He, X. Zhang. 2016.
            A Survey of Deep Residual Nets
            in Practice. arXiv, 2016.
            [2] B. Author. Second paper. 2021.
            """)
        XCTAssertEqual(found[1]?.text, "K. He, X. Zhang. 2016. A Survey of Deep Residual Nets in Practice. arXiv, 2016.")
    }

    func testWeakHeadingNeedsAFinishedEntryBeforeIt() {
        // The previous line stops mid-sentence ("…for"), so "A Survey of Graphs" is a wrapped title.
        let found = entries("""
            [1] A. Author. First. 2020.
            [2] K. He. A benchmark for
            A Survey of Graphs
            in practice. arXiv 2021.
            """)
        XCTAssertEqual(found[2]?.text, "K. He. A benchmark for A Survey of Graphs in practice. arXiv 2021.")
    }

    func testCapBoundsAnEntryWithNoCleanEnd() throws {
        let filler = (0..<200).map { "Unrelated running text number \($0) that goes on and on." }.joined(separator: "\n")
        let found = entries("[1] A. Author. First. 2020.\n[2] B. Author. Second. 2021.\n" + filler)
        let text = try XCTUnwrap(found[2]?.text)
        XCTAssertLessThanOrEqual(text.count, ReferenceIndex.maxEntryLength + 1)
        XCTAssertTrue(text.hasSuffix("…"), "a capped entry is marked")
        XCTAssertTrue(text.hasPrefix("B. Author. Second. 2021. Unrelated running text number 0"))
        XCTAssertFalse(text.contains("number 100"))
    }

    func testAnEntryUnderTheCapIsLeftAlone() {
        let long = String(repeating: "Coauthor, ", count: 60) + "et al. 2023."   // ~600 characters
        let found = entries("[1] \(long)\n[2] Next. 2020.")
        XCTAssertEqual(found[1]?.text, long)
    }

    func testHeadingDetectionIsNarrow() {
        typealias Index = ReferenceIndex
        // Strong forms count anywhere, weak ones only when allowed.
        XCTAssertTrue(Index.isSectionHeading("Appendix A", previousLine: "mid sentence for", allowWeakForms: false))
        XCTAssertFalse(Index.isSectionHeading("A Proofs", previousLine: "Journal, 2020.", allowWeakForms: false))
        XCTAssertTrue(Index.isSectionHeading("A Proofs", previousLine: "Journal, 2020.", allowWeakForms: true))
        // Wrapped author lists and continuation lines are not headings, even when weak forms are on.
        for line in ["K. He, X. Zhang, S. Ren, and J. Sun.", "In Proceedings of the IEEE Conference", "arXiv preprint arXiv:1706.03762,",
                     "pages 770–778. IEEE, 2016.", "12", "2019. Deep residual learning", "A Survey of Graphs, Part II"] {
            XCTAssertFalse(Index.isSectionHeading(line, previousLine: "Journal, 2020.", allowWeakForms: true), line)
        }
        // A sentence mentioning the appendix is not a heading.
        XCTAssertFalse(Index.isSectionHeading("Please see the appendix for the details of these proofs, which we omit here.",
                                              previousLine: "2020.", allowWeakForms: true))
    }

    // MARK: - Header variants

    func testHeaderVariants() {
        let accepted = [
            "References", "REFERENCES", "references", "7 References", "7. References", "VII. REFERENCES",
            "References and Notes", "Notes and References", "Reference List", "Bibliography", "BIBLIOGRAPHY",
            "参考文献", "参 考 文 献", "  References  ", "References:",
        ]
        for line in accepted {
            XCTAssertTrue(matchesHeader(line), "header expected: \(line.debugDescription)")
        }
        let rejected = [
            "See the references for details.", "References to prior work are given below", "Cross references",
            "2.3 References", "References [1] A. Author", "Related work and references", "1234 References",
            "mix references", "Reference",
        ]
        for line in rejected {
            XCTAssertFalse(matchesHeader(line), "not a header: \(line.debugDescription)")
        }
    }

    private func matchesHeader(_ line: String) -> Bool {
        // Sit the line between body text so the multi-line anchors do the work.
        let page = "Some body text.\n\(line)\n[1] A. Author. Paper. 2020."
        return ReferenceIndex.headerPattern.firstMatch(in: page, range: NSRange(location: 0, length: (page as NSString).length)) != nil
    }

    // MARK: - End to end on synthetic PDFs

    func testEntriesAcrossPagesAndLastEntryStopsAtTheAppendix() async throws {
        var appendix = ["Appendix A", "Proof of Theorem 1."]
        appendix += (0..<25).map { "Appendix text line \($0) with details of the derivation." }
        let index = try await index(pages: [
            ["Body text of the paper."],
            ["References", "[1] A. Author. First paper. Journal, 2020.", "[2] B. Author. Second paper. Conference, 2021."],
            ["[3] C. Author. Third paper. Conf, 2022.", "[4] D. Author. Fourth paper. Journal, 2023."] + appendix,
        ])
        XCTAssertEqual(index.entry(forNumber: 1)?.text, "A. Author. First paper. Journal, 2020.")
        XCTAssertEqual(index.entry(forNumber: 1)?.pageIndex, 1)
        XCTAssertEqual(index.entry(forNumber: 3)?.pageIndex, 2)
        XCTAssertEqual(index.entry(forNumber: 4)?.text, "D. Author. Fourth paper. Journal, 2023.")
        XCTAssertNil(index.entry(forNumber: 5))
    }

    func testHeaderVariantsBuildAnIndex() async throws {
        for header in ["7 References", "References and Notes", "REFERENCES", "Bibliography", "VII. REFERENCES"] {
            let index = try await index(pages: [["Body."], [header, "[1] A. Author. First paper. Journal, 2020."]])
            XCTAssertEqual(index.entry(forNumber: 1)?.text, "A. Author. First paper. Journal, 2020.", header)
        }
    }

    func testAReferencesHeadingOutsideTheScanWindowIsIgnored() async throws {
        let filler = (0..<(ReferenceIndex.headerScanWindow + 20)).map { ["Filler page \($0)"] }
        let far = try await index(pages: [["References", "[1] A. Author. First paper. Journal, 2020."]] + filler)
        XCTAssertNil(far.entry(forNumber: 1), "a heading this far from the end is a chapter list or a stray line")

        // The same heading just inside the window is used.
        let near = try await index(pages: [["References", "[1] A. Author. First paper. Journal, 2020."]]
                                   + Array(filler.prefix(ReferenceIndex.headerScanWindow - 1)))
        XCTAssertEqual(near.entry(forNumber: 1)?.text.hasPrefix("A. Author. First paper. Journal, 2020."), true)
    }

    func testShortDocumentsAreScannedInFull() async throws {
        // 30 pages: everything is inside the window, including a heading on page 0.
        let pages: [[String]] = [["References", "[1] A. Author. First paper. Journal, 2020."]] + (0..<29).map { ["Filler \($0)"] }
        let index = try await index(pages: pages)
        XCTAssertNotNil(index.entry(forNumber: 1))
    }

    func testAPaperWithoutABibliographyBuildsAnEmptyIndex() async throws {
        let index = try await index(pages: [["Introduction", "A paper that never lists references."], ["Conclusion"]])
        XCTAssertNil(index.entry(forNumber: 1))
    }

    func testPrepareLeavesTheMainActorFree() async throws {
        // The heading sits at the far edge of the scan window, so the build extracts the text of
        // ~58 pages after it. That work runs off the main actor, which keeps ticking meanwhile.
        let body = { (page: Int) in (0..<40).map { "Body sentence \($0) on page \(page) of the paper." } }
        var pages = (0..<80).map(body)
        pages.append(["References", "[1] A. Author. First paper. Journal, 2020."])
        pages += (0..<(ReferenceIndex.headerScanWindow - 2)).map(body)
        let document = try PaperFixtures.makeDocument(pages: pages, in: directory)
        let index = ReferenceIndex(document: document)

        var finished = false
        let build = Task {
            await index.prepare()
            finished = true
        }
        var ticks = 0
        while !finished, ticks < 10_000 {
            try await Task.sleep(for: .milliseconds(1))
            ticks += 1
        }
        await build.value
        XCTAssertNotNil(index.entry(forNumber: 1))
        XCTAssertGreaterThanOrEqual(ticks, 3, "the main actor was blocked while the index was built")
    }
}
