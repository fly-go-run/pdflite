import Foundation
import os.log

/// Fetches a paper's title from the arXiv Atom API so the downloaded file can be named after
/// the paper instead of its number. Best-effort: any failure (offline, timeout, odd XML) just
/// returns nil and the caller falls back to the arXiv id.
enum ArxivMetadataClient {
    private static let logger = Logger(subsystem: "com.pdflite.app", category: "ArxivMetadata")

    static func fetchTitle(id: String) async -> String? {
        var components = URLComponents(string: "https://export.arxiv.org/api/query")!
        components.queryItems = [URLQueryItem(name: "id_list", value: id)]
        guard let url = components.url else { return nil }

        var request = URLRequest(url: url)
        request.timeoutInterval = 6

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                logger.error("metadata query for \(id, privacy: .public) got HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1)")
                return nil
            }
            let title = AtomEntryTitleParser.firstEntryTitle(in: data)
            if title == nil {
                logger.error("metadata query for \(id, privacy: .public): no title in \(data.count) bytes of Atom")
            }
            return title
        } catch {
            logger.error("metadata query for \(id, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }
}

/// Minimal Atom parser: the feed's own <title> is "ArXiv Query: …", the paper's title is the
/// first <title> nested inside an <entry>.
private final class AtomEntryTitleParser: NSObject, XMLParserDelegate {
    private var insideEntry = false
    private var insideEntryTitle = false
    private var buffer = ""
    private(set) var result: String?

    static func firstEntryTitle(in data: Data) -> String? {
        let delegate = AtomEntryTitleParser()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.parse() // returns false after abortParsing() — the early-exit, not an error
        return delegate.result
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName: String?,
                attributes: [String: String] = [:]) {
        if elementName == "entry" {
            insideEntry = true
        } else if elementName == "title", insideEntry {
            insideEntryTitle = true
            buffer = ""
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if insideEntryTitle { buffer += string }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String,
                namespaceURI: String?, qualifiedName: String?) {
        if elementName == "title", insideEntryTitle {
            insideEntryTitle = false
            let collapsed = buffer
                .components(separatedBy: .whitespacesAndNewlines)
                .filter { !$0.isEmpty }
                .joined(separator: " ")
            if !collapsed.isEmpty {
                result = collapsed
                parser.abortParsing()
            }
        } else if elementName == "entry" {
            insideEntry = false
        }
    }
}
