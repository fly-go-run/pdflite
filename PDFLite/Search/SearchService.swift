import AppKit
import Observation
import PDFKit

@MainActor
@Observable
final class SearchService {
    /// Most matches stored and navigable; past this the find is cancelled and `isCapped` is set.
    /// Why cap: assigning `PDFView.highlightedSelections` is the expensive part of showing
    /// results (one assignment on a single very dense page took ~11 ms for 100 selections,
    /// ~270 ms for 500, ~1 s for 700+), and a common word ("the", "of") in a long paper gives
    /// 10k-20k matches, which used to stall the main thread while the find streamed in. 2000
    /// still covers every match of any term worth stepping through; beyond it ⌘G-ing one by one
    /// is hopeless and the fix is a more specific query, which the "2000+" counter says.
    /// Trade-off: for a capped query the matches past the 2000th (in document order) are
    /// neither highlighted nor reachable.
    static let resultLimit = 2000

    /// Streaming flush policy: hold matches back until the batch has doubled the list (never
    /// under `minFlushBatch`) AND at least `minFlushInterval` has passed since the last flush.
    /// Each flush costs the bridge one `highlightedSelections` re-assignment (see above), so
    /// this keeps the flush count O(log n) — at most ~9 up to the cap instead of 80 at a fixed
    /// batch of 25 — and at most ~8 a second; a find that finishes within one interval (the
    /// usual case) publishes just the first match and the final list. The very first match
    /// still flushes immediately so jump-to-first stays instant, and the end of the find
    /// (or hitting the cap) always flushes what is left, so the final list is exact.
    static let minFlushBatch = 25
    static let minFlushInterval: Duration = .milliseconds(120)

    var query: String = ""
    @ObservationIgnored var onNavigate: ((PDFSelection) -> Void)?
    @ObservationIgnored var onClear: (() -> Void)?
    private(set) var results: [PDFSelection] = []
    private(set) var currentIndex: Int = 0
    private(set) var isSearching: Bool = false
    /// True when more than `resultLimit` matches exist: `results` holds the first `resultLimit`
    /// and the find was cancelled. False for any result set that fit, including exactly the limit.
    private(set) var isCapped: Bool = false
    /// Bumped whenever `results` itself changes (new search, batch flush, clear). The bridge
    /// layer uses it to skip re-tinting on unrelated updateNSView passes.
    private(set) var resultsRevision: Int = 0
    /// Bumped whenever `results` is *replaced* (new search, clear). Within one epoch `results`
    /// only ever grows by appending, which is what lets the bridge tint just the new tail
    /// instead of everything on each flush (see `SearchTintPlanner`).
    private(set) var resultsEpoch: Int = 0
    /// The query `results` belong to (set when a find starts, nil after `clear()`). `query` is the
    /// live text field and runs ahead of it while the user is typing.
    private(set) var searchedQuery: String?

    /// Test seam: how many times streamed matches were published to `results`.
    @ObservationIgnored private(set) var flushCount: Int = 0
    /// Identifies the current find. Observer blocks capture it and ignore notifications from an
    /// older find: block observers on `.main` are queued when PDFKit posts, so a block that was
    /// already queued when a find was cancelled still runs after the observer is removed.
    @ObservationIgnored private(set) var findGeneration: Int = 0
    /// Per-instance so tests can exercise the cap without a 2000-match PDF.
    @ObservationIgnored let resultLimit: Int

    @ObservationIgnored private var debounceTask: Task<Void, Never>?
    @ObservationIgnored private weak var findingDocument: PDFDocument?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var pendingMatches: [PDFSelection] = []
    @ObservationIgnored private var lastFlushAt: ContinuousClock.Instant?

    init(resultLimit: Int = SearchService.resultLimit) {
        self.resultLimit = max(1, resultLimit)
    }

    var hasResults: Bool { !results.isEmpty }
    var totalResults: Int { results.count }
    var currentNumber: Int { hasResults ? currentIndex + 1 : 0 }
    /// The total as shown next to the current number: "2000+" once the list was cut off.
    var totalResultsLabel: String { isCapped ? "\(totalResults)+" : "\(totalResults)" }

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

