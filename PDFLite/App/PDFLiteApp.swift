import SwiftUI

@main
struct PDFLiteApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var recentFiles = RecentFilesService.shared
    @State private var shortcuts = AppShortcuts.shared

    @FocusedValue(\.documentSession) private var focusedSession

    var body: some Scene {
        // Read revision at the App-body level so SwiftUI's observation tracking re-evaluates the
        // whole scene tree (and rebuilds .commands) whenever the user records a new shortcut.
        // Without this read, observation only registers inside AppCommands.body — which doesn't
        // trigger Scene rebuilds — and menu items keep their old key bindings until app restart.
        let _ = shortcuts.revision

        WindowGroup("PDFLite") {
            ReaderWindowView()
                .frame(minWidth: 720, minHeight: 480)
        }
        .windowToolbarStyle(.unified)
        .commands {
            AppCommands(
                focusedSession: focusedSession,
                recentFiles: recentFiles,
                shortcuts: shortcuts
            )
        }

        Settings {
            SettingsView()
        }
    }
}
