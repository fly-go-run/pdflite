import Foundation

/// Cheap, deterministic clean-up applied before sending text to the LLM. Goal: turn raw PDFKit
/// selection text into something that looks like prose, without losing information that papers
/// care about (formulas, citation numbers, English abbreviations).
///
/// Rules (per §3.8):
/// 1. Soft hyphen U+00AD removed everywhere.
/// 2. Hyphenated line breaks `foo-\nbar` → `foobar` (English hyphenation only).
/// 3. CJK ↔ CJK or CJK ↔ punctuation line breaks: drop the newline.
/// 4. Plain English line breaks: collapse to a single space.
/// 5. Triple+ blank lines normalised to a single paragraph break.
enum TextCleaner {
    static func clean(_ raw: String) -> String {
        guard !raw.isEmpty else { return raw }

        // Normalise the line endings first so the regex steps don't have to think about \r.
        var text = raw.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\u{00AD}", with: "") // soft hyphen

        text = mergeHyphenatedLineBreaks(text)
        text = normaliseBlankLines(text)
        text = collapseLineBreaks(text)
        text = normaliseBlankLines(text)

        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Steps

    /// English hyphenation across line breaks: `multi-\nthread` → `multithread`. Only fires when
    /// the character before the hyphen is a Latin letter (so we don't eat dashes in formulas /
    /// number ranges like `12-\n34`).
    private static func mergeHyphenatedLineBreaks(_ text: String) -> String {
        let pattern = #"([A-Za-z])-\n[ \t]*"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.stringByReplacingMatches(in: text, range: range, withTemplate: "$1")
    }

    /// Collapse single newlines based on neighbouring characters.
    /// - CJK ↔ CJK: drop newline (no space, papers wrap CJK without spaces).
    /// - else: replace newline with single space.
    /// Multiple blank lines (paragraph breaks) are preserved by `normaliseBlankLines` afterwards.
    private static func collapseLineBreaks(_ text: String) -> String {
        var result = ""
        result.reserveCapacity(text.count)

        let scalars = Array(text.unicodeScalars)
        var i = 0
        while i < scalars.count {
            let c = scalars[i]
            if c.value == 0x0A { // newline
                // Preserve paragraph breaks. `normaliseBlankLines` has already collapsed any
                // multi-newline run to exactly two newlines, so skip both here.
                if i + 1 < scalars.count, scalars[i + 1].value == 0x0A {
                    result.append("\n\n")
                    i += 2
                    continue
                }
                let prev = scalars[safe: i - 1]
                let next = scalars[safe: i + 1]
                if let prev, let next, isCJK(prev) && (isCJK(next) || isCJKPunctuation(next)) {
                    // drop the newline entirely
                } else if let prev, let next, isCJKPunctuation(prev) && isCJK(next) {
                    // drop
                } else {
                    result.append(" ")
                }
                i += 1
            } else {
                result.unicodeScalars.append(c)
                i += 1
            }
        }
        return result
    }

    private static func normaliseBlankLines(_ text: String) -> String {
        let pattern = #"\n[ \t]*\n(?:[ \t]*\n)*"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.stringByReplacingMatches(in: text, range: range, withTemplate: "\n\n")
    }

    // MARK: - Unicode helpers

    private static func isCJK(_ scalar: Unicode.Scalar) -> Bool {
        let v = scalar.value
        // CJK Unified Ideographs + extensions A/B/C/D/E + compatibility forms.
        return (0x4E00...0x9FFF).contains(v)
            || (0x3400...0x4DBF).contains(v)
            || (0x20000...0x2A6DF).contains(v)
            || (0x2A700...0x2B73F).contains(v)
            || (0x2B740...0x2B81F).contains(v)
            || (0xF900...0xFAFF).contains(v)
            // Hiragana / Katakana — same line-break rules apply.
            || (0x3040...0x309F).contains(v)
            || (0x30A0...0x30FF).contains(v)
    }

    private static func isCJKPunctuation(_ scalar: Unicode.Scalar) -> Bool {
        let v = scalar.value
        // CJK symbols & punctuation, fullwidth forms, Vertical forms.
        return (0x3000...0x303F).contains(v)
            || (0xFF00...0xFFEF).contains(v)
            || (0xFE30...0xFE4F).contains(v)
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
