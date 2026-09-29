import XCTest

/// Table-driven coverage for `RemoteDocumentURL.parse` — the one place every "open from the
/// internet" spelling is normalized before download AND before the dedup token is computed.
/// Site rules were each verified against a real paper with header-only requests.
final class RemoteDocumentURLTests: XCTestCase {
    private struct Case {
        let input: String
        /// What gets downloaded.
        let download: String
        /// nil for web sources; the arXiv id when the source must be routed to arXiv.
        let arxiv: String?
        let line: UInt

        init(input: String, download: String, arxiv: String? = nil, line: UInt = #line) {
            self.input = input
            self.download = download
            self.arxiv = arxiv
            self.line = line
        }
    }

    private func check(_ cases: [Case], file: StaticString = #filePath) {
        for c in cases {
            guard let parsed = RemoteDocumentURL.parse(c.input) else {
                XCTFail("parse returned nil for \(c.input)", file: file, line: c.line)
                continue
            }
            XCTAssertEqual(parsed.downloadURL.absoluteString, c.download,
                           "downloadURL for \(c.input)", file: file, line: c.line)
            XCTAssertEqual(parsed.arxivID, c.arxiv, "arxivID for \(c.input)", file: file, line: c.line)
        }
    }

    // MARK: arXiv spellings (must keep working)

    func testArxivSpellingsAllRouteToCanonicalPDF() {
        check([
            Case(input: "2510.26692", download: "https://arxiv.org/pdf/2510.26692", arxiv: "2510.26692"),
            Case(input: "  2510.26692v2\n", download: "https://arxiv.org/pdf/2510.26692v2", arxiv: "2510.26692v2"),
            Case(input: "arXiv:2510.26692", download: "https://arxiv.org/pdf/2510.26692", arxiv: "2510.26692"),
            Case(input: "arxiv: 2510.26692v2", download: "https://arxiv.org/pdf/2510.26692v2", arxiv: "2510.26692v2"),
            Case(input: "cs.CL/0301012", download: "https://arxiv.org/pdf/cs.CL/0301012", arxiv: "cs.CL/0301012"),
            Case(input: "https://arxiv.org/abs/2510.26692", download: "https://arxiv.org/pdf/2510.26692", arxiv: "2510.26692"),
            Case(input: "http://arxiv.org/abs/2510.26692v3", download: "https://arxiv.org/pdf/2510.26692v3", arxiv: "2510.26692v3"),
            Case(input: "https://arxiv.org/pdf/2510.26692.pdf", download: "https://arxiv.org/pdf/2510.26692", arxiv: "2510.26692"),
            Case(input: "https://arxiv.org/pdf/2510.26692v2", download: "https://arxiv.org/pdf/2510.26692v2", arxiv: "2510.26692v2"),
            Case(input: "https://arxiv.org/html/2510.26692v1", download: "https://arxiv.org/pdf/2510.26692v1", arxiv: "2510.26692v1"),
            Case(input: "https://export.arxiv.org/abs/2510.26692", download: "https://arxiv.org/pdf/2510.26692", arxiv: "2510.26692"),
            Case(input: "https://arxiv.org/abs/cs.CL/0301012", download: "https://arxiv.org/pdf/cs.CL/0301012", arxiv: "cs.CL/0301012"),
        ])
    }

    func testArxivPagesThatAreNotAPaperAreRejected() {
        XCTAssertNil(RemoteDocumentURL.parse("https://arxiv.org/"))
        XCTAssertNil(RemoteDocumentURL.parse("https://arxiv.org/list/cs.CL/recent"))
        XCTAssertNil(RemoteDocumentURL.parse("https://arxiv.org/abs/not-an-id"))
    }

    func testUnrecognizableInputIsRejected() {
        for input in ["", "   ", "not a url", "ftp://example.com/a.pdf", "javascript:alert(1)",
                      "file:///Users/x/a.pdf", "https://", "12345"] {
            XCTAssertNil(RemoteDocumentURL.parse(input), input)
        }
    }

    // MARK: mirrors that carry an arXiv id

