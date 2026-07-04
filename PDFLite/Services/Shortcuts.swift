import AppKit
import KeyboardShortcuts
import Observation
import SwiftUI

// MARK: - Shortcut slot declarations
//
// Each slot is registered with a default that mirrors what AppCommands used to hardcode. The
// KeyboardShortcuts package handles persistence + the recorder UI; we only own the bridge
// from its `Shortcut` value to SwiftUI's `KeyboardShortcut`.

extension KeyboardShortcuts.Name {
    static let toggleSidebar       = Self("toggleSidebar", default: .init(.b, modifiers: .command))
    static let toggleInspector     = Self("toggleInspector", default: .init(.i, modifiers: [.command, .option]))
    static let zoomIn              = Self("zoomIn", default: .init(.equal, modifiers: .command))
    static let zoomOut             = Self("zoomOut", default: .init(.minus, modifiers: .command))
    // ⌘0 = actual size mirrors Preview.app; fit-width sits next to it on ⌘9.
    static let fitWidth            = Self("fitWidth", default: .init(.nine, modifiers: .command))
    static let actualSize          = Self("actualSize", default: .init(.zero, modifiers: .command))
    static let nextPage            = Self("nextPage", default: .init(.rightArrow, modifiers: .command))
    static let previousPage        = Self("previousPage", default: .init(.leftArrow, modifiers: .command))
    static let firstPage           = Self("firstPage", default: .init(.upArrow, modifiers: [.command, .option]))
    static let lastPage            = Self("lastPage", default: .init(.downArrow, modifiers: [.command, .option]))
    static let goBack              = Self("goBack", default: .init(.leftBracket, modifiers: .command))
    static let goForward           = Self("goForward", default: .init(.rightBracket, modifiers: .command))
    static let translateSelection  = Self("translateSelection", default: .init(.t, modifiers: [.command, .control]))
    static let highlightSelection  = Self("highlightSelection", default: .init(.h, modifiers: [.command, .control]))
}

// MARK: - Catalog driving the Settings UI

struct ShortcutEntry: Identifiable {
    let id: String
    let name: KeyboardShortcuts.Name
    let title: String

    init(name: KeyboardShortcuts.Name, title: String) {
        self.id = name.rawValue
        self.name = name
        self.title = title
    }
}

struct ShortcutSection: Identifiable {
    let id = UUID()
    let title: String
    let entries: [ShortcutEntry]
}

enum ShortcutCatalog {
    static let sections: [ShortcutSection] = [
        ShortcutSection(title: "视图", entries: [
            ShortcutEntry(name: .toggleSidebar, title: "Sidebar"),
            ShortcutEntry(name: .toggleInspector, title: "翻译 Inspector"),
            ShortcutEntry(name: .zoomIn, title: "放大"),
            ShortcutEntry(name: .zoomOut, title: "缩小"),
            ShortcutEntry(name: .fitWidth, title: "Fit Width"),
            ShortcutEntry(name: .actualSize, title: "实际大小")
        ]),
        ShortcutSection(title: "导航", entries: [
            ShortcutEntry(name: .nextPage, title: "下一页"),
            ShortcutEntry(name: .previousPage, title: "上一页"),
            ShortcutEntry(name: .firstPage, title: "首页"),
            ShortcutEntry(name: .lastPage, title: "末页"),
            ShortcutEntry(name: .goBack, title: "后退"),
            ShortcutEntry(name: .goForward, title: "前进")
        ]),
        ShortcutSection(title: "选区动作", entries: [
            ShortcutEntry(name: .translateSelection, title: "翻译选区"),
            ShortcutEntry(name: .highlightSelection, title: "高亮选区")
        ])
    ]

    static var allEntries: [ShortcutEntry] {
        sections.flatMap(\.entries)
    }
}

// MARK: - Observable bridge

