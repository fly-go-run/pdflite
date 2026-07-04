import SwiftUI

@main
struct PDFLiteApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var recentFiles = RecentFilesService.shared
    @State private var shortcuts = AppShortcuts.shared
    @State private var appFocus = AppFocusState.shared
    @State private var settings = ReaderSettings.shared

    @FocusedValue(\.documentSession) private var focusedSession

    var body: some Scene {
        // Read revision at the App-body level so SwiftUI's observation tracking re-evaluates the
        // whole scene tree (and rebuilds .commands) whenever the user records a new shortcut.
        // Without this read, observation only registers inside AppCommands.body — which doesn't
        // trigger Scene rebuilds — and menu items keep their old key bindings until app restart.
        let _ = shortcuts.revision
        let commandSession = focusedSession ?? appFocus.activeSession
        let colorScheme = settings.appearanceMode.colorScheme

        WindowGroup("PDFLite", id: "reader") {
            ReaderWindowView()
                .frame(minWidth: 720, minHeight: 480)
                .preferredColorScheme(colorScheme)
        }
        .windowToolbarStyle(.unified)
        .defaultSize(width: 1280, height: 1200)
        // File-open events route exclusively through AppDelegate → DocumentOpener (letting
        // SwiftUI handle them spawns a ghost empty window per odoc event). The one external
        // event this group accepts is our private pdflite:// scheme — the deterministic
        // "create a reader window" lever DocumentOpener pulls when no window exists (cold
        // launch with a document can race scene setup, and SwiftUI then skips the default
        // window entirely).
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
                .preferredColorScheme(colorScheme)
        }
    }
}
