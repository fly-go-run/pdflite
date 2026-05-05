import PDFKit
import SwiftUI

struct ReaderView: View {
    @Bindable var session: DocumentSession

    var body: some View {
        HStack(spacing: 0) {
            if session.isSidebarVisible {
                SidebarView(session: session)
                    .frame(width: 240)
                    .background(.regularMaterial)
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
                    .background(.regularMaterial)
            }
        }
        .toolbar {
            ReaderToolbar(session: session)
        }
    }
}