    /// Incremental async find via PDFDocument.beginFindString
    /// (https://developer.apple.com/documentation/pdfkit/pdfdocument/beginfindstring(_:withoptions:)).
    /// Matches stream in on the main queue as they're found; the first match lands immediately
    /// (so jump-to-first feels instant) and the rest flush on a throttle (`shouldFlush`) to keep
    /// UI invalidation cheap. At most `resultLimit` matches are kept, then the find is cancelled.
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
        isCapped = false
        lastFlushAt = nil
        resultsEpoch += 1
        resultsRevision += 1
        findingDocument = document

        // cancelOngoingFind() advanced the generation, so this find owns the new value.
        let generation = findGeneration
        let center = NotificationCenter.default
        observers.append(center.addObserver(
            forName: .PDFDocumentDidFindMatch, object: document, queue: .main
        ) { [weak self] note in
            // Delivered on the main queue (queue: .main); assumeIsolated is safe, and the
            // selection never actually crosses threads.
            nonisolated(unsafe) let payload = note.userInfo?["PDFDocumentFoundSelection"] as? PDFSelection
            MainActor.assumeIsolated {
                guard let self, self.findGeneration == generation, let selection = payload else { return }
                self.appendMatch(selection)
            }
        })
        observers.append(center.addObserver(
            forName: .PDFDocumentDidEndFind, object: document, queue: .main
        ) { [weak self, weak document] _ in
            MainActor.assumeIsolated {
                self?.findDidEnd(generation: generation, documentIsFinding: document?.isFinding == true)
            }
        })

        document.beginFindString(q, withOptions: .caseInsensitive)
    }

    func next() {
        guard !results.isEmpty else { return }
        currentIndex = (currentIndex + 1) % results.count
        if let current = currentSelection() { onNavigate?(current) }
    }

    func previous() {
        guard !results.isEmpty else { return }
        currentIndex = (currentIndex - 1 + results.count) % results.count
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
        isCapped = false
        resultsEpoch += 1
        resultsRevision += 1
    }

    func currentSelection() -> PDFSelection? {
        guard currentIndex < results.count else { return nil }
        return results[currentIndex]
    }

    // MARK: - Incremental find plumbing

    /// Pure decision for "publish the pending batch now?", split out so the throttle is
    /// testable without a real find. See `minFlushBatch` / `minFlushInterval`.
    static func shouldFlush(pending: Int, delivered: Int, sinceLastFlush: Duration) -> Bool {
        if delivered == 0 { return pending > 0 }
        return pending >= max(minFlushBatch, delivered) && sinceLastFlush >= minFlushInterval
    }

    private func appendMatch(_ selection: PDFSelection) {
        // A match beyond the limit proves more exist: drop it, publish what is queued and stop
        // PDFKit scanning (cancelFindString may be called while servicing a find notification:
        // https://developer.apple.com/documentation/pdfkit/pdfdocument/cancelfindstring()).
        // Waiting for the (limit+1)th match, rather than stopping at the limit-th, keeps
        // `isCapped` exact: a query with exactly `resultLimit` matches is not capped.
        if results.count + pendingMatches.count >= resultLimit {
            isCapped = true
            flushPendingMatches()
            cancelOngoingFind()
            return
        }
        pendingMatches.append(selection)
        let sinceLast = lastFlushAt.map { ContinuousClock.now - $0 } ?? .zero
        if Self.shouldFlush(pending: pendingMatches.count, delivered: results.count, sinceLastFlush: sinceLast) {
            flushPendingMatches()
        }
    }

    private func flushPendingMatches() {
        guard !pendingMatches.isEmpty else { return }
        let isFirstFlush = results.isEmpty
        results.append(contentsOf: pendingMatches)
        pendingMatches = []
        lastFlushAt = .now
        flushCount += 1
        resultsRevision += 1
        if isFirstFlush {
            currentIndex = 0
            if let current = currentSelection() { onNavigate?(current) }
        }
    }

    /// DidEndFind handler, with the guards as parameters so tests can drive them directly.
    /// Ignored when it belongs to an older find, or while the document is still finding: a
    /// cancelled previous find can post DidEndFind after the next one has started.
    func findDidEnd(generation: Int, documentIsFinding: Bool) {
        guard generation == findGeneration, !documentIsFinding else { return }
        finishFind()
    }

    private func finishFind() {
        flushPendingMatches()
        isSearching = false
        removeObservers()
        findingDocument = nil
    }

    private func cancelOngoingFind() {
        findGeneration += 1
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
