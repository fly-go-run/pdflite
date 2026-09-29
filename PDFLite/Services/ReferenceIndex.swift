import Foundation
import PDFKit

struct ReferenceEntry: Sendable, Equatable {
    let number: Int
    let text: String
    let pageIndex: Int
}

/// Hands the live PDFDocument to the background build. @unchecked Sendable is sound for the same
/// reason as ParsedDocument / PDFPageWarmupService: the build only *reads* (page.string), which
/// PDFKit tolerates off the main thread, and the box never outlives the build.
private struct ReferenceDocumentBox: @unchecked Sendable {
    let document: PDFDocument
}

/// Per-document, in-memory index of numeric bibliography entries (`[12]` style). Built off the
/// click path by `prepare()` so that lookups during a mouseDown stay non-blocking — if the index
/// isn't ready yet, `entry(forNumber:)` returns nil and the caller falls back to plain navigation.
/// v0 only recognizes single bracketed numbers; author-year and ranges are out of scope.
@MainActor
final class ReferenceIndex {
    private weak var document: PDFDocument?
    private var entries: [Int: ReferenceEntry] = [:]
    private var state: State = .idle

    private enum State {
        case idle
        case preparing
        case ready
    }

    /// How many trailing pages `locateHeader` will look at. The bibliography lives in the back
    /// matter: a paper's References (plus any appendix) fits well inside 60 pages, and a book's
    /// bibliography sits before its index. A heading further from the end than that is almost
    /// certainly a chapter's own reference list or a passing "References" line, which would
    /// build a wrong index — and with no header at all the old scan extracted the text of EVERY
    /// page (~250 ms of PDFKit text extraction, competing with rendering) after every open.
    /// Documents of 60 pages or fewer are still scanned in full.
    nonisolated static let headerScanWindow = 60

    /// Longest entry text kept (after cleaning), in characters. A bibliography entry is usually
    /// 100–350 characters; 1000 leaves room for a 60-author collaboration entry while capping
    /// how much unrelated text can ride along when an entry has no clean end (the last entry
    /// otherwise runs to the end of the document). A capped entry ends in "…".
    nonisolated static let maxEntryLength = 1000

    init(document: PDFDocument?) {
        self.document = document
    }

    /// Non-blocking lookup. Returns nil while preparing — caller should fall back to a plain jump.
    func entry(forNumber number: Int) -> ReferenceEntry? {
        guard state == .ready else { return nil }
        return entries[number]
    }

    /// Build the index in the background. Idempotent: a second call while preparing or after
    /// becoming ready is a no-op. The heavy lifting (per-page text extraction + regex matching)
    /// runs off the main actor; only the finished dictionary crosses back.
    func prepare() async {
        guard state == .idle else { return }
        state = .preparing
        guard let document, document.pageCount > 0 else {
            state = .ready
            return
        }
        let box = ReferenceDocumentBox(document: document)
        entries = await Self.buildIndex(box: box)
        state = .ready
    }

    func reset() {
        entries.removeAll()
        state = .idle
    }

    // MARK: - Build (runs on the global executor, off the main actor)

    private nonisolated static func buildIndex(box: ReferenceDocumentBox) async -> [Int: ReferenceEntry] {
        let document = box.document
        guard let header = locateHeader(in: document) else { return [:] }

        var combined = ""
        var pageOffsets: [(offset: Int, page: Int)] = []
        let trailing = (header.pageString as NSString).substring(from: header.headerRange.upperBound)
        pageOffsets.append((0, header.pageIndex))
        combined.append(trailing)
        // Running UTF-16 offset, accumulated per page — recounting `combined` each iteration
        // would make this loop quadratic in the size of the back matter.
        var runningOffset = (trailing as NSString).length
        for index in (header.pageIndex + 1)..<document.pageCount {
            if Task.isCancelled { return [:] }
            guard let pageString = document.page(at: index)?.string,
                  !pageString.isEmpty else { continue }
            pageOffsets.append((runningOffset + 1, index))
            combined.append("\n")
            combined.append(pageString)
            runningOffset += 1 + (pageString as NSString).length
        }

        if Task.isCancelled { return [:] }
        return matchEntries(in: combined, pageOffsets: pageOffsets, fallbackPage: header.pageIndex)
    }

    private struct HeaderHit {
        let pageIndex: Int
        let pageString: String
        let headerRange: NSRange
    }

