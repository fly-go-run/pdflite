import SwiftUI

@main
struct PDFLiteApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var recentFiles = RecentFilesService.shared
    @State private var shortcuts = AppShortcuts.shared
    @State private var appFocus = AppFocusState.shared

    @FocusedValue(\.documentSession) private var focusedSession

    var body: some Scene {
        // Read revision at the App-body level so SwiftUI's observation tracking re-evaluates the
        // whole scene tree (and rebuilds .commands) whenever the user records a new shortcut.
        // Without this read, observation only registers inside AppCommands.body — which doesn't
        // trigger Scene rebuilds — and menu items keep their old key bindings until app restart.
        let _ = shortcuts.revision
        let commandSession = focusedSession ?? appFocus.activeSession

        WindowGroup("PDFLite", id: "reader") {
            ReaderWindowView()
                .frame(minWidth: 720, minHeight: 480)
        }
        // unifiedCompact: toolbar shares one ~38pt row with the (leading) title instead of the
        // ~52pt unified row — the single biggest chrome saving available without giving up the
        // native toolbar. The title must stay visible: hiding it collapses the trailing
        // toolbar cluster to the leading edge (see note in WindowFocusBridge.Coordinator).
        .windowToolbarStyle(.unifiedCompact)
        .defaultSize(width: 1280, height: 1200)
        // File-open events route exclusively through AppDelegate → DocumentOpener (letting
        // SwiftUI handle them spawns a ghost empty window per odoc event). The external events
        // this group accepts are our private pdflite:// scheme: pdflite://reader is the
        // deterministic "create a reader window" lever DocumentOpener pulls when no window
        // exists, and pdflite://open?url=… deep links are claimed by existing windows via the
        // view-level handlesExternalEvents in ReaderWindowView + routed through onOpenURL.
        // Narrowing this to just pdflite://reader does NOT hand deep links to AppDelegate —
        // SwiftUI swallows unmatched pdflite:// events entirely (verified) — it just drops them.
        .handlesExternalEvents(matching: ["pdflite://"])
        .commands {
            AppCommands(
                focusedSession: commandSession,
                recentFiles: recentFiles,
                shortcuts: shortcuts
            )
        }

        Settings {
            SettingsView()
        }
    }
}
