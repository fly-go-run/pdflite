import Foundation

/// Cheap, deterministic clean-up applied before sending text to the LLM. Goal: turn raw PDFKit
/// selection text into something that looks like prose, without losing information that papers
/// care about (formulas, citation numbers, English abbreviations).
///
/// The output is also hashed into the translation cache key, so every rule here is part of the
/// cache contract: changing what `clean` returns for some input orphans that input's cached rows.
///
/// Rules (per §3.8):
/// 1. PDF ligatures U+FB00…FB06 are spelled out (`ﬁ` → `fi`). Only those seven code points —
///    a blanket NFKC would also rewrite superscripts, fractions and math symbols.
/// 2. Soft hyphen U+00AD removed everywhere; before a line break it joins the two halves.
/// 3. Line-end hyphens (`-`, U+2010, U+2011): `foo-\nbar` → `foobar` only when both sides are
///    lowercase Latin letters (a syllable break). Otherwise the hyphen is real (`GPT-\n4`,
///    `Well-\nKnown`, `COVID-\n19`) and stays, with the lines joined without a space. A blank
///    line is never merged across.
/// 4. CJK ↔ CJK or CJK ↔ punctuation line breaks: drop the newline.
/// 5. Plain English line breaks: collapse to a single space.
/// 6. Triple+ blank lines normalised to a single paragraph break.
enum TextCleaner {
    static func clean(_ raw: String) -> String {
        guard !raw.isEmpty else { return raw }

        // Normalise the line endings first so the later steps don't have to think about \r.
        var text = raw.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")

        // Ligatures first: the hyphen heuristic below looks at letter case around a break, and
        // `ﬁ` would otherwise count as a non-Latin letter.
        text = expandLigatures(text)
        text = mergeHyphenatedLineBreaks(text)
        text = normaliseBlankLines(text)
        text = collapseLineBreaks(text)
        text = normaliseBlankLines(text)

        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Steps

    /// PDF text extraction hands back typographic ligatures as single code points, which the LLM
    /// tokenises poorly and which make the same word hash differently in the cache key. Explicit
    /// table, not NFKC (see rule 1). U+FB05 is "long s t"; NFKC would give a long s, we want `st`.
    private static let ligatures: [Unicode.Scalar: String] = [
        "\u{FB00}": "ff", "\u{FB01}": "fi", "\u{FB02}": "fl", "\u{FB03}": "ffi",
        "\u{FB04}": "ffl", "\u{FB05}": "st", "\u{FB06}": "st",
    ]

    private static func expandLigatures(_ text: String) -> String {
        // Nearly every selection has none; skip rebuilding the string then.
        guard text.unicodeScalars.contains(where: { (0xFB00...0xFB06).contains($0.value) }) else { return text }
        var result = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            if let spelled = ligatures[scalar] {
                result.append(contentsOf: spelled.unicodeScalars)
            } else {
                result.append(scalar)
            }
        }
        return String(result)
    }

    /// Hyphens (and soft hyphens) at the end of a line. One left-to-right pass, because the
    /// decision needs the letters on *both* sides of the break, which a fixed regex can't judge.
    ///
    /// - U+00AD before a newline, directly after a non-space character: the typesetter marked a
    ///   break point, so join without hyphen or space regardless of case. A U+00AD anywhere
    ///   else is simply dropped.
    /// - `-` / U+2010 / U+2011 before a newline, directly after a letter or digit:
    ///   - lowercase Latin letter before and after → syllable break (`infor-\nmation`): drop the
    ///     hyphen and join.
    ///   - anything else (`GPT-\n4`, `Well-\nKnown`, `GPT-\nbased`, `12-\n34`) → the hyphen is part
    ///     of the text: keep it and join without inserting a space. An uppercase letter before
    ///     the hyphen means an acronym compound, since a syllable break never ends in a capital.
    /// - If the next line is blank or missing, the newline is left alone: a paragraph boundary
    ///   must survive, and there is nothing to join.
    /// - A hyphen that does not follow a letter/digit (` -\n`, `--\n`, after CJK text) is
    ///   punctuation, not a word break, and goes through the ordinary newline rules.
    private static func mergeHyphenatedLineBreaks(_ text: String) -> String {
        let scalars = Array(text.unicodeScalars)
        var result = [Unicode.Scalar]()
        result.reserveCapacity(scalars.count)

        var i = 0
        while i < scalars.count {
            let c = scalars[i]
            let isSoftHyphen = c.value == 0x00AD
            guard isSoftHyphen || isLineEndHyphenCandidate(c) else {
                result.append(c)
                i += 1
                continue
            }

            // Start of the next line's text, after the newline and its indentation. A soft hyphen
            // counts as indentation: it is invisible, so a line holding only one is a blank line.
            var next = i + 1
            var joinsNextLine = false
            if next < scalars.count, scalars[next].value == 0x0A {
                next += 1
                while next < scalars.count, isLineIndent(scalars[next]) {
                    next += 1
                }
                joinsNextLine = next < scalars.count && scalars[next].value != 0x0A
            }

            if isSoftHyphen {
                // Only a soft hyphen that closes a word joins the lines. One on an otherwise
                // empty line is invisible padding: dropping it must leave the blank line intact.
                if joinsNextLine, let prev = result.last, !prev.properties.isWhitespace { i = next } else { i += 1 }
                continue
            }
            guard joinsNextLine, let prev = result.last, isHyphenableWordEnd(prev) else {
                result.append(c)
                i += 1
                continue
            }
            if !(isLatinLowercase(prev) && isLatinLowercase(scalars[next])) {
                result.append(c)
            }
            i = next
        }

        var merged = String.UnicodeScalarView()
        merged.append(contentsOf: result)
        return String(merged)
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
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return blankLinesPattern.stringByReplacingMatches(in: text, range: range, withTemplate: "\n\n")
    }

    // Compiled once, like every other hot-path regex in the project. Force-try is fine:
    // the patterns are constant and validated the first time they're used.
    // swiftlint:disable:next force_try
    private static let blankLinesPattern = try! NSRegularExpression(pattern: #"\n[ \t]*\n(?:[ \t]*\n)*"#)

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

    private static func isLineIndent(_ scalar: Unicode.Scalar) -> Bool {
        scalar.value == 0x20 || scalar.value == 0x09 || scalar.value == 0x00AD
    }

    private static func isLineEndHyphenCandidate(_ scalar: Unicode.Scalar) -> Bool {
        // Hyphen-minus, HYPHEN, NON-BREAKING HYPHEN. Dashes (en/em) and the minus sign are not
        // hyphenation marks.
        scalar.value == 0x002D || scalar.value == 0x2010 || scalar.value == 0x2011
    }

    /// Basic Latin through Latin Extended-B, so accented European text (`Ver-\nänderung`) merges
    /// like English. Greek/Cyrillic are excluded on purpose: `α-\nhelix` is a real compound.
    private static func isLatinLowercase(_ scalar: Unicode.Scalar) -> Bool {
        scalar.value < 0x0250 && scalar.properties.isLowercase
    }

    /// A letter or digit a hyphen can be attached to. CJK is excluded so a hyphen after Chinese
    /// or Japanese text keeps going through the ordinary CJK newline rules.
    private static func isHyphenableWordEnd(_ scalar: Unicode.Scalar) -> Bool {
        guard !isCJK(scalar) else { return false }
        return scalar.properties.isAlphabetic || scalar.properties.numericType != nil
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
