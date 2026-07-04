import Foundation
import PDFKit

/// A "Figure 3" / "Table 2" reference parsed out of a text selection. v0 only handles single
/// numbers — ranges ("Figures 3-5") and conjunctions ("Figs. 3 and 4") just take the first
/// number.
struct FigureReference: Equatable {
    enum Kind: String { case figure, table }
    let kind: Kind
    let number: Int

    /// Canonical caption label used for UI ("Figure 3" / "Table 2").
    var canonicalLabel: String {
        switch kind {
        case .figure: return "Figure \(number)"
        case .table: return "Table \(number)"
        }
    }

    /// Caption spellings to try when searching the document. Journals are split between the
    /// full word and the abbreviation ("Fig. 3:", "Fig 3 |"), so the jump has to try both.
    var searchLabels: [String] {
        switch kind {
        case .figure: return ["Figure \(number)", "Fig. \(number)", "Fig \(number)"]
        case .table: return ["Table \(number)", "Tab. \(number)", "Tab \(number)"]
        }
    }

    /// Try to parse a reference out of arbitrary selection text. Returns nil when the leading
    /// token doesn't match the expected "Fig./Figure/Tab./Table N" shape.
    static func parse(_ text: String) -> FigureReference? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let nsText = trimmed as NSString
        let range = NSRange(location: 0, length: nsText.length)
        guard let match = pattern.firstMatch(in: trimmed, range: range),
              match.numberOfRanges >= 3 else { return nil }

        let kindRaw = nsText.substring(with: match.range(at: 1)).lowercased()
        let numberRaw = nsText.substring(with: match.range(at: 2))
        guard let number = Int(numberRaw) else { return nil }

        let kind: Kind = kindRaw.hasPrefix("t") ? .table : .figure
        return FigureReference(kind: kind, number: number)
    }

    // The kind word may carry a short prefix ("see Figure 3", "(Fig. 3)") — up to 24 characters,
    // so a paragraph-sized selection that merely *contains* "Figure 3" still doesn't sprout a
    // jump button. Then the first 1–3 digit number.
    // swiftlint:disable:next force_try
    private static let pattern = try! NSRegularExpression(
        pattern: #"(?i)^.{0,24}?\b(figure|fig\.?|table|tab\.?)\s*(\d{1,3})\b"#,
        options: [.dotMatchesLineSeparators]
    )
}
