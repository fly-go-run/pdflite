import AppKit
import Observation
import PDFKit

@MainActor
@Observable
final class SearchService {
    var query: String = ""
    private(set) var results: [PDFSelection] = []
    private(set) var currentIndex: Int = 0
    private(set) var isSearching: Bool = false
    private(set) var navigationRevision: Int = 0

    var hasResults: Bool { !results.isEmpty }
    var totalResults: Int { results.count }
    var currentNumber: Int { hasResults ? currentIndex + 1 : 0 }

    /// Synchronous on the main actor — fast enough for typical paper PDFs. If we ever need to
    /// search huge documents without blocking, switch to PDFDocument.beginFindString and
    /// PDFDocumentDelegate.didMatchString.
    func search(in document: PDFDocument) {
        let q = query
        guard !q.isEmpty else {
            clear()
            return
        }
        isSearching = true
        let found = document.findString(q, withOptions: .caseInsensitive)
        results = found
        currentIndex = 0
        isSearching = false
        navigationRevision += 1
    }

    func next() {
        guard !results.isEmpty else { return }
        currentIndex = (currentIndex + 1) % results.count
        navigationRevision += 1
    }

    func previous() {
        guard !results.isEmpty else { return }
        currentIndex = (currentIndex - 1 + results.count) % results.count
        navigationRevision += 1
    }

    func clear() {
        query = ""
        results = []
        currentIndex = 0
        isSearching = false
        navigationRevision += 1
    }

    func currentSelection() -> PDFSelection? {
        guard currentIndex < results.count else { return nil }
        return results[currentIndex]
    }
}
