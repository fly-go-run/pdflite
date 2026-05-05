import SwiftUI

@main
struct PDFLiteApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var recentFiles = RecentFilesService.shared

    @FocusedValue(\.documentSession) private var focusedSession

    var body: some Scene {
        WindowGroup("PDFLite") {
            ReaderWindowView()
                .frame(minWidth: 720, minHeight: 480)
        }
        .windowToolbarStyle(.unified)
        .commands {
            AppCommands(focusedSession: focusedSession, recentFiles: recentFiles)
        }

        Settings {
            SettingsView()
        }
    }
}
