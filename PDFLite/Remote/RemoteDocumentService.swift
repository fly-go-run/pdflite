import Foundation
import os.log

enum RemoteDocumentError: LocalizedError {
    case badStatus(Int)
    case notPDF

    var errorDescription: String? {
        switch self {
        case .badStatus(let code):
            // OpenReview / bioRxiv answer scripted clients with a browser challenge (403/429).
            let hint = [401, 403, 429].contains(code)
                ? "该站点可能要求浏览器验证或限制了自动下载，可先在浏览器里下载 PDF 再拖入 PDFLite。"
                : ""
            return "服务器返回了 HTTP \(code)。" + hint
        case .notPDF:
            return "下载的内容不是 PDF（可能是网页或错误页）。请确认链接直接指向 PDF 文件。"
        }
    }
}

/// Where downloaded PDFs live and how they're named. Layout:
/// `~/Library/Application Support/PDFLite/library/{arxiv,web}/<name> [<token>].pdf`
/// The bracketed token suffix is the dedup key — no database involvement, so files stay
/// self-describing and survive any DB reset.
enum RemoteDocumentLibrary {
    private static let subdirectories = ["arxiv", "web"]

    static func directory(for subdirectory: String,
                          in root: URL = AppPaths.remoteLibraryDirectory) -> URL {
        let dir = root.appendingPathComponent(subdirectory, isDirectory: true)
        let fm = FileManager.default
        if !fm.fileExists(atPath: dir.path) {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    /// Already downloaded from this source? Any spelling of the same source normalizes to the
    /// same token, so a suffix scan across the library answers "have we got this one".
    static func existingFile(token: String,
                             in root: URL = AppPaths.remoteLibraryDirectory) -> URL? {
        let fm = FileManager.default
        let suffix = "[\(token)].pdf"
        for sub in subdirectories {
            let dir = root.appendingPathComponent(sub, isDirectory: true)
            guard let names = try? fm.contentsOfDirectory(atPath: dir.path) else { continue }
            if let hit = names.first(where: { $0.hasSuffix(suffix) }) {
                let url = dir.appendingPathComponent(hit)
                if fm.isReadableFile(atPath: url.path) { return url }
            }
        }
        return nil
    }

    /// Cheap sanity check that what we fetched is actually a PDF and not an HTML error page
    /// served with 200 (arXiv does this for withdrawn papers). The spec allows junk before the
    /// header, so look for %PDF anywhere in the first KB.
    static func validatePDF(at url: URL) throws {
        guard let handle = try? FileHandle(forReadingFrom: url),
              let head = try? handle.read(upToCount: 1024),
              head.range(of: Data("%PDF".utf8)) != nil
        else { throw RemoteDocumentError.notPDF }
        try? handle.close()
    }

    /// Move a validated download into the library under its final name.
    static func land(tempFile: URL, source: RemoteDocumentURL, title: String?,
                     in root: URL = AppPaths.remoteLibraryDirectory) throws -> URL {
        let base = sanitizedBaseName(title ?? source.fallbackName)
        let name = "\(base) [\(source.dedupToken)].pdf"
        let dest = directory(for: source.subdirectory, in: root).appendingPathComponent(name)
        let fm = FileManager.default
        if fm.fileExists(atPath: dest.path) {
            try fm.removeItem(at: dest)
        }
        try fm.moveItem(at: tempFile, to: dest)
        return dest
    }

    /// Paper titles become filenames (visible in the bookshelf, tab titles, Finder) — strip
    /// filesystem-hostile characters, collapse whitespace, cap the length.
    static func sanitizedBaseName(_ raw: String) -> String {
        var s = raw
            .components(separatedBy: CharacterSet(charactersIn: "/\\:?%*|\"<>#"))
            .joined(separator: " ")
        s = s.components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        if s.count > 100 {
            s = String(s.prefix(100)).trimmingCharacters(in: .whitespaces)
        }
        // APFS caps a name at 255 UTF-8 bytes, and 100 CJK characters are 300 — leave room for
        // the " [token].pdf" suffix or the final move into the library fails.
        while s.utf8.count > 180 {
            s.removeLast()
        }
        s = s.trimmingCharacters(in: .whitespaces)
        return s.isEmpty ? "document" : s
    }

    /// Vets a page title handed over by the browser extension (`pdflite://open?…&title=`).
    /// It is untrusted page text: returns nil unless it is safe and plausible enough to name a
    /// file after — the caller then falls back to the arXiv API / URL-derived name. Survivors
    /// have already been through `sanitizedBaseName`, so nothing here can reach the path.
    static func sanitizedDeepLinkTitle(_ raw: String?) -> String? {
        guard let raw else { return nil }
        // Control / format characters (NUL, bidi overrides…) break file operations or make names
        // lie about themselves in Finder and tab strips. Tabs and newlines are whitespace —
        // kept so sanitizedBaseName collapses them to a space instead of gluing words together.
        let cleaned = String(String.UnicodeScalarView(raw.unicodeScalars.filter { scalar in
            CharacterSet.whitespacesAndNewlines.contains(scalar)
                || !CharacterSet.controlCharacters.contains(scalar)
        }))
        var title = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        // arXiv tab titles read "[2510.26692] Real Title" — the bracketed id is already the
        // dedup token in the file name. Other leading brackets ("[Survey] …") are part of the title.
        title = title.replacing(
            #/^\[\s*(?:arxiv:\s*)?(?:\d{4}\.\d{4,5}|[a-z][a-z.-]*\/\d{7})(?:v\d+)?\s*\]\s*/#.ignoresCase(),
            with: "")
        guard !title.isEmpty else { return nil }

        // A title that is really a file name, an identifier or a URL says nothing about the paper.
        let noSpaces = !title.contains(where: \.isWhitespace)
        if noSpaces {
            if title.wholeMatch(of: #/(?i)[^\s]+\.(pdf|tex|dvi|docx?|html?|ps)/#) != nil { return nil }
            if title.allSatisfy({ $0.isHexDigit || ".-_:".contains($0) || $0 == "v" || $0 == "V" }) { return nil }
        }
        if RemoteDocumentURL.parse(title)?.arxivID != nil { return nil }
        if title.contains("://") || title.lowercased().hasPrefix("www.") { return nil }

        let name = sanitizedBaseName(title).drop(while: { $0 == "." || $0 == " " })
        guard name.count >= 4, name.contains(where: \.isLetter) else { return nil }
        return String(name)
    }

    /// Human-facing name for a landed file: the landing scheme's " [token]" suffix is a dedup key,
    /// not part of the title. Drops it when the token is a 10-hex web token (pure noise) or when
    /// it merely repeats the whole name ("2504.09014 [2504.09014]"); keeps arXiv-style suffixes
    /// when the name differs — "Title [2603.15031]" carries a useful citation id.
    /// `fileName` may include the ".pdf" extension; other dots are left alone.
    static func displayName(forFileName fileName: String) -> String {
        var base = fileName
        if base.lowercased().hasSuffix(".pdf") { base.removeLast(4) }
        guard let match = base.wholeMatch(of: #/(?<name>.*\S)\s+\[(?<token>[^\]]+)\]/#) else {
            return base
        }
        let name = String(match.output.name)
        let token = String(match.output.token)
        let isWebToken = token.count == 10 && token.allSatisfy { $0.isASCII && $0.isHexDigit }
        return isWebToken || token == name ? name : base
    }
}

/// One-shot PDF download with progress. Cancellation flows from the owning Task straight into
/// the URLSession task, so an abandoned download stops moving bytes immediately.
final class RemoteDocumentDownloader: NSObject, @unchecked Sendable {
    private let logger = Logger(subsystem: "com.pdflite.app", category: "RemoteDownload")
    private var task: URLSessionDownloadTask?
    private var progressObservation: NSKeyValueObservation?
    /// Where the request ended up after redirects — set before `download` returns, so callers
    /// can re-route when a short link resolved to a paper's landing page.
    private(set) var finalURL: URL?

    /// Downloads to a private temp file and returns its URL. `progress` reports 0…1, or nil
    /// while the server hasn't declared a Content-Length.
    func download(from url: URL,
                  progress: @escaping @Sendable (Double?) -> Void) async throws -> URL {
        try Task.checkCancellation()

        var request = URLRequest(url: url)
        request.timeoutInterval = 60
        request.setValue("PDFLite/0.2 (personal PDF reader)", forHTTPHeaderField: "User-Agent")

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let task = URLSession.shared.downloadTask(with: request) { tempURL, response, error in
                    if let error {
                        if (error as? URLError)?.code == .cancelled {
                            continuation.resume(throwing: CancellationError())
                        } else {
                            continuation.resume(throwing: error)
                        }
                        return
                    }
                    guard let tempURL, let http = response as? HTTPURLResponse else {
                        continuation.resume(throwing: URLError(.badServerResponse))
                        return
                    }
                    guard http.statusCode == 200 else {
                        continuation.resume(throwing: RemoteDocumentError.badStatus(http.statusCode))
                        return
                    }
                    self.finalURL = http.url
                    // The system deletes tempURL when this handler returns — move it out now.
                    do {
                        let held = FileManager.default.temporaryDirectory
                            .appendingPathComponent("pdflite-download-\(UUID().uuidString).pdf")
                        try FileManager.default.moveItem(at: tempURL, to: held)
                        continuation.resume(returning: held)
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
                self.task = task
                self.progressObservation = task.progress.observe(\.fractionCompleted) { p, _ in
                    progress(p.isIndeterminate ? nil : p.fractionCompleted)
                }
                task.resume()
            }
        } onCancel: {
            self.task?.cancel()
        }
    }
}

/// The whole "URL → file in the library" pipeline, minus queueing and UI: download (racing the
/// arXiv title fetch), validate, land. If the URL turns out to be a redirect to an HTML page that
/// normalizes to a real PDF (t.co → arxiv.org/abs/…), retries once against the normalized source.
enum RemoteDocumentFetch {
    /// `suppliedTitle` is an already-vetted page title (deep link `title=`); when present it names
    /// the file and the arXiv API is not consulted.
    static func downloadAndLand(source initial: RemoteDocumentURL,
                                suppliedTitle: String?,
                                in root: URL = AppPaths.remoteLibraryDirectory,
                                progress: @escaping @Sendable (Double?) -> Void) async throws -> URL {
        var source = initial
        var retried = false
        while true {
            // The title fetch races the download; both are usually done within a couple of
            // seconds and a failed fetch just means the file keeps its arXiv id as its name.
            let arxivID = suppliedTitle == nil ? source.arxivID : nil
            async let fetchedTitle = title(arxivID: arxivID, supplied: suppliedTitle)

            let downloader = RemoteDocumentDownloader()
            let tempFile = try await downloader.download(from: source.downloadURL, progress: progress)
            do {
                try RemoteDocumentLibrary.validatePDF(at: tempFile)
            } catch {
                try? FileManager.default.removeItem(at: tempFile)
                if !retried, let final = downloader.finalURL,
                   let next = RemoteDocumentURL.redirectRetry(requested: source, finalURL: final) {
                    retried = true
                    source = next
                    continue
                }
                throw error
            }
            return try RemoteDocumentLibrary.land(tempFile: tempFile, source: source,
                                                  title: await fetchedTitle, in: root)
        }
    }

    private static func title(arxivID: String?, supplied: String?) async -> String? {
        if let supplied { return supplied }
        guard let arxivID else { return nil }
        return await ArxivMetadataClient.fetchTitle(id: arxivID)
    }
}
