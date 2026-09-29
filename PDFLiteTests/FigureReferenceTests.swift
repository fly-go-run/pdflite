import XCTest

/// `FigureReference.parse` (which selections sprout a "跳到 Figure N" button) and the caption /
/// mention regexes the jump uses. Wrong matches are worse than none, so the negative table is as
/// important as the positive one.
final class FigureReferenceTests: XCTestCase {
    private typealias Ref = FigureReference

    // MARK: - parse: accepted forms

    func testAcceptedFormsParseToTheFirstNamedItem() {
        let cases: [(String, Ref)] = [
            // Existing forms must keep working.
            ("Figure 3", Ref(kind: .figure, number: 3)),
            ("Fig. 3", Ref(kind: .figure, number: 3)),
            ("Fig 3", Ref(kind: .figure, number: 3)),
            ("fig.3", Ref(kind: .figure, number: 3)),
            ("FIGURE 3", Ref(kind: .figure, number: 3)),
            ("  Figure 3\n", Ref(kind: .figure, number: 3)),
            ("see Figure 3", Ref(kind: .figure, number: 3)),
            ("(Fig. 3)", Ref(kind: .figure, number: 3)),
            ("as shown in Figure 12", Ref(kind: .figure, number: 12)),
            ("Fig. 3.", Ref(kind: .figure, number: 3)),
            ("Fig. 3 | Overview", Ref(kind: .figure, number: 3)),
            ("Table 2", Ref(kind: .table, number: 2)),
            ("Tab. 2", Ref(kind: .table, number: 2)),
            ("Tab 2", Ref(kind: .table, number: 2)),
            ("TABLE 2", Ref(kind: .table, number: 2)),
            // A panel letter names a panel of the same figure.
            ("Figure 3a", Ref(kind: .figure, number: 3)),
            ("Fig. 3a", Ref(kind: .figure, number: 3)),
            ("Figure 3(a)", Ref(kind: .figure, number: 3)),
            ("Fig. 3b,c", Ref(kind: .figure, number: 3)),
            ("Figure 3a-c", Ref(kind: .figure, number: 3)),
            // Plurals and ranges jump to the first item.
            ("Figures 3 and 4", Ref(kind: .figure, number: 3)),
            ("Figs. 3-4", Ref(kind: .figure, number: 3)),
            ("Figs 3\u{2013}5", Ref(kind: .figure, number: 3)),
            ("Figs. 3, 4 and 5", Ref(kind: .figure, number: 3)),
            ("Tables 2 and 3", Ref(kind: .table, number: 2)),
            ("Tabs. 2-3", Ref(kind: .table, number: 2)),
            // Supplementary labels are their own sequence.
            ("Figure S3", Ref(kind: .figure, number: 3, isSupplementary: true)),
            ("Fig. S3", Ref(kind: .figure, number: 3, isSupplementary: true)),
            ("Figure S3a", Ref(kind: .figure, number: 3, isSupplementary: true)),
            ("Table S2", Ref(kind: .table, number: 2, isSupplementary: true)),
            ("Supplementary Figure S3", Ref(kind: .figure, number: 3, isSupplementary: true)),
        ]
        for (text, expected) in cases {
            XCTAssertEqual(Ref.parse(text), expected, "parse(\(text.debugDescription))")
        }
    }

    // MARK: - parse: rejected

    func testNonReferencesAndAmbiguousLabelsReturnNil() {
        let cases = [
            "", "   ", "Figure", "Fig.", "Table", "Figure a", "Figure S",
            "Configuration 3", "prefigure 3", "Stable 2", "Tabulate 2", "Comfortable 2",
            // More than one trailing letter / digit is not a panel or a small number.
            "Figure 3rd", "Figure 3abc", "Figure 1234", "Figure s3",
            // Chapter-style decimal labels can't be addressed by an integer: no button beats a
            // jump to the wrong figure.
            "Figure 3.2", "Fig. 3.2", "Table 2.1",
            // A supplement's own "Figure 3" is not the main text's.
            "Supplementary Figure 3", "Supplemental Table 2", "Extended Data Fig. 3",
            // A paragraph that merely contains a reference.
            "The results of the ablation study are shown in Figure 3",
        ]
        for text in cases {
            XCTAssertNil(Ref.parse(text), "parse(\(text.debugDescription)) must not match")
        }
    }

