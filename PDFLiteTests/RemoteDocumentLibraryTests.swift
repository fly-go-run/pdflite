import XCTest

final class RemoteDocumentLibraryTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdflite-library-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func tempPDF() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdflite-download-\(UUID().uuidString).pdf")
        try Data("%PDF-1.4\n%%EOF".utf8).write(to: url)
        return url
    }

    // MARK: display names

    func testDisplayNameStripsNoiseTokensButKeepsCitationIds() {
        let cases: [(String, String)] = [
            // 10-hex web token is pure noise.
            ("Some Paper [a439842ff6].pdf", "Some Paper"),
            ("He_Deep_Residual_Learning_CVPR_2016_paper [a439842ff6].pdf", "He_Deep_Residual_Learning_CVPR_2016_paper"),
            ("Paper [1] [a439842ff6].pdf", "Paper [1]"),
            // Token that merely repeats the whole name.
            ("2504.09014 [2504.09014].pdf", "2504.09014"),
            ("cs-CL-0301012 [cs-CL-0301012].pdf", "cs-CL-0301012"),
            // arXiv id next to a real title is a useful citation handle — keep.
            ("Kimi Linear An Expressive Attention Architecture [2510.26692].pdf",
             "Kimi Linear An Expressive Attention Architecture [2510.26692]"),
            ("Some Title [2603.15031v2].pdf", "Some Title [2603.15031v2]"),
            // Near-misses are left alone.
            ("Paper [a439842ff].pdf", "Paper [a439842ff]"),       // 9 hex
            ("Paper [a439842ff6b].pdf", "Paper [a439842ff6b]"),   // 11 hex
            ("Paper [abc].pdf", "Paper [abc]"),
            ("Paper [zzzzzzzzzz].pdf", "Paper [zzzzzzzzzz]"),     // not hex
            // Plain names: only the .pdf extension goes; dots inside the name stay.
            ("plain.pdf", "plain"),
            ("2504.09014.pdf", "2504.09014"),
            ("Report.PDF", "Report"),
            // Works without an extension too.
            ("Some Paper [a439842ff6]", "Some Paper"),
        ]
        for (input, expected) in cases {
            XCTAssertEqual(RemoteDocumentLibrary.displayName(forFileName: input), expected, input)
        }
    }

    func testRecentFileDisplayNameUsesTheHelper() {
        let recent = RecentFile(url: URL(fileURLWithPath: "/tmp/library/web/Some Paper [a439842ff6].pdf"))
        XCTAssertEqual(recent.displayName, "Some Paper")
        let arxiv = RecentFile(url: URL(fileURLWithPath: "/tmp/library/arxiv/2504.09014 [2504.09014].pdf"))
        XCTAssertEqual(arxiv.displayName, "2504.09014")
    }

    // MARK: deep-link titles (untrusted page text)

    func testAcceptableTitlesAreSanitizedNotRejected() {
        let cases: [(String, String)] = [
            ("Attention is All you Need", "Attention is All you Need"),
            // arXiv abs tab title: leading "[id] " is dropped, ":" is filesystem-hostile.
            ("[2510.26692] Kimi Linear: An Expressive, Efficient Attention Architecture",
             "Kimi Linear An Expressive, Efficient Attention Architecture"),
            ("  Spaced   out \n title  ", "Spaced out title"),
            ("Line one\nLine two", "Line one Line two"),
            ("Title\u{0}With\u{202E}Hidden", "TitleWithHidden"),
            // Path tricks collapse into spaces; never a separator, never a leading dot.
            ("../../etc/passwd", "etc passwd"),
            (".hidden paper title", "hidden paper title"),
            ("BERT", "BERT"),
            // Only an arXiv-id bracket is a citation prefix; other brackets belong to the title.
            ("[arXiv:2510.26692v2] Kimi Linear", "Kimi Linear"),
            ("[cs.CL/0301012] Old Style Title", "Old Style Title"),
            ("[Survey] A Big Paper", "[Survey] A Big Paper"),
        ]
        for (input, expected) in cases {
            XCTAssertEqual(RemoteDocumentLibrary.sanitizedDeepLinkTitle(input), expected, input)
        }
    }

    func testUnusableTitlesAreRejected() {
        let rejected: [String?] = [
            nil, "", "   ", "\n\t",
            "[2510.26692]",               // only the id prefix
            "paper.pdf", "2510.26692v2.pdf", "main.tex", "draft.docx",   // filenames
            "2510.26692", "2510.26692v2", "arXiv:2510.26692", "cs.CL/0301012",  // ids
            "a439842ff6", "A439842FF6",   // web tokens
            "https://arxiv.org/abs/2510.26692", "www.example.com/paper",  // URLs
            "ab", "T5",                   // too short
            "1234 5", "...",              // no letters
        ]
        for input in rejected {
            XCTAssertNil(RemoteDocumentLibrary.sanitizedDeepLinkTitle(input), String(describing: input))
        }
    }

    func testTitleNeverEscapesTheLibraryDirectory() throws {
        for evil in ["../../../Library/evil", "/etc/passwd", "..\\..\\x title", "a/b/c/d title"] {
            let title = try XCTUnwrap(RemoteDocumentLibrary.sanitizedDeepLinkTitle(evil), evil)
            XCTAssertFalse(title.contains("/"), title)
            XCTAssertFalse(title.contains("\\"), title)
            XCTAssertFalse(title.hasPrefix("."), title)

            let source = try XCTUnwrap(RemoteDocumentURL.parse("https://example.com/a.pdf"))
            let landed = try RemoteDocumentLibrary.land(tempFile: tempPDF(), source: source,
                                                        title: title, in: root)
            XCTAssertEqual(landed.deletingLastPathComponent().standardizedFileURL.path,
                           root.appendingPathComponent("web").standardizedFileURL.path, evil)
        }
    }

    func testLongCJKTitlesFitTheFilesystemNameLimit() throws {
        let long = String(repeating: "深度学习论文", count: 40)   // 240 chars, 720 UTF-8 bytes
        let title = try XCTUnwrap(RemoteDocumentLibrary.sanitizedDeepLinkTitle(long))
        XCTAssertLessThanOrEqual(title.utf8.count, 180)

        // The real proof: landing it must not trip the 255-byte APFS limit.
        let source = try XCTUnwrap(RemoteDocumentURL.parse("2510.26692v12"))
        let landed = try RemoteDocumentLibrary.land(tempFile: tempPDF(), source: source,
                                                    title: title, in: root)
        XCTAssertTrue(FileManager.default.fileExists(atPath: landed.path))
        XCTAssertLessThanOrEqual(landed.lastPathComponent.utf8.count, 255)
    }

    func testSanitizedBaseNameKeepsExistingBehavior() {
        XCTAssertEqual(RemoteDocumentLibrary.sanitizedBaseName("A: B/C  D"), "A B C D")
        XCTAssertEqual(RemoteDocumentLibrary.sanitizedBaseName(""), "document")
        XCTAssertEqual(RemoteDocumentLibrary.sanitizedBaseName("  ///  "), "document")
        XCTAssertEqual(RemoteDocumentLibrary.sanitizedBaseName(String(repeating: "a", count: 300)).count, 100)
    }

    // MARK: landing + dedup lookup

    func testLandedFileIsFoundByTokenForEverySpelling() throws {
        let source = try XCTUnwrap(RemoteDocumentURL.parse("https://arxiv.org/abs/2510.26692"))
        let landed = try RemoteDocumentLibrary.land(tempFile: tempPDF(), source: source,
                                                    title: "Kimi Linear", in: root)
        XCTAssertEqual(landed.lastPathComponent, "Kimi Linear [2510.26692].pdf")
        XCTAssertEqual(landed.deletingLastPathComponent().lastPathComponent, "arxiv")

        for spelling in ["2510.26692", "arXiv:2510.26692", "https://arxiv.org/pdf/2510.26692.pdf",
                         "https://huggingface.co/papers/2510.26692",
                         "https://alphaxiv.org/abs/2510.26692"] {
            let token = try XCTUnwrap(RemoteDocumentURL.parse(spelling)).dedupToken
            XCTAssertEqual(RemoteDocumentLibrary.existingFile(token: token, in: root)?.lastPathComponent,
                           "Kimi Linear [2510.26692].pdf", spelling)
        }
        let other = try XCTUnwrap(RemoteDocumentURL.parse("2510.26693")).dedupToken
        XCTAssertNil(RemoteDocumentLibrary.existingFile(token: other, in: root))
    }

    func testWebWrapperAndDirectLinkDedupToTheSameLandedFile() throws {
        let wrapper = try XCTUnwrap(RemoteDocumentURL.parse("https://aclanthology.org/2020.acl-main.747/"))
        let landed = try RemoteDocumentLibrary.land(tempFile: tempPDF(), source: wrapper,
                                                    title: "XLM-R", in: root)
        XCTAssertEqual(landed.deletingLastPathComponent().lastPathComponent, "web")

        let direct = try XCTUnwrap(RemoteDocumentURL.parse("https://aclanthology.org/2020.acl-main.747.pdf"))
        XCTAssertEqual(RemoteDocumentLibrary.existingFile(token: direct.dedupToken, in: root), landed)
    }

    func testExistingFileOnEmptyOrMissingLibraryIsNil() {
        XCTAssertNil(RemoteDocumentLibrary.existingFile(token: "2510.26692", in: root))
        XCTAssertNil(RemoteDocumentLibrary.existingFile(
            token: "2510.26692", in: root.appendingPathComponent("does-not-exist")))
    }
}
