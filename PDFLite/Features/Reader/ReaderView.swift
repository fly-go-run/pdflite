import PDFKit
import SwiftUI

struct ReaderView: View {
    @Bindable var session: DocumentSession

    var body: some View {
        NavigationSplitView(columnVisibility: sidebarVisibility) {
            SidebarView(session: session)
                .navigationSplitViewColumnWidth(240)
        } detail: {
            ZStack(alignment: .top) {
                PDFKitRepresentable(session: session)

                if session.isSearchVisible {
                    SearchBar(session: session)
                        .padding(.top, 12)
                }
            }
        }
        .inspector(isPresented: $session.isTranslationInspectorVisible) {
            TranslationInspector(session: session)
                .inspectorColumnWidth(min: 280, ideal: 320, max: 480)
        }
        .toolbar {
            ReaderToolbar(session: session)
        }
    }

    private var sidebarVisibility: Binding<NavigationSplitViewVisibility> {
        Binding(
            get: { session.isSidebarVisible ? .all : .detailOnly },
            set: { session.isSidebarVisible = ($0 != .detailOnly) }
        )
    }
}
