import Foundation
import PDFKit

/// A "Figure 3" / "Table 2" reference parsed out of a text selection. v0 only handles single
/// numbers — ranges ("Figures 3-5") and conjunctions ("Figs. 3 and 4") just take the first
/// number.
struct FigureReference: Equatable {
    enum Kind: String { case figure, table }
    let kind: Kind
    let number: Int

    /// Canonical caption label used for full-doc search ("Figure 3" / "Table 2").
    var canonicalLabel: String {
        switch kind {
        case .figure: return "Figure \(number)"
        case .table: return "Table \(number)"
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

    // First token is the kind word, then the first 1–3 digit number. Anchored with `^` so a
    // selection of body text that happens to *contain* "Figure 3" later doesn't match — the user
    // should be able to select the inline mention directly.
    // swiftlint:disable:next force_try
    private static let pattern = try! NSRegularExpression(
        pattern: #"^(?i)(figure|fig\.?|table|tab\.?)\s*(\d{1,3})\b"#
    )
}
