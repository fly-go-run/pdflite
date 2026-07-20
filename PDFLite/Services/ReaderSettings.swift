import AppKit
import Foundation
import Observation
import SwiftUI

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

enum AppearanceMode: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }
    var label: String {
        switch self {
        case .system: return "跟随系统"
        case .light: return "浅色"
        case .dark: return "深色"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }

    var nsAppearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }
}

/// Per-app reading preferences. Light wrapper over UserDefaults so SwiftUI views can bind to it
/// directly via @Observable. Toggles persist immediately on set.
@MainActor
@Observable
final class ReaderSettings {
    static let shared = ReaderSettings()

    /// Allowed trackpad scroll-speed multipliers. 1.0 = native macOS distance per swipe.
    static let scrollSpeedRange: ClosedRange<Double> = 1.0...3.0

    private enum Key {
        static let autoTranslateOnHighlight = "pdflite.autoTranslateOnHighlight"
        static let selectionAutoAction = "pdflite.selectionAutoAction"
        static let appearanceMode = "pdflite.appearanceMode"
        static let scrollSpeed = "pdflite.scrollSpeed"
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

    var appearanceMode: AppearanceMode {
        didSet {
            guard oldValue != appearanceMode else { return }
            UserDefaults.standard.set(appearanceMode.rawValue, forKey: Key.appearanceMode)
            applyAppAppearance()
        }
    }

    /// Window chrome (titlebar / tab bar / toolbar) and AppKit panels follow NSApp.appearance,
    /// which SwiftUI's .preferredColorScheme never touches — without this, a non-system
    /// appearance renders the content in one scheme and the top bar in the other. Called on
    /// every change and once at launch (applicationDidFinishLaunching).
    func applyAppAppearance() {
        NSApp.appearance = appearanceMode.nsAppearance
    }

    /// Distance multiplier applied to trackpad scroll deltas. 1.0 keeps PDFKit's native feel;
    /// higher values make one swipe travel proportionally further. See `ReaderPDFView.scrollWheel`.
    var scrollSpeed: Double {
        didSet {
            let clamped = min(max(scrollSpeed, Self.scrollSpeedRange.lowerBound),
                              Self.scrollSpeedRange.upperBound)
            if clamped != scrollSpeed {
                scrollSpeed = clamped
                return
            }
            guard oldValue != scrollSpeed else { return }
            UserDefaults.standard.set(scrollSpeed, forKey: Key.scrollSpeed)
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
        if let raw = defaults.string(forKey: Key.appearanceMode),
           let value = AppearanceMode(rawValue: raw) {
            appearanceMode = value
        } else {
            appearanceMode = .system
        }
        // double(forKey:) returns 0 when the key is absent — fall back to native 1.0× then.
        let storedScrollSpeed = defaults.double(forKey: Key.scrollSpeed)
        scrollSpeed = storedScrollSpeed > 0
            ? min(max(storedScrollSpeed, Self.scrollSpeedRange.lowerBound),
                  Self.scrollSpeedRange.upperBound)
            : 1.0
    }
}
