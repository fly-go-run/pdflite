import PDFKit
import SwiftUI

struct ReaderWindowView: View {
    @State private var session = DocumentSession()

    var body: some View {
        Group {
            if session.hasDocument {
                ReaderView(session: session)
            } else {
                EmptyDocumentView(session: session)
            }
        }
        .focusedSceneValue(\.documentSession, session)
        .onAppear {
            DocumentOpener.register(session)
        }
        .onDisappear {
            session.flushReadingState()
        }
        .navigationTitle(session.title)
        .alert("无法打开 PDF",
               isPresented: Binding(
                   get: { session.loadError != nil },
                   set: { if !$0 { session.clearLoadError() } }
               ),
               actions: { Button("OK") { session.clearLoadError() } },
               message: { Text(session.loadError ?? "") })
    }
}
