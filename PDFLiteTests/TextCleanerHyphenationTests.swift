import XCTest

/// Line-end hyphens, soft hyphens, PDF ligatures and input-size behaviour. Companion to
/// `TextCleanerTests` (which pins everything that was already right).
///
/// Rule under test: a line-end hyphen is a soft break (hyphen dropped, halves joined) only when a
/// lowercase letter ends the first half and a lowercase letter starts the next line. Any other
/// hyphen is a real one and survives, with the lines joined without a space.
final class TextCleanerHyphenationTests: XCTestCase {
    // MARK: Real compound hyphens broken across lines (previously lost)

    func testCompoundHyphenSurvivesWhenNextLineIsNotLowercase() {
        assertCleaning([
            CleanCase("digit after", "GPT-\n4", "GPT-4"),
            CleanCase("digit after (COVID)", "COVID-\n19", "COVID-19"),
            CleanCase("digit after, indented", "GPT-\n   4", "GPT-4"),
            CleanCase("digit after, CRLF", "GPT-\r\n4", "GPT-4"),
            CleanCase("uppercase after", "Well-\nKnown", "Well-Known"),
            CleanCase("uppercase after (Trans)", "Trans-\nFormer", "Trans-Former"),
            CleanCase("in a sentence", "the COVID-\n19 pandemic and GPT-\n4 models", "the COVID-19 pandemic and GPT-4 models"),
            CleanCase("digits both sides", "pages 12-\n34", "pages 12-34"),
            CleanCase("digit before, word after", "a 10-\nfold gain", "a 10-fold gain"),
            CleanCase("symbol after", "foo-\n$x$", "foo-$x$"),
        ])
    }

    func testAcronymBeforeHyphenIsARealCompound() {
        assertCleaning([
            CleanCase("acronym + lowercase", "GPT-\nbased", "GPT-based"),
            CleanCase("acronym + lowercase 2", "an LSTM-\nbased model", "an LSTM-based model"),
            CleanCase("single capital", "X-\nray", "X-ray"),
        ])
    }

    func testCompoundHyphenBeforeCJK() {
        assertCleaning([
            CleanCase("Latin before, CJK after", "Transformer-\n的模型", "Transformer-的模型"),
            // A hyphen after CJK text is not a word hyphen: the old behaviour (newline -> space) stays.
            CleanCase("CJK before hyphen", "深度学习-\n模型", "深度学习- 模型"),
        ])
    }

    // MARK: Ordinary hyphenation still merges

    func testLowercaseContinuationIsMerged() {
        assertCleaning([
            CleanCase("plain", "infor-\nmation", "information"),
            CleanCase("with indent", "infor-\n  mation", "information"),
            CleanCase("in sentence", "a long infor-\nmation retrieval task", "a long information retrieval task"),
            CleanCase("chain", "un-\nder-\nstand-\ning", "understanding"),
            CleanCase("accented", "Ver-\nänderung", "Veränderung"),
            CleanCase("accented before", "Bü-\ncher", "Bücher"),
            CleanCase("capitalised first half", "Infor-\nmation", "Information"),
        ])
    }

    func testInlineCompoundsAreNotTouched() {
        assertCleaning([
            CleanCase("state-of-the-art", "state-of-the-art", "state-of-the-art"),
            CleanCase("inline then wrap", "state-of-the-art\nmodels", "state-of-the-art models"),
            CleanCase("hyphen at line start", "a\n-b", "a -b"),
        ])
    }

    // MARK: Paragraph breaks are never merged across

    func testHyphenNeverMergesAcrossBlankLine() {
        assertCleaning([
            CleanCase("uppercase after", "foo-\n\nBar", "foo-\n\nBar"),
            CleanCase("lowercase after", "foo-\n\nbar", "foo-\n\nbar"),
            CleanCase("whitespace-only line", "foo-\n \nbar", "foo-\n\nbar"),
            CleanCase("CRLF blank line", "foo-\r\n\r\nbar", "foo-\n\nbar"),
            CleanCase("several blank lines", "foo-\n\n\n\nbar", "foo-\n\nbar"),
            CleanCase("soft hyphen", "foo\u{00AD}\n\nbar", "foo\n\nbar"),
        ])
    }

