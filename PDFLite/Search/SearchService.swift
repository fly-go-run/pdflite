import AppKit
import Observation
import PDFKit

@MainActor
@Observable
final class SearchService {
    var query: String = ""
    @ObservationIgnored var onNavigate: ((PDFSelection) -> Void)?
    @ObservationIgnored var onClear: (() -> Void)?
    private(set) var results: [PDFSelection] = []
    private(set) var currentIndex: Int = 0
    private(set) var isSearching: Bool = false
    private(set) var navigationRevision: Int = 0
    /// Bumped whenever `results` itself changes (new search, batch flush, clear). The bridge
    /// layer uses it to skip re-tinting hundreds of selections on unrelated updateNSView passes.
    private(set) var resultsRevision: Int = 0
    /// The query `results` belong to (set when a find starts, nil after `clear()`). `query` is the
    /// live text field and runs ahead of it while the user is typing.
    private(set) var searchedQuery: String?

    @ObservationIgnored private var debounceTask: Task<Void, Never>?
    @ObservationIgnored private weak var findingDocument: PDFDocument?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var pendingMatches: [PDFSelection] = []

    var hasResults: Bool { !results.isEmpty }
    var totalResults: Int { results.count }
    var currentNumber: Int { hasResults ? currentIndex + 1 : 0 }

    /// Debounced entry point for live typing. Waits for the input to settle before kicking off
    /// the find, so large documents aren't re-searched on every keystroke.
    func scheduleSearch(in document: PDFDocument) {
        debounceTask?.cancel()
        debounceTask = Task { [weak self, weak document] in
            try? await Task.sleep(for: .milliseconds(250))
            if Task.isCancelled { return }
            guard let self, let document else { return }
            self.search(in: document)
        }
    }

    /// Return / ⇧Return in the search field, following Safari and Preview: with results already
    /// on hand for exactly this query it steps to the next / previous match (wrapping), instead
    /// of re-running the find — which would clear the results and snap back to match 1. A changed
    /// query (typed but not yet debounced) or an empty result set starts a fresh search.
    func submit(in document: PDFDocument, backwards: Bool = false) {
        guard hasResults, searchedQuery == query else {
            search(in: document)
            return
        }
        if backwards { previous() } else { next() }
    }

    /// Incremental async find via PDFDocument.beginFindString. Matches stream in on the main
    /// queue as they're found; the first match lands immediately (so jump-to-first feels
    /// instant) and the rest flush in batches to keep UI invalidation cheap.
    func search(in document: PDFDocument) {
        debounceTask?.cancel()
        cancelOngoingFind()

        let q = query
        guard !q.isEmpty else {
            clear()
            return
        }

        isSearching = true
        searchedQuery = q
        results = []
        pendingMatches = []
        currentIndex = 0
        navigationRevision += 1
        resultsRevision += 1
        findingDocument = document

        let center = NotificationCenter.default
        observers.append(center.addObserver(
            forName: .PDFDocumentDidFindMatch, object: document, queue: .main
        ) { [weak self] note in
            // Delivered on the main queue (queue: .main); assumeIsolated is safe, and the
            // selection never actually crosses threads.
            nonisolated(unsafe) let payload = note.userInfo?["PDFDocumentFoundSelection"] as? PDFSelection
            MainActor.assumeIsolated {
                guard let selection = payload else { return }
                self?.appendMatch(selection)
            }
        })
        observers.append(center.addObserver(
            forName: .PDFDocumentDidEndFind, object: document, queue: .main
        ) { [weak self, weak document] _ in
            MainActor.assumeIsolated {
                // A cancelled previous find can post DidEndFind after the next one has started;
                // ignore it while the document is still finding.
                if document?.isFinding == true { return }
                self?.finishFind()
            }
        })

        document.beginFindString(q, withOptions: .caseInsensitive)
    }

    func next() {
        guard !results.isEmpty else { return }
        currentIndex = (currentIndex + 1) % results.count
        navigationRevision += 1
        if let current = currentSelection() { onNavigate?(current) }
    }

    func previous() {
        guard !results.isEmpty else { return }
        currentIndex = (currentIndex - 1 + results.count) % results.count
        navigationRevision += 1
        if let current = currentSelection() { onNavigate?(current) }
    }

    func clear() {
        onClear?()
        debounceTask?.cancel()
        cancelOngoingFind()
        query = ""
        searchedQuery = nil
        results = []
        currentIndex = 0
        navigationRevision += 1
        resultsRevision += 1
    }

    func currentSelection() -> PDFSelection? {
        guard currentIndex < results.count else { return nil }
        return results[currentIndex]
    }

    // MARK: - Incremental find plumbing

    private func appendMatch(_ selection: PDFSelection) {
        pendingMatches.append(selection)
        // First match flushes immediately; after that, batch so hundreds of matches don't
        // trigger hundreds of observable updates.
        if results.isEmpty || pendingMatches.count >= 25 {
            flushPendingMatches()
        }
    }

    private func flushPendingMatches() {
        guard !pendingMatches.isEmpty else { return }
        let isFirstFlush = results.isEmpty
        results.append(contentsOf: pendingMatches)
        pendingMatches = []
        resultsRevision += 1
        if isFirstFlush {
            currentIndex = 0
            navigationRevision += 1
            if let current = currentSelection() { onNavigate?(current) }
        }
    }

    private func finishFind() {
        flushPendingMatches()
        isSearching = false
        removeObservers()
        findingDocument = nil
    }

    private func cancelOngoingFind() {
        if let findingDocument, findingDocument.isFinding {
            findingDocument.cancelFindString()
        }
        removeObservers()
        pendingMatches = []
        findingDocument = nil
        isSearching = false
    }

    private func removeObservers() {
        for token in observers {
            NotificationCenter.default.removeObserver(token)
        }
        observers = []
    }
}
