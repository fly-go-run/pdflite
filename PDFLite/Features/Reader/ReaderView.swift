import PDFKit
import SwiftUI

struct ReaderView: View {
    @Bindable var session: DocumentSession

    var body: some View {
        HStack(spacing: 0) {
            if session.isSidebarVisible {
                SidebarView(session: session)
                    .frame(width: 240)
                    // VisualEffect right behind content for vibrancy; solid color as the deepest
                    // layer so the brief render gap during fullscreen ↔ windowed animation
                    // shows the sidebar tint instead of the bare window grey.
                    .background(VisualEffectBackground(material: .sidebar))
                    .background(Color(nsColor: .controlBackgroundColor))
                Divider()
            }

            ZStack(alignment: .top) {
                PDFKitRepresentable(session: session)

                if session.isSearchVisible {
                    SearchBar(session: session)
                        .padding(.top, 12)
                }
            }

            if session.isTranslationInspectorVisible {
                Divider()
                TranslationInspector(session: session)
                    .frame(width: 320)
                    .background(VisualEffectBackground(material: .contentBackground))
                    .background(Color(nsColor: .controlBackgroundColor))
            }
        }
        .toolbar {
            ReaderToolbar(session: session)
        }
    }
}