    func testTrailingHyphenAtEndOfInput() {
        assertCleaning([
            CleanCase("no newline", "foo-", "foo-"),
            CleanCase("newline", "foo-\n", "foo-"),
            CleanCase("blank lines", "foo-\n\n", "foo-"),
            CleanCase("trailing spaces after newline", "foo-\n   ", "foo-"),
        ])
    }

    // MARK: Soft hyphen (U+00AD)

    func testSoftHyphenBeforeNewlineJoinsWithoutHyphenOrSpace() {
        assertCleaning([
            CleanCase("plain", "multi\u{00AD}\nthread", "multithread"),
            CleanCase("CRLF", "multi\u{00AD}\r\nthread", "multithread"),
            CleanCase("CR", "multi\u{00AD}\rthread", "multithread"),
            CleanCase("indent", "multi\u{00AD}\n  thread", "multithread"),
            CleanCase("uppercase after", "Trans\u{00AD}\nFormer", "TransFormer"),
            CleanCase("in sentence", "a multi\u{00AD}\nthreaded run", "a multithreaded run"),
            CleanCase("line-end and mid-word together", "wor\u{00AD}\nd and wor\u{00AD}ds", "word and words"),
        ])
    }

    // MARK: Unicode hyphens (U+2010, U+2011)

    func testUnicodeHyphensAtLineEndBehaveLikeAsciiHyphen() {
        assertCleaning([
            CleanCase("U+2010 soft break", "multi\u{2010}\nthread", "multithread"),
            CleanCase("U+2011 soft break", "multi\u{2011}\nthread", "multithread"),
            CleanCase("U+2010 real compound", "GPT\u{2010}\n4", "GPT\u{2010}4"),
            CleanCase("U+2011 real compound", "COVID\u{2011}\n19", "COVID\u{2011}19"),
            CleanCase("U+2010 blank line", "foo\u{2010}\n\nbar", "foo\u{2010}\n\nbar"),
            CleanCase("U+2010 mid-line untouched", "a\u{2010}b and c\u{2011}d", "a\u{2010}b and c\u{2011}d"),
        ])
    }

    func testNonHyphenDashesAreNotBreaks() {
        assertCleaning([
            CleanCase("en dash", "12\u{2013}\n34", "12\u{2013} 34"),
            CleanCase("em dash", "wait\u{2014}\nno", "wait\u{2014} no"),
            CleanCase("minus sign", "a \u{2212}\nb", "a \u{2212} b"),
            CleanCase("double hyphen", "a--\nb", "a-- b"),
        ])
    }

    // MARK: Ligatures

    func testLigaturesAreExpanded() {
        assertCleaning([
            CleanCase("fi", "\u{FB01}nd", "find"),
            CleanCase("fl", "\u{FB02}ow", "flow"),
            CleanCase("ff", "e\u{FB00}ect", "effect"),
            CleanCase("ffi", "e\u{FB03}cient", "efficient"),
            CleanCase("ffl", "ba\u{FB04}e", "baffle"),
            CleanCase("long s t", "mi\u{FB05}", "mist"),
            CleanCase("st", "mi\u{FB06}", "mist"),
            CleanCase("several in a sentence", "The \u{FB01}rst e\u{FB00}ort \u{FB01}xes the \u{FB02}aw.",
                      "The first effort fixes the flaw."),
            CleanCase("in a wrapped sentence", "the \u{FB02}ow is e\u{FB03}-\ncient and \u{FB01}ne", "the flow is efficient and fine"),
        ])
    }

