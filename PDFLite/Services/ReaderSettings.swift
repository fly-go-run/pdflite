import Foundation
import Observation

/// What to do automatically when the user finishes a text selection. Independent of
/// `autoTranslateOnHighlight`, which only chains *after* a manual highlight.
enum SelectionAutoAction: String, CaseIterable, Identifiable {
    case none
    case translate
    case highlight

    var id: String { rawValue }
    var label: String {
        switch self {
        case .none: return "不操作"
        case .translate: return "自动翻译"
        case .highlight: return "自动高亮"
        }
    }
}

/// Per-app reading preferences. Light wrapper over UserDefaults so SwiftUI views can bind to it
/// directly via @Observable. Toggles persist immediately on set.
@MainActor
@Observable
final class ReaderSettings {
    static let shared = ReaderSettings()

    private enum Key {
        static let autoTranslateOnHighlight = "pdflite.autoTranslateOnHighlight"
        static let selectionAutoAction = "pdflite.selectionAutoAction"
    }

    var autoTranslateOnHighlight: Bool {
        didSet {
            guard oldValue != autoTranslateOnHighlight else { return }
            UserDefaults.standard.set(autoTranslateOnHighlight, forKey: Key.autoTranslateOnHighlight)
        }
    }

    var selectionAutoAction: SelectionAutoAction {
        didSet {
            guard oldValue != selectionAutoAction else { return }
            UserDefaults.standard.set(selectionAutoAction.rawValue, forKey: Key.selectionAutoAction)
        }
    }

    init() {
        let defaults = UserDefaults.standard
        // bool(forKey:) returns false when the key is absent — that's our intended default.
        autoTranslateOnHighlight = defaults.bool(forKey: Key.autoTranslateOnHighlight)
        if let raw = defaults.string(forKey: Key.selectionAutoAction),
           let value = SelectionAutoAction(rawValue: raw) {
            selectionAutoAction = value
        } else {
            selectionAutoAction = .none
        }
    }
}
