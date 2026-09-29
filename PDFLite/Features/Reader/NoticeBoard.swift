import Foundation
import Observation

/// One banner message over the reader.
///
/// The transient/persistent split exists because the two kinds of message age differently: a
/// failed one-off action ("无法删除高亮…") is stale a few seconds later and should clear itself,
/// while a message about an ongoing condition ("数据库降级"、"无法确认文档内容") stays true until the
/// document is reopened — auto-clearing it would hide exactly the warning that the user's
/// progress and highlights are not being saved.
struct SessionNotice: Equatable {
    let message: String
    let isTransient: Bool

    static func transient(_ message: String) -> SessionNotice {
        SessionNotice(message: message, isTransient: true)
    }

    static func persistent(_ message: String) -> SessionNotice {
        SessionNotice(message: message, isTransient: false)
    }

    /// Highlighting was attempted before the document identity / saved highlights finished
    /// loading. Resolved by `DocumentSession` (not by time) once annotations are ready.
    static let preparingAnnotations = persistent("正在准备标注，请稍候")
    /// The database is unavailable, so highlights can't be stored for this session.
    static let annotationsNotSaved = persistent("无法保存标注，阅读仍可继续")
}

/// Holds the banner state for one window's `DocumentSession`: at most one persistent and one
/// transient notice. A transient notice is shown on top of the persistent one and, when it
/// expires or is dismissed, the persistent one is still there underneath — a passing error must
/// never evict a standing warning.
@MainActor
@Observable
final class NoticeBoard {
    private(set) var persistent: SessionNotice?
    private(set) var transient: SessionNotice?

    /// What the banner shows: the newest transient notice, else the standing persistent one.
    var current: SessionNotice? { transient ?? persistent }

    /// How long a transient notice stays. A property (not a constant) so tests can shorten it.
    @ObservationIgnored var transientLifetime: Duration = .seconds(6)

    @ObservationIgnored private var expiry: Task<Void, Never>?
    /// Bumped on every transient post and on `reset()`, so a timer that survives a cancellation
    /// race can tell it belongs to an older notice / document and must not touch the new one.
    @ObservationIgnored private var transientGeneration = 0
    /// Persistent messages the user already dismissed this session. Repeating conditions (for
    /// example a progress save that fails after every scroll) re-post the same message; without
    /// this the banner would pop back up right after each ✕.
    @ObservationIgnored private var dismissedPersistent: Set<String> = []

    func post(_ notice: SessionNotice) {
        if notice.isTransient {
            transient = notice
            scheduleExpiry()
        } else if persistent?.message != notice.message,
                  !dismissedPersistent.contains(notice.message) {
            persistent = notice
        }
    }

    /// The ✕ button: hides the notice currently shown. Dismissing a persistent notice hides it
    /// for the rest of this document session; the underlying condition is unchanged.
    func dismiss() {
        if transient != nil {
            transient = nil
            cancelExpiry()
        } else if let shown = persistent {
            dismissedPersistent.insert(shown.message)
            persistent = nil
        }
    }

    /// The condition behind `notice` resolved (for example annotations finished loading).
    func resolve(_ notice: SessionNotice) {
        if persistent == notice { persistent = nil }
        if transient == notice {
            transient = nil
            cancelExpiry()
        }
    }

    /// Document closed or a new one is opening: nothing shown belongs to the next document, and
    /// no timer may outlive this call.
    func reset() {
        cancelExpiry()
        transient = nil
        persistent = nil
        dismissedPersistent = []
    }

    private func scheduleExpiry() {
        cancelExpiry() // also bumps the generation, invalidating any timer still in flight
        let generation = transientGeneration
        let lifetime = transientLifetime
        expiry = Task { [weak self] in
            try? await Task.sleep(for: lifetime)
            guard !Task.isCancelled, let self, self.transientGeneration == generation else { return }
            self.transient = nil
        }
    }

    private func cancelExpiry() {
        expiry?.cancel()
        expiry = nil
        transientGeneration += 1
    }
}