/// Thin observable wrapper so SwiftUI menu builders re-render when the user records a new
/// shortcut. The KeyboardShortcuts package doesn't publish a generic "shortcut changed"
/// signal we can subscribe to from outside the Recorder, so we plumb its onChange callback
/// straight into `notifyChange()` and bump a revision tracked by `value(for:)`.
@MainActor
@Observable
final class AppShortcuts {
    static let shared = AppShortcuts()

    private(set) var revision: Int = 0

    func notifyChange() {
        revision += 1
    }

    /// SwiftUI `KeyboardShortcut?` for the given slot. Reads `revision` so the call site is
    /// re-evaluated whenever a Recorder reports a change.
    func value(for name: KeyboardShortcuts.Name) -> SwiftUI.KeyboardShortcut? {
        _ = revision
        return KeyboardShortcuts.getShortcut(for: name)?.swiftUIShortcut
    }

    /// Restore every customizable shortcut to its declared default.
    func resetAll() {
        KeyboardShortcuts.reset(ShortcutCatalog.allEntries.map(\.name))
        notifyChange()
    }

    /// Tooltip text with the *current* key binding appended (e.g. "后退 (⌘[)"), so tooltips
    /// stay truthful after the user re-records a shortcut in Settings.
    func helpText(_ base: String, for name: KeyboardShortcuts.Name) -> String {
        _ = revision
        guard let shortcut = KeyboardShortcuts.getShortcut(for: name) else { return base }
        return "\(base) (\(shortcut.description))"
    }
}

// MARK: - Bridge KeyboardShortcuts.Shortcut → SwiftUI.KeyboardShortcut
//
// The package has an internal `toSwiftUI` property that does this exact conversion, but it
// isn't public — so we re-implement on top of the public surface. `nsMenuItemKeyEquivalent`
// returns the AppKit menu-item character (special function keys appear as their NSEvent
// `NSXxxFunctionKey` Unicode constants), which we then map back to SwiftUI's KeyEquivalent.

extension KeyboardShortcuts.Shortcut {
    @MainActor
    var swiftUIShortcut: SwiftUI.KeyboardShortcut? {
        guard let keyString = nsMenuItemKeyEquivalent,
              let first = keyString.first else { return nil }
        return SwiftUI.KeyboardShortcut(
            KeyEquivalent.from(menuKey: first),
            modifiers: EventModifiers(nsModifiers: modifiers)
        )
    }
}

extension KeyEquivalent {
    /// Translate the single character returned by `NSMenuItem#keyEquivalent` into SwiftUI's
    /// equivalent. AppKit uses a few private-use Unicode codepoints (the `NSXxxFunctionKey`
    /// constants) for arrows / page nav / forward-delete; everything else is a regular char.
    static func from(menuKey ch: Character) -> KeyEquivalent {
        switch ch.unicodeScalars.first?.value {
        case UInt32(NSUpArrowFunctionKey):    return .upArrow
        case UInt32(NSDownArrowFunctionKey):  return .downArrow
        case UInt32(NSLeftArrowFunctionKey):  return .leftArrow
        case UInt32(NSRightArrowFunctionKey): return .rightArrow
        case UInt32(NSPageUpFunctionKey):     return .pageUp
        case UInt32(NSPageDownFunctionKey):   return .pageDown
        case UInt32(NSHomeFunctionKey):       return .home
        case UInt32(NSEndFunctionKey):        return .end
        case UInt32(NSDeleteFunctionKey):     return .deleteForward
        case 0x7F:                             return .delete       // backspace
        case 0x1B:                             return .escape
        case 0x09:                             return .tab
        case 0x0D, 0x03:                       return .return       // CR / Enter
        case 0x20:                             return .space
        default:                               return KeyEquivalent(ch)
        }
    }
}

extension EventModifiers {
    init(nsModifiers: NSEvent.ModifierFlags) {
        var result: EventModifiers = []
        if nsModifiers.contains(.command)  { result.insert(.command) }
        if nsModifiers.contains(.option)   { result.insert(.option) }
        if nsModifiers.contains(.control)  { result.insert(.control) }
        if nsModifiers.contains(.shift)    { result.insert(.shift) }
        self = result
    }
}
