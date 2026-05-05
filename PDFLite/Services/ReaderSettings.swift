import Foundation
import Observation

/// Per-app reading preferences. Light wrapper over UserDefaults so SwiftUI views can bind to it
/// directly via @Observable. Toggles persist immediately on set.
@MainActor
@Observable
final class ReaderSettings {
    static let shared = ReaderSettings()

    private enum Key {
        static let autoTranslateOnHighlight = "pdflite.autoTranslateOnHighlight"
    }

    var autoTranslateOnHighlight: Bool {
        didSet {
            guard oldValue != autoTranslateOnHighlight else { return }
            UserDefaults.standard.set(autoTranslateOnHighlight, forKey: Key.autoTranslateOnHighlight)
        }
    }

    init() {
        let defaults = UserDefaults.standard
        // bool(forKey:) returns false when the key is absent — that's our intended default.
        autoTranslateOnHighlight = defaults.bool(forKey: Key.autoTranslateOnHighlight)
    }
}
