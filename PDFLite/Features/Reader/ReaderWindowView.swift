import PDFKit
import SwiftUI

struct ReaderWindowView: View {
    @State private var session = DocumentSession()
    @State private var panelController = SelectionPanelController()

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
            wirePanelActions()
        }
        .onDisappear {
            session.flushReadingState()
            panelController.dismiss()
        }
        .onChange(of: session.selectionRevision) { _, _ in
            refreshPanel()
        }
        .onChange(of: session.translation.current) { _, _ in
            refreshPanel()
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

    private func wirePanelActions() {
        panelController.onTranslate = {
            session.translateCurrentSelection()
        }
        panelController.onHighlight = {
            session.highlightSelection()
        }
        panelController.onCopy = {
            session.copyCurrentSelection()
        }
        panelController.onCancel = {
            session.cancelTranslation()
        }
    }

    private func refreshPanel() {
        guard session.hasSelection,
              let rect = session.selectionScreenRect() else {
            panelController.dismiss()
            return
        }
        panelController.present(near: rect, translation: session.translation.current)
    }
}