    private nonisolated static func locateHeader(in document: PDFDocument) -> HeaderHit? {
        // Scan from the last page backward — academic PDFs put References in the back matter, and
        // a survey paper's body might mention "References" in passing. The first match from the
        // end is almost always the real bibliography. Only the last `headerScanWindow` pages are
        // considered; no header there means no index (callers fall back to plain navigation).
        let firstCandidate = max(0, document.pageCount - headerScanWindow)
        for index in stride(from: document.pageCount - 1, through: firstCandidate, by: -1) {
            if Task.isCancelled { return nil }
            guard let pageString = document.page(at: index)?.string,
                  !pageString.isEmpty else { continue }
            let range = NSRange(location: 0, length: (pageString as NSString).length)
            if let match = ReferenceIndex.headerPattern.matches(in: pageString, range: range).last {
                return HeaderHit(pageIndex: index, pageString: pageString, headerRange: match.range)
            }
        }
        return nil
    }

    nonisolated static func matchEntries(
        in combined: String,
        pageOffsets: [(offset: Int, page: Int)],
        fallbackPage: Int
    ) -> [Int: ReferenceEntry] {
        let nsCombined = combined as NSString
        let combinedRange = NSRange(location: 0, length: nsCombined.length)
        let matches = ReferenceIndex.entryPattern.matches(in: combined, range: combinedRange)
        guard !matches.isEmpty else { return [:] }

        var result: [Int: ReferenceEntry] = [:]
        for (i, match) in matches.enumerated() {
            let bracketRange = match.range(at: 1)
            let dotRange = match.range(at: 2)
            let numberRange = bracketRange.location != NSNotFound ? bracketRange : dotRange
            guard numberRange.location != NSNotFound,
                  let number = Int(nsCombined.substring(with: numberRange)) else { continue }

            let bodyStart = match.range.upperBound
            // An entry ends where the next marker starts. The last one has no such marker — it
            // would run to the end of the document — so the read window is bounded as well
            // (twice the kept length: cleaning only ever shrinks the text).
            let nextStart = i + 1 < matches.count ? matches[i + 1].range.location : nsCombined.length
            let bodyEnd = min(nextStart, bodyStart + 2 * maxEntryLength)
            guard bodyEnd > bodyStart else { continue }
            let raw = nsCombined.substring(with: NSRange(location: bodyStart, length: bodyEnd - bodyStart))
            let body = entryBody(from: raw, isLastMarker: i + 1 == matches.count)
            guard !body.isEmpty else { continue }

            let pageIndex = page(forOffset: match.range.location, in: pageOffsets) ?? fallbackPage
            // Keep the first occurrence so a stray "[1]" inside body text can't shadow the real
            // entry that should appear earlier in the bibliography.
            if result[number] == nil {
                result[number] = ReferenceEntry(number: number, text: body, pageIndex: pageIndex)
            }
        }
        return result
    }

    /// Cut the raw text after a marker down to the entry itself: stop at the first line that
    /// opens a new section (an appendix hiding behind the last entry), clean, then cap the length.
    private nonisolated static func entryBody(from raw: String, isLastMarker: Bool) -> String {
        let lines = raw.components(separatedBy: "\n")
        var kept: [String] = []
        for (offset, line) in lines.enumerated() {
            // Line 0 is the rest of the marker's own line: never a heading.
            if offset > 0,
               isSectionHeading(line, previousLine: lines[offset - 1], allowWeakForms: isLastMarker) {
                break
            }
            kept.append(line)
        }
        return capped(cleanEntryBody(kept.joined(separator: "\n")))
    }

    /// Does `line` open a new section rather than continue a reference? Wrong cuts are cheap
    /// (a shortened preview) but so is a leaked appendix, so this is deliberately narrow:
    /// - Strong forms are unmistakable ("Appendix A", "Supplementary Material", "Acknowledgments")
    ///   and count anywhere.
    /// - Weak forms — lettered ("A Proofs", "B.1 Details"), numbered ("9 Limitations") and
    ///   ALL-CAPS titles — look like the start of a wrapped bibliography line just as easily
    ///   ("A Survey of…", "K. Simonyan"), so they only count for the LAST entry (the only one
    ///   with no marker to bound it), on a short line without commas or a trailing period,
    ///   right after a line that ends like a finished entry.
    nonisolated static func isSectionHeading(_ line: String, previousLine: String?, allowWeakForms: Bool) -> Bool {
        let text = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count <= 80 else { return false }
        let range = NSRange(location: 0, length: (text as NSString).length)
        if strongHeadingPattern.firstMatch(in: text, range: range) != nil { return true }
        guard allowWeakForms, endsLikeFinishedEntry(previousLine) else { return false }
        return weakHeadingPatterns.contains { $0.firstMatch(in: text, range: range) != nil }
    }

