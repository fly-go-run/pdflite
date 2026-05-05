import PDFKit
import SwiftUI

struct ReaderView: View {
    @Bindable var session: DocumentSession

    var body: some View {
        HStack(spacing: 0) {
            if session.isSidebarVisible {
                ZStack {
                    // Solid base (deepest), then vibrancy on top, then SidebarView content. Both
                    // backings ignoreSafeArea so they keep filling the column even while the
                    // window's safe area is animating through the fullscreen ↔ windowed
                    // transition — which is what was leaving a one-frame grey flash before.
                    Color(nsColor: .controlBackgroundColor)
                        .ignoresSafeArea()
                    VisualEffectBackground(material: .sidebar)
                        .ignoresSafeArea()
                    SidebarView(session: session)
                }
                .frame(width: 240)
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
                ZStack {
                    Color(nsColor: .controlBackgroundColor)
                        .ignoresSafeArea()
                    VisualEffectBackground(material: .contentBackground)
                        .ignoresSafeArea()
                    TranslationInspector(session: session)
                }
                .frame(width: 320)
            }
        }
        .toolbar {
            ReaderToolbar(session: session)
        }
    }
}
