import AppKit
import PDFKit

/// Keeps a PDFView's search highlighting in step with `SearchService` doing only the work each
/// change needs. The bridge used to recolour every result and re-assign `highlightedSelections`
/// on every result flush and every ⌘G — O(n²) over a streaming find. The rules now:
///
/// - A flush tints only the results that appeared since the last pass (`SearchService` only
///   appends within an epoch), so each selection is coloured once, and re-assigns
///   `highlightedSelections` once for that flush. The assignment is PDFKit's expensive step.
/// - Navigation recolours just the previous and the new current match and never re-assigns
///   `highlightedSelections`: PDFKit reads `PDFSelection.color` when it draws, and
///   `setCurrentSelection` / `go(to:)` (DocumentSession.navigateSearchResult) already make it
///   repaint the match being stepped to.
///
/// The decision is a plain value type so it can be tested without a window.
/// https://developer.apple.com/documentation/pdfkit/pdfview/highlightedselections
/// https://developer.apple.com/documentation/pdfkit/pdfselection/color
struct SearchTintPlanner {
    struct Recolor: Equatable {
        let index: Int
        let isCurrent: Bool
    }

    struct Plan: Equatable {
        /// `highlightedSelections = nil`: there are no results any more.
        var clear = false
        /// Results that appeared since the last pass; they get the normal match colour.
        var tint: Range<Int> = 0..<0
        /// Individual recolours after navigation (old current back to normal, new current).
        /// Applied after `tint`, so a fresh result can be both tinted and made current.
        var recolor: [Recolor] = []
        /// The result set changed: assign `highlightedSelections`. Never true for navigation.
        var reassign = false

        var isEmpty: Bool { !clear && tint.isEmpty && recolor.isEmpty && !reassign }
    }

    private var appliedEpoch: Int?
    private var appliedRevision: Int?
    private var tintedCount = 0
    private var tintedCurrent: Int?
    private var installed = false

    mutating func plan(epoch: Int, resultsRevision: Int, count: Int, currentIndex: Int) -> Plan {
        guard count > 0 else {
            defer {
                appliedEpoch = epoch
                appliedRevision = resultsRevision
                tintedCount = 0
                tintedCurrent = nil
                installed = false
            }
            return Plan(clear: installed)
        }

        var plan = Plan()
        if appliedEpoch != epoch {
            // A different result set: its selections are fresh objects, nothing carries over.
            tintedCount = 0
            tintedCurrent = nil
        }
        if appliedEpoch != epoch || appliedRevision != resultsRevision || !installed {
            plan.tint = tintedCount..<count
            plan.reassign = true
            tintedCount = count
            installed = true
        }
        appliedEpoch = epoch
        appliedRevision = resultsRevision

        let wanted = (0..<count).contains(currentIndex) ? currentIndex : nil
        if wanted != tintedCurrent {
            if let old = tintedCurrent, old < count {
                plan.recolor.append(Recolor(index: old, isCurrent: false))
            }
            if let wanted {
                plan.recolor.append(Recolor(index: wanted, isCurrent: true))
            }
            tintedCurrent = wanted
        }
        return plan
    }

    /// Plans against `search`'s current state and applies the result to `view`. Called from
    /// `updateNSView`, so it must stay O(1) when nothing search-related changed.
    @MainActor
    mutating func sync(with search: SearchService, to view: PDFView) {
        let results = search.results
        let plan = plan(epoch: search.resultsEpoch,
                        resultsRevision: search.resultsRevision,
                        count: results.count,
                        currentIndex: search.currentIndex)
        if plan.clear {
            view.highlightedSelections = nil
            return
        }
        for index in plan.tint { results[index].color = .yellow }
        for change in plan.recolor { results[change.index].color = change.isCurrent ? .orange : .yellow }
        if plan.reassign { view.highlightedSelections = results }
    }
}