    func testHuggingFaceAndAlphaxivRouteToArxiv() {
        check([
            Case(input: "https://huggingface.co/papers/2510.26692", download: "https://arxiv.org/pdf/2510.26692", arxiv: "2510.26692"),
            Case(input: "https://alphaxiv.org/abs/2510.26692", download: "https://arxiv.org/pdf/2510.26692", arxiv: "2510.26692"),
            Case(input: "https://www.alphaxiv.org/abs/2510.26692v2", download: "https://arxiv.org/pdf/2510.26692v2", arxiv: "2510.26692v2"),
            Case(input: "https://www.alphaxiv.org/overview/2510.26692", download: "https://arxiv.org/pdf/2510.26692", arxiv: "2510.26692"),
        ])
    }

    func testMirrorPagesWithoutAnIdStayPlainWebPages() {
        check([
            Case(input: "https://huggingface.co/papers", download: "https://huggingface.co/papers", arxiv: nil),
            Case(input: "https://huggingface.co/papers/trending", download: "https://huggingface.co/papers/trending", arxiv: nil),
            Case(input: "https://huggingface.co/datasets/2510.26692", download: "https://huggingface.co/datasets/2510.26692", arxiv: nil),
        ])
    }

    // MARK: web wrappers → direct PDF (each verified: rewritten URL answers application/pdf)

    func testGitHubBlobAndRawNormalizeToRawHost() {
        check([
            Case(input: "https://github.com/owner/repo/blob/main/papers/a.pdf",
                 download: "https://raw.githubusercontent.com/owner/repo/main/papers/a.pdf"),
            Case(input: "https://github.com/owner/repo/raw/main/a.pdf",
                 download: "https://raw.githubusercontent.com/owner/repo/main/a.pdf"),
            Case(input: "https://raw.githubusercontent.com/owner/repo/main/a.pdf",
                 download: "https://raw.githubusercontent.com/owner/repo/main/a.pdf"),
            Case(input: "https://github.com/owner/repo", download: "https://github.com/owner/repo"),
        ])
    }

    func testACLAnthologyPaperPageBecomesPDF() {
        check([
            Case(input: "https://aclanthology.org/2020.acl-main.747/", download: "https://aclanthology.org/2020.acl-main.747.pdf"),
            Case(input: "https://aclanthology.org/2023.findings-emnlp.12", download: "https://aclanthology.org/2023.findings-emnlp.12.pdf"),
            Case(input: "https://aclanthology.org/P19-1001/", download: "https://aclanthology.org/P19-1001.pdf"),
            Case(input: "http://aclanthology.org/P19-1001", download: "https://aclanthology.org/P19-1001.pdf"),
            // Already direct, and volume pages, are left alone.
            Case(input: "https://aclanthology.org/2020.acl-main.747.pdf", download: "https://aclanthology.org/2020.acl-main.747.pdf"),
            Case(input: "https://aclanthology.org/2020.acl-main/", download: "https://aclanthology.org/2020.acl-main/"),
        ])
    }

    func testPMLRLayoutDependsOnVolume() {
        check([
            // v54+ nests: /vN/<name>/<name>.pdf
            Case(input: "https://proceedings.mlr.press/v139/radford21a.html",
                 download: "https://proceedings.mlr.press/v139/radford21a/radford21a.pdf"),
            Case(input: "http://proceedings.mlr.press/v54/mcmahan17a.html",
                 download: "https://proceedings.mlr.press/v54/mcmahan17a/mcmahan17a.pdf"),
            // v53 and earlier are flat: /vN/<name>.pdf
            Case(input: "https://proceedings.mlr.press/v53/fan16.html",
                 download: "https://proceedings.mlr.press/v53/fan16.pdf"),
            Case(input: "https://proceedings.mlr.press/v37/ioffe15.html",
                 download: "https://proceedings.mlr.press/v37/ioffe15.pdf"),
            // PMLR's own pages link plain-http PDFs — upgraded so both spellings dedup.
            Case(input: "http://proceedings.mlr.press/v37/ioffe15.pdf",
                 download: "https://proceedings.mlr.press/v37/ioffe15.pdf"),
            // Volume index page is not a paper.
            Case(input: "https://proceedings.mlr.press/v139/", download: "https://proceedings.mlr.press/v139/"),
        ])
    }

