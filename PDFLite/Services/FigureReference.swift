import Foundation
import PDFKit

/// A "Figure 3" / "Table 2" reference parsed out of a text selection. Plural and range forms
/// ("Figures 3 and 4", "Figs. 3-4") jump to the FIRST item they name; a trailing panel letter
/// ("Figure 3a", "Fig. 3(b)") is ignored because the caption belongs to the whole figure; and
/// supplementary labels ("Figure S3") are kept apart from the main-text numbers.
struct FigureReference: Equatable {
    enum Kind: String { case figure, table }
    let kind: Kind
    let number: Int
    /// "S3"-style label: a different sequence than the main-text "3", so it must never be
    /// searched as "Figure 3".
    let isSupplementary: Bool

    init(kind: Kind, number: Int, isSupplementary: Bool = false) {
        self.kind = kind
        self.number = number
        self.isSupplementary = isSupplementary
    }

    /// Canonical caption label used for UI ("Figure 3" / "Table S2").
    var canonicalLabel: String {
        switch kind {
        case .figure: return "Figure \(numberToken)"
        case .table: return "Table \(numberToken)"
        }
    }

    private var numberToken: String { isSupplementary ? "S\(number)" : "\(number)" }

    /// Regex fragment matching the label in any spelling. Journals are split between the full
    /// word and the abbreviation ("Fig. 3:", "Fig 3 |"), so both are accepted. The number is
    /// closed off so "Figure 3" never matches "Figure 30" or the chapter-style "Figure 3.2".
    private var labelPattern: String {
        let word = kind == .figure ? #"(?:figure|fig\.?)"# : #"(?:table|tab\.?)"#
        let prefix = isSupplementary ? #"(?-i:S)"# : ""
        return #"\#(word)\h*\#(prefix)\#(number)"#
    }

    /// A caption LINE: the label opens the line and is followed by a caption delimiter ("Figure 3.",
    /// "Fig. 3:", "Fig. 3 |") or by a capitalised title word ("Fig. 3 Overview of…", the Springer
    /// style). "…as shown in Figure 3." has the same label + "." but does not open its line, and
    /// "Figure 3 shows…" opens one but continues in lowercase — neither is a caption.
    /// Matched line by line (`.anchorsMatchLines`) against `PDFPage.string`.
    var captionRegex: NSRegularExpression {
        // A supplementary caption may carry the word: "Supplementary Figure S3."
        let qualifier = isSupplementary ? #"(?:supplement(?:ary|al)\h+)?"# : ""
        return Self.compile(
            #"^\h*\#(qualifier)\#(labelPattern)(?![0-9A-Za-z])(?:\h*[.:|](?!\d)|\h+(?=(?-i:[A-Z])))"#,
            options: [.caseInsensitive, .anchorsMatchLines]
        )
    }

    /// The label anywhere in a line — an inline mention (or an unrecognised caption style).
    /// The trailing letter of a panel ("3a") is allowed; a longer word or a decimal is not.
    var mentionRegex: NSRegularExpression {
        Self.compile(
            #"\b\#(labelPattern)(?:(?-i:[a-z]))?(?![A-Za-z0-9]|\.\d)"#,
            options: [.caseInsensitive]
        )
    }

    private static func compile(_ pattern: String, options: NSRegularExpression.Options) -> NSRegularExpression {
        // Built only from the constant fragments above plus an Int, so it always compiles.
        // swiftlint:disable:next force_try
        try! NSRegularExpression(pattern: pattern, options: options)
    }

    /// Try to parse a reference out of arbitrary selection text. Returns nil when the leading
    /// token doesn't match the expected "Fig./Figure(s)/Tab./Table(s) N" shape.
    static func parse(_ text: String) -> FigureReference? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let nsText = trimmed as NSString
        let range = NSRange(location: 0, length: nsText.length)
        guard let match = pattern.firstMatch(in: trimmed, range: range),
              match.numberOfRanges >= 5 else { return nil }

        let prefix = nsText.substring(with: match.range(at: 1))
        let kindRaw = nsText.substring(with: match.range(at: 2)).lowercased()
        let isSupplementary = match.range(at: 3).location != NSNotFound
        guard let number = Int(nsText.substring(with: match.range(at: 4))) else { return nil }

        // "Supplementary Figure 3" / "Extended Data Fig. 3" name a figure in the supplement, not
        // the main text's "Figure 3" — jumping to the latter would be a wrong match. (Only the
        // S-numbered form is a label this document can carry.)
        if !isSupplementary,
           qualifierPattern.firstMatch(in: prefix, range: NSRange(location: 0, length: (prefix as NSString).length)) != nil {
            return nil
        }

        let kind: Kind = kindRaw.hasPrefix("t") ? .table : .figure
        return FigureReference(kind: kind, number: number, isSupplementary: isSupplementary)
    }

    // The kind word may carry a short prefix ("see Figure 3", "(Fig. 3)") — up to 24 characters,
    // so a paragraph-sized selection that merely *contains* "Figure 3" still doesn't sprout a
    // jump button. Then an optional supplementary "S" and the first 1–3 digit number, optionally
    // followed by ONE lowercase panel letter. The lookahead rejects longer words ("3rd"), more
    // digits ("Figure 2020") and decimal labels ("Figure 3.2" — chapter-numbered documents,
    // which a bare integer can't address, so no button beats a wrong jump).
    // swiftlint:disable:next force_try
    private static let pattern = try! NSRegularExpression(
        pattern: #"(?i)^(.{0,24}?)\b(figures?|figs?\.?|tables?|tabs?\.?)\s*((?-i:S))?(\d{1,3})(?:(?-i:[a-z]))?(?![A-Za-z0-9]|\.\d)"#,
        options: [.dotMatchesLineSeparators]
    )

    // swiftlint:disable:next force_try
    private static let qualifierPattern = try! NSRegularExpression(
        pattern: #"(?i)\b(?:supplement(?:ary|al)|extended\s+data)\s*$"#
    )
}