    func testLigatureExpansionCountsForHyphenMerging() {
        assertCleaning([
            CleanCase("next line starts with a ligature", "dif-\n\u{FB01}cult", "difficult"),
            CleanCase("first half ends with a ligature", "arti\u{FB01}-\ncial", "artificial"),
        ])
    }

    /// Only the seven ligature code points are mapped. A blanket NFKC would also rewrite these,
    /// which papers rely on (see the design's TextCleaner rule 5).
    func testCompatibilityCharactersOutsideTheLigatureSetSurvive() {
        assertCleaning([
            CleanCase("superscripts", "x² + n³ + 10⁻⁶", "x² + n³ + 10⁻⁶"),
            CleanCase("fractions", "½ ¼ ⅓", "½ ¼ ⅓"),
            CleanCase("fullwidth Latin", "ＡＢＣ　ｘｙｚ", "ＡＢＣ　ｘｙｚ"),
            CleanCase("circled and units", "① ㎏ ℃ №", "① ㎏ ℃ №"),
            CleanCase("Dutch ij ligature", "ĳ", "ĳ"),
        ])
    }

    // MARK: Realistic passages

    func testMixedPassage() {
        assertCleaning([
            CleanCase(
                "paper excerpt",
                "The infor-\nmation of GPT-\n4 and COVID-\n19 is state-of-the-art [12, 13].\n\nNext para-\ngraph uses e\u{FB03}cient multi\u{00AD}\nthreading (Smith et al., 2020).",
                "The information of GPT-4 and COVID-19 is state-of-the-art [12, 13].\n\nNext paragraph uses efficient multithreading (Smith et al., 2020)."
            ),
            CleanCase(
                "Chinese paper with Latin terms",
                "我们使用 GPT-\n4 与 BERT\n模型。\n\n结果见表 1。",
                "我们使用 GPT-4 与 BERT 模型。\n\n结果见表 1。"
            ),
        ])
    }

    // MARK: Input size

    /// The cleaner runs on the main actor's selection path and before every cache lookup, so it
    /// must stay roughly linear. The bound is deliberately generous (typical run is milliseconds).
    func testTwoHundredKilobytesCleanQuickly() {
        let chunk = "The infor-\nmation about GPT-\n4 and multi\u{00AD}\nthread \u{FB01}nds the e\u{FB03}cient cost.\nSecond line here [1, 2].\n\n这是一个\n测试句子。\n\n"
        var input = ""
        while input.utf8.count < 200_000 { input += chunk }

        let start = Date()
        let cleaned = TextCleaner.clean(input)
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertLessThan(elapsed, 3.0, "200 KB took \(elapsed)s")
        XCTAssertTrue(cleaned.contains("information about GPT-4 and multithread finds the efficient cost."))
        XCTAssertTrue(cleaned.contains("这是一个测试句子。"))
        XCTAssertFalse(cleaned.contains("\u{00AD}"))
        XCTAssertFalse(cleaned.contains("\u{FB01}"))
        XCTAssertEqual(TextCleaner.clean(cleaned), cleaned)
    }

    func testLongUnbrokenAndHyphenHeavyInputs() {
        let hyphens = String(repeating: "ab-\n", count: 50_000) // 200 KB of chained breaks
        let start = Date()
        let merged = TextCleaner.clean(hyphens)
        let blanks = TextCleaner.clean(String(repeating: "\n", count: 200_000))
        let letters = TextCleaner.clean(String(repeating: "a", count: 200_000))
        let elapsed = Date().timeIntervalSince(start)

        // Every break merges except the last, which has no next line: its hyphen stays.
        XCTAssertEqual(merged, String(repeating: "ab", count: 50_000) + "-")
        XCTAssertEqual(blanks, "")
        XCTAssertEqual(letters.count, 200_000)
        XCTAssertLessThan(elapsed, 3.0, "pathological inputs took \(elapsed)s")
    }
}
