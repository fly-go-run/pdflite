import XCTest

/// One row of a TextCleaner table. `name` is only for failure messages; keep it unique per table.
struct CleanCase {
    let name: String
    let input: String
    let expected: String

    init(_ name: String, _ input: String, _ expected: String) {
        self.name = name
        self.input = input
        self.expected = expected
    }
}

extension XCTestCase {
    /// Runs every row and additionally asserts idempotence: the cleaned text feeds the translation
    /// cache key, so cleaning an already-clean string must be a no-op or the same passage could
    /// hash differently depending on how many times it went through the pipeline.
    func assertCleaning(_ cases: [CleanCase], file: StaticString = #filePath, line: UInt = #line) {
        for row in cases {
            let cleaned = TextCleaner.clean(row.input)
            XCTAssertEqual(cleaned, row.expected, "[\(row.name)] input: \(row.input.debugDescription)",
                           file: file, line: line)
            XCTAssertEqual(TextCleaner.clean(cleaned), cleaned,
                           "[\(row.name)] not idempotent, first pass: \(cleaned.debugDescription)",
                           file: file, line: line)
        }
    }
}

/// Behaviour that was already correct before the hyphenation/ligature rework: line-ending
/// normalisation, paragraph handling, CJK joins, and text that must pass through untouched.
/// These rows were run against the unmodified cleaner first, so a failure here is a regression.
final class TextCleanerTests: XCTestCase {
    func testPassThroughUnchanged() {
        assertCleaning([
            CleanCase("plain sentence", "Attention is all you need.", "Attention is all you need."),
            CleanCase("inline compound", "a state-of-the-art model", "a state-of-the-art model"),
            CleanCase("inner spaces kept", "a  b", "a  b"),
            CleanCase("hyphen then space", "long- term", "long- term"),
            CleanCase("Chinese sentence", "这是一个测试句子。", "这是一个测试句子。"),
        ])
    }

    func testEnglishHyphenatedBreakIsMerged() {
        assertCleaning([
            CleanCase("plain", "infor-\nmation", "information"),
            CleanCase("in sentence", "The infor-\nmation is stored.", "The information is stored."),
            CleanCase("leading indent on next line", "multi-\n   thread", "multithread"),
            CleanCase("CRLF", "infor-\r\nmation", "information"),
            CleanCase("lone CR", "infor-\rmation", "information"),
        ])
    }

    func testEnglishNewlinesBecomeSpaces() {
        assertCleaning([
            CleanCase("two lines", "line one\nline two", "line one line two"),
            CleanCase("three lines", "a\nb\nc", "a b c"),
            CleanCase("trailing period", "It ends.\nAnother starts.", "It ends. Another starts."),
            CleanCase("compound at line start", "well-known\nresult", "well-known result"),
            CleanCase("spaced dash at line end", "foo -\nbar", "foo - bar"),
        ])
    }

    func testLineEndingsAreNormalised() {
        assertCleaning([
            CleanCase("CRLF", "a\r\nb", "a b"),
            CleanCase("CR", "a\rb", "a b"),
            CleanCase("mixed", "a\r\nb\rc\nd", "a b c d"),
            CleanCase("CRLF paragraph", "one\r\n\r\ntwo", "one\n\ntwo"),
            CleanCase("CR paragraph", "one\r\rtwo", "one\n\ntwo"),
        ])
    }

    func testParagraphBreaksArePreserved() {
        assertCleaning([
            CleanCase("two paragraphs", "para one\n\npara two", "para one\n\npara two"),
            CleanCase("wrapped paragraphs", "one\nstill one\n\ntwo\nstill two", "one still one\n\ntwo still two"),
            CleanCase("many blank lines", "one\n\n\n\ntwo", "one\n\ntwo"),
            CleanCase("whitespace-only blank line", "one\n \t \ntwo", "one\n\ntwo"),
            CleanCase("three paragraphs", "a\n\nb\n\nc", "a\n\nb\n\nc"),
        ])
    }

    func testCJKParagraphsDropInParagraphNewlines() {
        assertCleaning([
            CleanCase("CJK to CJK", "这是一个\n测试句子", "这是一个测试句子"),
            CleanCase("CJK to fullwidth punctuation", "你好\n，世界", "你好，世界"),
            CleanCase("fullwidth punctuation to CJK", "你好，\n世界", "你好，世界"),
            CleanCase("paragraphs kept", "第一段\n继续\n\n第二段", "第一段继续\n\n第二段"),
            CleanCase("kana", "これは\nテストです", "これはテストです"),
            CleanCase("CRLF CJK", "这是\r\n测试", "这是测试"),
        ])
    }

    func testCJKLatinBoundariesKeepASpace() {
        assertCleaning([
            CleanCase("Latin to CJK", "the model\n模型 training\nfoo", "the model 模型 training foo"),
            CleanCase("CJK to Latin", "模型\nTransformer", "模型 Transformer"),
            CleanCase("mixed line", "使用 Transformer\n模型", "使用 Transformer 模型"),
            CleanCase("inline mix untouched", "使用BERT模型进行分类", "使用BERT模型进行分类"),
        ])
    }

    func testCitationsAndReferencesAreUntouched() {
        assertCleaning([
            CleanCase("numeric", "as shown in [12] and [1, 2]", "as shown in [12] and [1, 2]"),
            CleanCase("author-year", "(Smith et al., 2020)", "(Smith et al., 2020)"),
            CleanCase("range", "see [3-5]", "see [3-5]"),
            CleanCase("wrapped author-year", "Smith et al.\n(2020) showed", "Smith et al. (2020) showed"),
            CleanCase("abbreviations", "e.g. i.i.d. and et al.", "e.g. i.i.d. and et al."),
        ])
    }

    func testFormulasAreUntouched() {
        assertCleaning([
            CleanCase("subscript/superscript", "x_i = W^T h", "x_i = W^T h"),
            CleanCase("greater or equal", "p ≥ 0.5", "p ≥ 0.5"),
            CleanCase("wrapped formula", "p(y|x)\n≥ 0.5", "p(y|x) ≥ 0.5"),
            CleanCase("unicode superscripts", "x² + y² = z²", "x² + y² = z²"),
            CleanCase("fractions and math symbols", "½ ≤ α ∑ ∈ ℝ", "½ ≤ α ∑ ∈ ℝ"),
            CleanCase("plain minus", "a - b = c", "a - b = c"),
        ])
    }

    func testSurroundingWhitespaceIsTrimmed() {
        assertCleaning([
            CleanCase("spaces and newline", "  hi  \n", "hi"),
            CleanCase("leading blank lines", "\n\nhi", "hi"),
            CleanCase("trailing blank lines", "hi\n\n\n", "hi"),
            CleanCase("tabs", "\t hi \t", "hi"),
            CleanCase("CRLF edges", "\r\nhi\r\n", "hi"),
        ])
    }

    func testEmptyAndWhitespaceOnlyInput() {
        assertCleaning([
            CleanCase("empty", "", ""),
            CleanCase("spaces", "   ", ""),
            CleanCase("newlines", "\n\n\n", ""),
            CleanCase("mixed whitespace", "   \n\t\n ", ""),
            CleanCase("CRLF only", "\r\n\r\n", ""),
        ])
    }

    func testLoneSoftHyphenInsideAWordIsRemoved() {
        assertCleaning([
            CleanCase("mid-word", "co\u{00AD}operate", "cooperate"),
            CleanCase("several", "in\u{00AD}ter\u{00AD}na\u{00AD}tion\u{00AD}al", "international"),
            CleanCase("at end of text", "trail\u{00AD}", "trail"),
        ])
    }
}
