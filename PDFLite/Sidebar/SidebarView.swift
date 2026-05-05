import SwiftUI

struct SidebarView: View {
    @Bindable var session: DocumentSession

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $session.sidebarTab) {
                ForEach(SidebarTab.allCases) { tab in
                    Image(systemName: tab.systemImage)
                        .tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .padding(8)

            Divider()

            switch session.sidebarTab {
            case .outline:
                OutlineSidebar(session: session)
            case .thumbnails:
                ThumbnailSidebar(session: session)
            }
        }
    }
}