    func testLabelsForTheUI() {
        XCTAssertEqual(Ref(kind: .figure, number: 3).canonicalLabel, "Figure 3")
        XCTAssertEqual(Ref(kind: .table, number: 2).canonicalLabel, "Table 2")
        XCTAssertEqual(Ref(kind: .figure, number: 3, isSupplementary: true).canonicalLabel, "Figure S3")
        XCTAssertEqual(Ref(kind: .table, number: 2, isSupplementary: true).canonicalLabel, "Table S2")
    }

    // MARK: - Caption vs mention lines

    private func isCaption(_ text: String, _ reference: Ref) -> Bool {
        reference.captionRegex.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length)) != nil
    }

    private func isMention(_ text: String, _ reference: Ref) -> Bool {
        reference.mentionRegex.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length)) != nil
    }

    func testCaptionLinesAcrossJournalStyles() {
        let figure3 = Ref(kind: .figure, number: 3)
        let captions = [
            "Figure 3. Overview of the model.",          // CVPR / ACL
            "Figure 3: Overview of the model.",          // ACM / NeurIPS
            "Fig. 3. Overview of the model.",            // Elsevier / IEEE
            "Fig. 3 | Overview of the model.",           // Nature
            "Fig. 3 Overview of the model",              // Springer
            "  Figure 3. Overview",                      // indented
            "FIGURE 3. OVERVIEW",
            "Fig.3: Overview",
            "Some earlier text\nFigure 3. Overview of the model.", // second line of the page
        ]
        for line in captions {
            XCTAssertTrue(isCaption(line, figure3), "caption expected: \(line.debugDescription)")
        }
    }

    func testMentionsAndLookalikesAreNotCaptions() {
        let figure3 = Ref(kind: .figure, number: 3)
        let notCaptions = [
            "as shown in Figure 3.",                     // sentence-ending mention, not line-initial
            "as shown in Figure 3: the model",
            "Figure 3 shows the overview",               // opens a line, continues lowercase
            "Figure 3a. Panel description",              // a panel, not the caption line itself
            "Figure 30. Another figure",
            "Figure 3.2 A chapter-numbered figure",
            "Figure 3",                                  // bare label
            "Figure S3. Supplementary caption",
            "Table 3. Not a figure",
        ]
        for line in notCaptions {
            XCTAssertFalse(isCaption(line, figure3), "not a caption: \(line.debugDescription)")
        }
    }

    func testTableAndSupplementaryCaptions() {
        let table2 = Ref(kind: .table, number: 2)
        XCTAssertTrue(isCaption("Table 2. Results on the test set.", table2))
        XCTAssertTrue(isCaption("Tab. 2 | Results", table2))
        XCTAssertFalse(isCaption("as reported in Table 2.", table2))

        let supp = Ref(kind: .figure, number: 3, isSupplementary: true)
        XCTAssertTrue(isCaption("Figure S3. Extra results.", supp))
        XCTAssertTrue(isCaption("Supplementary Figure S3. Extra results.", supp))
        XCTAssertFalse(isCaption("Figure 3. Overview of the model.", supp), "S3 is not 3")
        XCTAssertFalse(isCaption("Figure S3. Extra results.", Ref(kind: .figure, number: 3)), "3 is not S3")
    }

    func testMentionRegexClosesTheNumber() {
        let figure3 = Ref(kind: .figure, number: 3)
        for text in ["see Figure 3", "(Fig. 3)", "Figure 3a shows", "in Fig 3, the", "Figure 3."] {
            XCTAssertTrue(isMention(text, figure3), "mention expected: \(text.debugDescription)")
        }
        for text in ["Figure 30", "Figure 3.2", "prefigure 3", "Figure 3rd", "Figure S3", "Table 3"] {
            XCTAssertFalse(isMention(text, figure3), "not a mention of Figure 3: \(text.debugDescription)")
        }
    }
}
