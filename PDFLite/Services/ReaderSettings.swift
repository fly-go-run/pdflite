import AppKit
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

    var nsAppearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }
}

/// Keeps AppKit-owned window chrome in the same scheme as the SwiftUI reader content.
///
/// macOS 26 renders native fullscreen tabs through glass views in an auxiliary window. The
/// auxiliary window inherits the right appearance, but the glass content can retain Aqua after
/// a live switch to Dark Aqua. A dark tint plus explicit control/text appearances fixes that
/// public-AppKit boundary without depending on private window or tab-view class names.
@MainActor
enum AppAppearanceSynchronizer {
    private final class GlassTintSnapshot: NSObject {
        let value: NSColor?

        init(_ value: NSColor?) {
            self.value = value
        }
    }

    private final class AppearanceSnapshot: NSObject {
        let value: NSAppearance?

        init(_ value: NSAppearance?) {
            self.value = value
        }
    }

    private static var synchronizationRevision = 0
    private static let originalGlassTints =
        NSMapTable<NSView, GlassTintSnapshot>.weakToStrongObjects()
    private static let originalControlAppearances =
        NSMapTable<NSView, AppearanceSnapshot>.weakToStrongObjects()

    static func applyAppAppearance(_ appearance: NSAppearance?) {
        NSApp.appearance = appearance
        scheduleSynchronization()
    }

    /// AppKit rebuilds fullscreen chrome asynchronously when entering fullscreen or selecting a
    /// tab. Run an immediate pass, then two short follow-up passes to catch replacement views.
    static func scheduleSynchronization() {
        synchronizationRevision += 1
        let revision = synchronizationRevision
        synchronizeWindowAppearances()

        Task { @MainActor in
            await Task.yield()
            guard revision == synchronizationRevision else { return }
            synchronizeWindowAppearances()

            try? await Task.sleep(for: .milliseconds(160))
            guard revision == synchronizationRevision else { return }
            synchronizeWindowAppearances()
        }
    }

    private static func synchronizeWindowAppearances() {
        let target = NSApp.effectiveAppearance
        let targetMatch = target.bestMatch(from: [.darkAqua, .aqua])
        let isDark = targetMatch == .darkAqua

        for window in NSApp.windows {
            // A transparent titlebar leaves the background around macOS's fullscreen tab
            // glass in Aqua even after the tab controls themselves switch to Dark Aqua.
            // Make only the active fullscreen reader titlebar opaque in dark mode; restore the
            // app's normal transparent chrome for light mode, inactive tabs, and windowed mode.
            if #available(macOS 26.0, *),
               window.tabbingIdentifier == "PDFLiteReader" {
                let shouldAppearTransparent = !(
                    isDark && window.styleMask.contains(.fullScreen)
                )
                if window.titlebarAppearsTransparent != shouldAppearTransparent {
                    window.titlebarAppearsTransparent = shouldAppearTransparent
                }
            }

            // Native fullscreen chrome uses a separate window whose public appearanceSource is
            // the original fullscreen document window. Restrict glass tinting to that auxiliary
            // window so ordinary reader/sidebar glass keeps its system-provided material.
            guard #available(macOS 26.0, *),
                  let sourceWindow = window.appearanceSource as? NSWindow,
                  isNativeFullscreenChromeWindow(window, source: sourceWindow),
                  let rootView = window.contentView else {
                continue
            }
            synchronizeFullscreenChrome(
                in: rootView,
                target: target,
                isDark: isDark
            )
        }
    }

    /// Identifies the native fullscreen tab/titlebar helper using only public window state.
    /// `appearanceSource` alone is intentionally insufficient because sheets and other child
    /// windows can inherit from the same fullscreen reader window.
    private static func isNativeFullscreenChromeWindow(
        _ window: NSWindow,
        source: NSWindow
    ) -> Bool {
        let frame = window.frame
        let sourceFrame = source.frame
        return source !== window
            && source.tabbingIdentifier == "PDFLiteReader"
            && source.styleMask.contains(.fullScreen)
            && window.parent === source
            && window.sheetParent == nil
            && !(window is NSPanel)
            && window.styleMask.isEmpty
            && window.level == .normal
            && !window.isOpaque
            && !window.hasShadow
            && frame.height > 0
            && frame.height <= 160
            && abs(frame.width - sourceFrame.width) <= 2
            && abs(frame.maxY - sourceFrame.maxY) <= 2
    }

    private static func synchronizeFullscreenChrome(
        in view: NSView,
        target: NSAppearance,
        isDark: Bool
    ) {
        if #available(macOS 26.0, *), let glassView = view as? NSGlassEffectView {
            if isDark {
                if originalGlassTints.object(forKey: glassView) == nil {
                    originalGlassTints.setObject(
                        GlassTintSnapshot(glassView.tintColor),
                        forKey: glassView
                    )
                }
                glassView.tintColor = NSColor.black.withAlphaComponent(0.75)
            } else if let snapshot = originalGlassTints.object(forKey: glassView) {
                glassView.tintColor = snapshot.value
                originalGlassTints.removeObject(forKey: glassView)
            }
        }

        // The glass content holder can choose Aqua even when its window is Dark Aqua. Applying
        // the target directly to public controls and labels preserves readable tab titles,
        // close buttons, and the new-tab button. Restore the exact inherited/explicit value in
        // light mode so AppKit can resume its normal selection and hover behavior.
        if view is NSButton || view is NSTextField {
            if isDark {
                if originalControlAppearances.object(forKey: view) == nil {
                    originalControlAppearances.setObject(
                        AppearanceSnapshot(view.appearance),
                        forKey: view
                    )
                }
                view.appearance = target
            } else if let snapshot = originalControlAppearances.object(forKey: view) {
                view.appearance = snapshot.value
                originalControlAppearances.removeObject(forKey: view)
            }
        }

        view.needsDisplay = true
        for subview in view.subviews {
            synchronizeFullscreenChrome(in: subview, target: target, isDark: isDark)
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

    /// Use NSApp.appearance as the single source for both AppKit chrome and hosted SwiftUI
    /// content. Keeping windows on their default inherited appearance prevents the Settings
    /// titlebar and body from updating on different lifecycles. Called on every change and once
    /// at launch (applicationDidFinishLaunching).
    func applyAppAppearance() {
        AppAppearanceSynchronizer.applyAppAppearance(appearanceMode.nsAppearance)
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
