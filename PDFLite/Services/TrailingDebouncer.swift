import Foundation

/// Trailing-edge debouncer for main-actor hot paths (scroll ticks, pinch zoom, selection drags).
/// Unlike the cancel-and-respawn `Task { sleep }` idiom, repeated calls while waiting only push
/// the deadline forward — a single long-lived task services the whole burst, so a 60 Hz
/// notification stream doesn't allocate and cancel one Task per event.
@MainActor
final class TrailingDebouncer {
    private var deadline = ContinuousClock.now
    private var pendingAction: (@MainActor () -> Void)?
    private var runner: Task<Void, Never>?

    /// Schedule `action` to run once, `interval` after the most recent call. A later call
    /// replaces the pending action and moves the deadline out.
    func call(after interval: Duration, action: @escaping @MainActor () -> Void) {
        pendingAction = action
        deadline = ContinuousClock.now + interval
        guard runner == nil else { return }
        runner = Task { [weak self] in
            while true {
                guard let self, !Task.isCancelled else { return }
                let target = self.deadline
                if ContinuousClock.now >= target {
                    self.runner = nil
                    let action = self.pendingAction
                    self.pendingAction = nil
                    action?()
                    return
                }
                try? await Task.sleep(until: target, clock: .continuous)
            }
        }
    }

    /// Drop the pending action without running it.
    func cancel() {
        pendingAction = nil
        runner?.cancel()
        runner = nil
    }
}
