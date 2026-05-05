import PDFKit
import SwiftUI

struct ReaderView: View {
    @Bindable var session: DocumentSession

    var body: some View {
        HStack(spacing: 0) {
            if session.isSidebarVisible {
                ZStack {
                    Color(nsColor: .controlBackgroundColor)
                        .ignoresSafeArea()
                    VisualEffectBackground(material: .sidebar)
                        .ignoresSafeArea()
                    SidebarView(session: session)
                }
                .frame(width: 240)
                .transaction { $0.disablesAnimations = true }
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
                .transaction { $0.disablesAnimations = true }
            }
        }
        .toolbar {
            ReaderToolbar(session: session)
        }
    }
}