    func testCVFHtmlPageBecomesPapersPDF() {
        check([
            Case(input: "https://openaccess.thecvf.com/content/ICCV2023/html/Kirillov_Segment_Anything_ICCV_2023_paper.html",
                 download: "https://openaccess.thecvf.com/content/ICCV2023/papers/Kirillov_Segment_Anything_ICCV_2023_paper.pdf"),
            Case(input: "https://openaccess.thecvf.com/content_cvpr_2016/html/He_Deep_Residual_Learning_CVPR_2016_paper.html",
                 download: "https://openaccess.thecvf.com/content_cvpr_2016/papers/He_Deep_Residual_Learning_CVPR_2016_paper.pdf"),
            Case(input: "https://openaccess.thecvf.com/content/ICCV2023/papers/Kirillov_Segment_Anything_ICCV_2023_paper.pdf",
                 download: "https://openaccess.thecvf.com/content/ICCV2023/papers/Kirillov_Segment_Anything_ICCV_2023_paper.pdf"),
        ])
    }

    func testNeurIPSAbstractPageBecomesPaperPDF() {
        check([
            Case(input: "https://papers.nips.cc/paper_files/paper/2017/hash/3f5ee243547dee91fbd053c1c4a845aa-Abstract.html",
                 download: "https://papers.nips.cc/paper_files/paper/2017/file/3f5ee243547dee91fbd053c1c4a845aa-Paper.pdf"),
            Case(input: "https://papers.nips.cc/paper_files/paper/2022/hash/002262941c9edfd472a79298b2ac5e17-Abstract-Conference.html",
                 download: "https://papers.nips.cc/paper_files/paper/2022/file/002262941c9edfd472a79298b2ac5e17-Paper-Conference.pdf"),
            Case(input: "https://proceedings.neurips.cc/paper_files/paper/2022/hash/002262941c9edfd472a79298b2ac5e17-Abstract-Conference.html",
                 download: "https://proceedings.neurips.cc/paper_files/paper/2022/file/002262941c9edfd472a79298b2ac5e17-Paper-Conference.pdf"),
            Case(input: "https://papers.nips.cc/paper_files/paper/2024/hash/013cf29a9e68e4411d0593040a8a1eb3-Abstract-Datasets_and_Benchmarks_Track.html",
                 download: "https://papers.nips.cc/paper_files/paper/2024/file/013cf29a9e68e4411d0593040a8a1eb3-Paper-Datasets_and_Benchmarks_Track.pdf"),
            // Already direct / listing pages are left alone.
            Case(input: "https://papers.nips.cc/paper_files/paper/2017/file/3f5ee243547dee91fbd053c1c4a845aa-Paper.pdf",
                 download: "https://papers.nips.cc/paper_files/paper/2017/file/3f5ee243547dee91fbd053c1c4a845aa-Paper.pdf"),
            Case(input: "https://papers.nips.cc/paper_files/paper/2022", download: "https://papers.nips.cc/paper_files/paper/2022"),
        ])
    }

    func testPlainDirectLinksPassThrough() {
        check([
            Case(input: "https://example.com/papers/a.pdf", download: "https://example.com/papers/a.pdf"),
            Case(input: "http://example.com/a.pdf?dl=1", download: "http://example.com/a.pdf?dl=1"),
        ])
    }

    // MARK: dedup tokens

    private func token(_ input: String, line: UInt = #line) -> String {
        guard let parsed = RemoteDocumentURL.parse(input) else {
            XCTFail("parse returned nil for \(input)", line: line)
            return ""
        }
        return parsed.dedupToken
    }

    private func assertSameToken(_ inputs: [String], line: UInt = #line) {
        let tokens = Set(inputs.map { token($0, line: line) })
        XCTAssertEqual(tokens.count, 1, "spellings should share one token: \(inputs) → \(tokens)", line: line)
    }

    func testArxivSpellingsShareOneToken() {
        assertSameToken([
            "2510.26692", "arXiv:2510.26692", "https://arxiv.org/abs/2510.26692",
            "https://arxiv.org/pdf/2510.26692.pdf", "https://arxiv.org/html/2510.26692",
            "https://huggingface.co/papers/2510.26692", "https://www.alphaxiv.org/abs/2510.26692",
            "https://alphaxiv.org/overview/2510.26692",
        ])
        XCTAssertEqual(token("2510.26692"), "2510.26692")
        XCTAssertEqual(token("cs.CL/0301012"), "cs.CL-0301012")
        // A different version is a different file.
        XCTAssertNotEqual(token("2510.26692v2"), token("2510.26692"))
    }

