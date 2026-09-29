import CryptoKit
import Foundation

/// A user-supplied "open this from the internet" input, normalized to something downloadable.
/// arXiv gets special treatment because the same paper hides behind many spellings — abs/pdf/html
/// pages, versioned ids, bare ids, `arXiv:` prefixes — and they must all dedup to one file.
enum RemoteDocumentURL: Equatable {
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

        // Mirrors that carry the arXiv id in their own path — treat as arXiv so they get the
        // canonical PDF, the API title and the same dedup token as every other spelling.
        if let id = arxivID(fromMirrorURL: url) {
            return .arxiv(id: id)
        }

        return .web(normalizedWebURL(url))
    }

    /// The download redirected somewhere that normalizes to a different PDF URL than the one we
    /// fetched (t.co → arxiv.org/abs/…). Returns the source to retry with, or nil when the
    /// final URL teaches us nothing new — i.e. it is the URL we already got HTML from.
    static func redirectRetry(requested: RemoteDocumentURL, finalURL: URL) -> RemoteDocumentURL? {
        guard let next = parse(finalURL.absoluteString),
              next.downloadURL.absoluteString != requested.downloadURL.absoluteString,
              next.downloadURL.absoluteString != finalURL.absoluteString
        else { return nil }
        return next
    }

    /// Hosts whose PDFs are known to be served over https. Plain-http spellings (PMLR's own
    /// abstract pages link `http://…pdf`) are upgraded so both collapse to one dedup token.
    private static let httpsUpgradeHosts: Set<String> = [
        "aclanthology.org", "proceedings.mlr.press", "openaccess.thecvf.com",
        "papers.nips.cc", "proceedings.neurips.cc",
    ]

    /// PMLR switched from `/vN/<name>.pdf` to `/vN/<name>/<name>.pdf` at volume 54 (verified:
    /// v28–v53 flat, v54 onward nested). Abstract pages are always `/vN/<name>.html`.
    private static let pmlrFirstNestedVolume = 54

    /// Site-specific rewrites for URLs that are an HTML wrapper around the actual PDF bytes.
    /// Applied before download AND before the dedup token is computed, so wrapper and direct
    /// spellings of the same file collapse to one library entry. Every paper-site rule below was
    /// checked against real papers with header-only requests (the rewritten URL answers
    /// application/pdf); sites that gate PDFs behind bot challenges (OpenReview, bioRxiv/medRxiv)
    /// are deliberately not rewritten because the result could not be verified — or downloaded.
    private static func normalizedWebURL(_ original: URL) -> URL {
        guard let host = original.host?.lowercased() else { return original }
        var url = original
        if httpsUpgradeHosts.contains(host), url.scheme?.lowercased() == "http",
           var comps = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            comps.scheme = "https"
            comps.port = nil
            url = comps.url ?? url
        }
        let parts = url.path.split(separator: "/").map(String.init)

        func https(_ path: String) -> URL? {
            var comps = URLComponents()
            comps.scheme = "https"
            comps.host = host
            comps.path = path
            return comps.url
        }

        switch host {
        case "github.com", "www.github.com":
            // GitHub blob pages (github.com/{owner}/{repo}/blob/{ref}/{path}) serve an HTML
            // viewer; the file itself lives on raw.githubusercontent.com/{owner}/{repo}/{ref}/{path}.
            // The /raw/ spelling is normalized the same way (it 302s there anyway).
            if parts.count >= 5, parts[2] == "blob" || parts[2] == "raw" {
                var comps = URLComponents()
                comps.scheme = "https"
                comps.host = "raw.githubusercontent.com"
                comps.path = "/" + ([parts[0], parts[1]] + parts[3...]).joined(separator: "/")
                if let raw = comps.url { return raw }
            }

        case "aclanthology.org":
            // Paper page /<id>/ → /<id>.pdf. Volume pages ("2020.acl-main") have no paper
            // number and are left alone.
            if parts.count == 1, isACLPaperID(parts[0]), let pdf = https("/\(parts[0]).pdf") {
                return pdf
            }

        case "proceedings.mlr.press":
            if parts.count == 2, parts[0].hasPrefix("v"), let volume = Int(parts[0].dropFirst()),
               parts[1].hasSuffix(".html") {
                let name = String(parts[1].dropLast(".html".count))
                if !name.isEmpty, name.allSatisfy({ $0.isLetter || $0.isNumber || "._-".contains($0) }) {
                    let path = volume >= pmlrFirstNestedVolume
                        ? "/\(parts[0])/\(name)/\(name).pdf"
                        : "/\(parts[0])/\(name).pdf"
                    if let pdf = https(path) { return pdf }
                }
            }

        case "openaccess.thecvf.com":
            // .../html/<Name>_paper.html → .../papers/<Name>_paper.pdf (both the
            // /content/CVPR2023/ and the older /content_cvpr_2016/ layouts).
            if parts.count >= 3, parts[parts.count - 2] == "html",
               let last = parts.last, last.hasSuffix(".html") {
                var rewritten = parts
                rewritten[rewritten.count - 2] = "papers"
                rewritten[rewritten.count - 1] = String(last.dropLast(".html".count)) + ".pdf"
                if let pdf = https("/" + rewritten.joined(separator: "/")) { return pdf }
            }

        case "papers.nips.cc", "proceedings.neurips.cc":
            // .../hash/<md5>-Abstract[-Conference|-Datasets_and_Benchmarks…].html
            //   → .../file/<md5>-Paper[-Conference|…].pdf
            if parts.count >= 2, parts[parts.count - 2] == "hash",
               let last = parts.last, last.hasSuffix(".html"), last.contains("-Abstract") {
                var rewritten = parts
                rewritten[rewritten.count - 2] = "file"
                rewritten[rewritten.count - 1] = String(last.dropLast(".html".count))
                    .replacingOccurrences(of: "-Abstract", with: "-Paper") + ".pdf"
                if let pdf = https("/" + rewritten.joined(separator: "/")) { return pdf }
            }

        default:
            break
        }

        return url
    }

    /// huggingface.co/papers/<id> and alphaxiv.org/{abs,overview}/<id> are pages *about* an
    /// arXiv paper; the id is right in the path.
    private static func arxivID(fromMirrorURL url: URL) -> String? {
        guard var host = url.host?.lowercased() else { return nil }
        if host.hasPrefix("www.") { host.removeFirst(4) }
        let parts = url.path.split(separator: "/").map(String.init)
        guard parts.count == 2 else { return nil }
        switch host {
        case "huggingface.co" where parts[0] == "papers",
             "alphaxiv.org" where ["abs", "overview"].contains(parts[0]):
            return isValidArxivID(parts[1]) ? parts[1] : nil
        default:
            return nil
        }
    }

    /// ACL Anthology paper ids: "2020.acl-main.747" / "2023.findings-emnlp.12" (new) and
    /// "P19-1001" / "W19-5301" (pre-2020), optionally versioned.
    private static func isACLPaperID(_ id: String) -> Bool {
        let newStyle = #/^\d{4}\.[a-z0-9-]+\.\d+(v\d+)?$/#
        let oldStyle = #/^[A-Z]\d{2}-\d{1,4}(v\d+)?$/#
        return id.wholeMatch(of: newStyle) != nil || id.wholeMatch(of: oldStyle) != nil
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
