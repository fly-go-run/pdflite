import CryptoKit
import Foundation

/// A user-supplied "open this from the internet" input, normalized to something downloadable.
/// arXiv gets special treatment because the same paper hides behind many spellings — abs/pdf/html
/// pages, versioned ids, bare ids, `arXiv:` prefixes — and they must all dedup to one file.
enum RemoteDocumentURL {
    case arxiv(id: String)
    case web(URL)

    /// The URL we actually download. arXiv always goes through the canonical /pdf/ endpoint.
    var downloadURL: URL {
        switch self {
        case .arxiv(let id):
            return URL(string: "https://arxiv.org/pdf/\(id)")!
        case .web(let url):
            return url
        }
    }

    /// Filesystem-safe identity token embedded in the landed filename as `… [token].pdf`.
    /// Re-opening any spelling of the same source finds the existing file by this suffix,
    /// so dedup needs no database. Old-style arXiv ids contain "/" — mapped to "-".
    var dedupToken: String {
        switch self {
        case .arxiv(let id):
            return id.replacingOccurrences(of: "/", with: "-")
        case .web(let url):
            var comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
            comps?.fragment = nil
            let canonical = comps?.string ?? url.absoluteString
            let digest = SHA256.hash(data: Data(canonical.utf8))
            return String(digest.map { String(format: "%02x", $0) }.joined().prefix(10))
        }
    }

    /// Subdirectory under the download library this file lands in.
    var subdirectory: String {
        switch self {
        case .arxiv: return "arxiv"
        case .web: return "web"
        }
    }

    var arxivID: String? {
        if case .arxiv(let id) = self { return id }
        return nil
    }

    /// Display name used when no better title is available (metadata fetch failed / non-arXiv).
    var fallbackName: String {
        switch self {
        case .arxiv(let id):
            return id.replacingOccurrences(of: "/", with: "-")
        case .web(let url):
            let last = url.deletingPathExtension().lastPathComponent
                .removingPercentEncoding ?? ""
            if last.count >= 3, last != "/" { return last }
            return url.host ?? "document"
        }
    }

    // MARK: - Parsing

    /// Accepts: arXiv abs/pdf/html URLs, bare ids ("2510.26692v2", "arXiv:2510.26692",
    /// "cs.CL/0301012"), and any other http(s) URL (assumed to point at a PDF; verified after
    /// download). Returns nil for anything unrecognizable — including arxiv.org pages that
    /// aren't a specific paper.
    static func parse(_ raw: String) -> RemoteDocumentURL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let id = parseBareArxivID(trimmed) {
            return .arxiv(id: id)
        }

        guard let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              url.host != nil
        else { return nil }

        if let host = url.host?.lowercased(),
           host == "arxiv.org" || host.hasSuffix(".arxiv.org") {
            guard let id = arxivID(fromPath: url.path) else { return nil }
            return .arxiv(id: id)
        }

        return .web(normalizedWebURL(url))
    }

    /// Site-specific rewrites for URLs that are an HTML wrapper around the actual PDF bytes.
    /// Applied before download AND before the dedup token is computed, so wrapper and direct
    /// spellings of the same file collapse to one library entry.
    private static func normalizedWebURL(_ url: URL) -> URL {
        guard let host = url.host?.lowercased() else { return url }

        // GitHub blob pages (github.com/{owner}/{repo}/blob/{ref}/{path}) serve an HTML viewer;
        // the file itself lives on raw.githubusercontent.com/{owner}/{repo}/{ref}/{path}.
        // The /raw/ spelling is normalized the same way (it 302s there anyway).
        if host == "github.com" || host == "www.github.com" {
            let parts = url.path.split(separator: "/").map(String.init)
            if parts.count >= 5, parts[2] == "blob" || parts[2] == "raw" {
                var comps = URLComponents()
                comps.scheme = "https"
                comps.host = "raw.githubusercontent.com"
                comps.path = "/" + ([parts[0], parts[1]] + parts[3...]).joined(separator: "/")
                if let raw = comps.url { return raw }
            }
        }

        return url
    }

    private static func parseBareArxivID(_ text: String) -> String? {
        var candidate = text
        if candidate.lowercased().hasPrefix("arxiv:") {
            candidate = String(candidate.dropFirst("arxiv:".count))
                .trimmingCharacters(in: .whitespaces)
        }
        return isValidArxivID(candidate) ? candidate : nil
    }

    private static func arxivID(fromPath path: String) -> String? {
        let components = path.split(separator: "/").map(String.init)
        guard components.count >= 2,
              ["abs", "pdf", "html"].contains(components[0].lowercased())
        else { return nil }

        // Old-style ids ("cs.CL/0301012") span two path components — rejoin everything.
        var id = components.dropFirst().joined(separator: "/")
        if id.lowercased().hasSuffix(".pdf") {
            id = String(id.dropLast(4))
        }
        return isValidArxivID(id) ? id : nil
    }

    private static func isValidArxivID(_ id: String) -> Bool {
        // New style: 2510.26692 / 2510.26692v3. Old style: cs.CL/0301012 / math.GT/0309136v2.
        let newStyle = #/^\d{4}\.\d{4,5}(v\d+)?$/#
        let oldStyle = #/^[a-zA-Z][a-zA-Z.-]*/\d{7}(v\d+)?$/#
        return id.wholeMatch(of: newStyle) != nil || id.wholeMatch(of: oldStyle) != nil
    }
}