    /// A finished entry ends with a full stop, a closing bracket or a digit (year, pages, URL id);
    /// a blank line is a break too. A line ending mid-sentence ("…for") is a wrap, not an end.
    private nonisolated static func endsLikeFinishedEntry(_ line: String?) -> Bool {
        guard let last = line?.trimmingCharacters(in: .whitespacesAndNewlines).last else { return true }
        return last == "." || last == ")" || last == "]" || last.isNumber
    }

    /// Cap at `maxEntryLength`, cutting at a word boundary unless that would discard most of the text.
    private nonisolated static func capped(_ text: String) -> String {
        guard text.count > maxEntryLength else { return text }
        let head = text.prefix(maxEntryLength)
        var end = head.endIndex
        if let space = head.lastIndex(of: " "), head.distance(from: head.startIndex, to: space) > maxEntryLength / 2 {
            end = space
        }
        return head[..<end].trimmingCharacters(in: .whitespacesAndNewlines) + "…"
    }

    private nonisolated static func cleanEntryBody(_ raw: String) -> String {
        var s = raw.replacingOccurrences(of: "-\n", with: "")
        s = s.replacingOccurrences(of: "\r\n", with: "\n")
        s = s.replacingOccurrences(of: "\n", with: " ")
        s = s.replacingOccurrences(of: "\r", with: " ")
        while s.contains("  ") { s = s.replacingOccurrences(of: "  ", with: " ") }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private nonisolated static func page(forOffset offset: Int, in offsets: [(offset: Int, page: Int)]) -> Int? {
        var match: Int?
        for entry in offsets {
            if entry.offset <= offset { match = entry.page } else { break }
        }
        return match
    }

    // Compiled once. Force-try is fine: these patterns are constant and validated at init time.
    // The whole line must be the heading: "7 References", "VII. REFERENCES", "References and
    // Notes", "Bibliography", "参考文献" — never a sentence that merely mentions references.
    // Horizontal whitespace only (`\h`), so a heading can't be stitched to a neighbouring line.
    nonisolated static let headerPattern: NSRegularExpression = {
        // swiftlint:disable:next force_try
        try! NSRegularExpression(
            pattern: #"^\h*(?:(?:\d{1,2}|(?-i:[IVX]{1,6}))(?:[.)]\h*|\h+))?(?:references(?:\h+and\h+notes)?|reference\h+list|notes\h+and\h+references|bibliography|参考文献|参\h*考\h*文\h*献)\h*[:：]?\h*$"#,
            options: [.caseInsensitive, .anchorsMatchLines]
        )
    }()

    private nonisolated static let strongHeadingPattern: NSRegularExpression = {
        // swiftlint:disable:next force_try
        try! NSRegularExpression(
            pattern: #"^(?:appendix|appendices|supplement(?:ary|al)|supporting\s+information|acknowledg(?:e)?ments?)\b"#,
            options: [.caseInsensitive]
        )
    }()

    private nonisolated static let weakHeadingPatterns: [NSRegularExpression] = {
        let patterns = [
            // "A Proofs", "A. Additional Results", "B.1 Implementation details"
            #"^[A-Z](?:\.\d{1,2})*[.:]?\h+[A-Z][^,;\n]{1,58}[^,;.\n]$"#,
            // "9 Limitations", "10.1 Extra experiments"
            #"^\d{1,2}(?:\.\d{1,2})*\.?\h+[A-Z][^,;\n]{1,58}[^,;.\n]$"#,
            // "ACKNOWLEDGMENTS", "A. PROOFS" — 6+ capitals, nothing else
            #"^(?:[A-Z]\.?\h+)?[A-Z][A-Z &:–-]{5,70}$"#,
        ]
        // swiftlint:disable:next force_try
        return patterns.map { try! NSRegularExpression(pattern: $0) }
    }()

    private nonisolated static let entryPattern: NSRegularExpression = {
        // swiftlint:disable:next force_try
        try! NSRegularExpression(
            pattern: #"(?m)^\s*(?:\[(\d{1,3})\]|(\d{1,3})\.)\s+"#
        )
    }()
}
