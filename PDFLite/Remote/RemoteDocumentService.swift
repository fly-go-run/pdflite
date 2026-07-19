import Foundation
import os.log

enum RemoteDocumentError: LocalizedError {
    case badStatus(Int)
    case notPDF

    var errorDescription: String? {
        switch self {
        case .badStatus(let code):
            return "服务器返回了 HTTP \(code)。"
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

    static func directory(for subdirectory: String) -> URL {
        let dir = AppPaths.remoteLibraryDirectory
            .appendingPathComponent(subdirectory, isDirectory: true)
        let fm = FileManager.default
        if !fm.fileExists(atPath: dir.path) {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    /// Already downloaded from this source? Any spelling of the same source normalizes to the
    /// same token, so a suffix scan across the library answers "have we got this one".
    static func existingFile(token: String) -> URL? {
        let fm = FileManager.default
        let suffix = "[\(token)].pdf"
        for sub in subdirectories {
            let dir = AppPaths.remoteLibraryDirectory
                .appendingPathComponent(sub, isDirectory: true)
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
    static func land(tempFile: URL, source: RemoteDocumentURL, title: String?) throws -> URL {
        let base = sanitizedBaseName(title ?? source.fallbackName)
        let name = "\(base) [\(source.dedupToken)].pdf"
        let dest = directory(for: source.subdirectory).appendingPathComponent(name)
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
        return s.isEmpty ? "document" : s
    }
}

/// One-shot PDF download with progress. Cancellation flows from the owning Task straight into
/// the URLSession task, so an abandoned download stops moving bytes immediately.
final class RemoteDocumentDownloader: NSObject, @unchecked Sendable {
    private let logger = Logger(subsystem: "com.pdflite.app", category: "RemoteDownload")
    private var task: URLSessionDownloadTask?
    private var progressObservation: NSKeyValueObservation?

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
