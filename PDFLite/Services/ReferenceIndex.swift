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
        // end is almost always the real bibliography.
        for index in stride(from: document.pageCount - 1, through: 0, by: -1) {
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

    private nonisolated static func matchEntries(
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
            let bodyEnd = i + 1 < matches.count ? matches[i + 1].range.location : nsCombined.length
            guard bodyEnd > bodyStart else { continue }
            let raw = nsCombined.substring(with: NSRange(location: bodyStart, length: bodyEnd - bodyStart))
            let body = cleanEntryBody(raw)
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
    private nonisolated static let headerPattern: NSRegularExpression = {
        // swiftlint:disable:next force_try
        try! NSRegularExpression(
            pattern: #"(?im)^\s*(References|REFERENCES|Bibliography|BIBLIOGRAPHY|参考文献)\s*$"#
        )
    }()

    private nonisolated static let entryPattern: NSRegularExpression = {
        // swiftlint:disable:next force_try
        try! NSRegularExpression(
            pattern: #"(?m)^\s*(?:\[(\d{1,3})\]|(\d{1,3})\.)\s+"#
        )
    }()
}
