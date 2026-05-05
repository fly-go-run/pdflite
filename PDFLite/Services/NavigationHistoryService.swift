import Foundation
import Observation

struct NavigationEntry: Sendable, Equatable {
    let pageIndex: Int
}

/// Per-session back/forward stack for "jump" actions (outline click, page input, search hit,
/// translation history "jump-back", etc). Continuous scrolling and next/previous page do NOT
/// pass through here — those are not user-perceived jumps. Back/forward themselves do not push
/// new entries; they swap entries between the two stacks so repeated Cmd-[ / Cmd-] cycles stay
/// stable.
@MainActor
@Observable
final class NavigationHistoryService {
    private(set) var canGoBack = false
    private(set) var canGoForward = false

    @ObservationIgnored private var back: [NavigationEntry] = []
    @ObservationIgnored private var forward: [NavigationEntry] = []
    @ObservationIgnored private let maxStack = 100

    /// Push the current location onto the back stack and clear the forward stack. Call this
    /// just before performing a jump. No-op when current is nil or identical to the top entry
    /// (avoids consecutive duplicates from repeated jumps to the same page).
    func recordJump(from current: NavigationEntry?) {
        guard let current else { return }
        if let last = back.last, last == current { return }
        back.append(current)
        if back.count > maxStack { back.removeFirst() }
        forward.removeAll()
        refreshFlags()
    }

    /// Pop a back entry. Push the current location onto the forward stack so the user can come
    /// back. Returns the entry to navigate to, or nil when there's nothing to go back to.
    func goBack(saving current: NavigationEntry?) -> NavigationEntry? {
        guard let entry = back.popLast() else { return nil }
        if let current, current != entry {
            forward.append(current)
        }
        refreshFlags()
        return entry
    }

    func goForward(saving current: NavigationEntry?) -> NavigationEntry? {
        guard let entry = forward.popLast() else { return nil }
        if let current, current != entry {
            back.append(current)
        }
        refreshFlags()
        return entry
    }

    func clear() {
        back.removeAll()
        forward.removeAll()
        refreshFlags()
    }

    private func refreshFlags() {
        canGoBack = !back.isEmpty
        canGoForward = !forward.isEmpty
    }
}