    func testWrapperAndDirectSpellingsShareOneToken() {
        assertSameToken([
            "https://aclanthology.org/2020.acl-main.747/",
            "https://aclanthology.org/2020.acl-main.747.pdf",
            "http://aclanthology.org/2020.acl-main.747.pdf#page=3",
        ])
        assertSameToken([
            "https://proceedings.mlr.press/v139/radford21a.html",
            "http://proceedings.mlr.press/v139/radford21a/radford21a.pdf",
        ])
        assertSameToken([
            "https://proceedings.mlr.press/v37/ioffe15.html",
            "http://proceedings.mlr.press/v37/ioffe15.pdf",
        ])
        assertSameToken([
            "https://openaccess.thecvf.com/content/ICCV2023/html/Kirillov_Segment_Anything_ICCV_2023_paper.html",
            "https://openaccess.thecvf.com/content/ICCV2023/papers/Kirillov_Segment_Anything_ICCV_2023_paper.pdf",
        ])
        assertSameToken([
            "https://papers.nips.cc/paper_files/paper/2017/hash/3f5ee243547dee91fbd053c1c4a845aa-Abstract.html",
            "https://papers.nips.cc/paper_files/paper/2017/file/3f5ee243547dee91fbd053c1c4a845aa-Paper.pdf",
        ])
        assertSameToken([
            "https://github.com/owner/repo/blob/main/a.pdf",
            "https://github.com/owner/repo/raw/main/a.pdf",
            "https://raw.githubusercontent.com/owner/repo/main/a.pdf",
        ])
    }

    func testWebTokenIgnoresFragmentAndIsTenLowercaseHex() {
        assertSameToken(["https://example.com/a.pdf", "https://example.com/a.pdf#page=4"])
        XCTAssertNotEqual(token("https://example.com/a.pdf"), token("https://example.com/b.pdf"))
        let t = token("https://example.com/a.pdf")
        XCTAssertEqual(t.count, 10)
        XCTAssertTrue(t.allSatisfy { "0123456789abcdef".contains($0) })
    }

    func testSubdirectoryAndFallbackName() {
        XCTAssertEqual(RemoteDocumentURL.parse("2510.26692")?.subdirectory, "arxiv")
        XCTAssertEqual(RemoteDocumentURL.parse("https://example.com/a.pdf")?.subdirectory, "web")
        XCTAssertEqual(RemoteDocumentURL.parse("cs.CL/0301012")?.fallbackName, "cs.CL-0301012")
        XCTAssertEqual(RemoteDocumentURL.parse("https://example.com/papers/My%20Paper.pdf")?.fallbackName, "My Paper")
    }

    // MARK: redirect retry (stretch: t.co → arxiv.org/abs)

    func testRedirectRetryRoutesShortLinkThatLandedOnPaperPage() throws {
        let requested = try XCTUnwrap(RemoteDocumentURL.parse("https://t.co/abc123"))

        XCTAssertEqual(
            RemoteDocumentURL.redirectRetry(requested: requested,
                                            finalURL: URL(string: "https://arxiv.org/abs/2510.26692")!),
            .arxiv(id: "2510.26692"))
        XCTAssertEqual(
            RemoteDocumentURL.redirectRetry(requested: requested,
                                            finalURL: URL(string: "https://huggingface.co/papers/2510.26692")!),
            .arxiv(id: "2510.26692"))
        XCTAssertEqual(
            RemoteDocumentURL.redirectRetry(
                requested: requested,
                finalURL: URL(string: "https://openaccess.thecvf.com/content/ICCV2023/html/K_Segment_ICCV_2023_paper.html")!)?
                .downloadURL.absoluteString,
            "https://openaccess.thecvf.com/content/ICCV2023/papers/K_Segment_ICCV_2023_paper.pdf")
    }

    func testRedirectRetryIgnoresPagesThatTeachUsNothing() throws {
        let requested = try XCTUnwrap(RemoteDocumentURL.parse("https://t.co/abc123"))
        // A random web page normalizes to itself — retrying would just download the same HTML.
        XCTAssertNil(RemoteDocumentURL.redirectRetry(
            requested: requested, finalURL: URL(string: "https://example.com/blog/post")!))
        // No redirect happened: same URL back.
        XCTAssertNil(RemoteDocumentURL.redirectRetry(
            requested: requested, finalURL: URL(string: "https://t.co/abc123")!))
        // Retrying the identical normalized target would loop.
        let arxiv = try XCTUnwrap(RemoteDocumentURL.parse("2510.26692"))
        XCTAssertNil(RemoteDocumentURL.redirectRetry(
            requested: arxiv, finalURL: URL(string: "https://arxiv.org/abs/2510.26692")!))
    }
}
