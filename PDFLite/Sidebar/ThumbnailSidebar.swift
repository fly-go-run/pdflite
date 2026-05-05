import PDFKit
import SwiftUI

struct ThumbnailSidebar: NSViewRepresentable {
    @Bindable var session: DocumentSession

    func makeNSView(context: Context) -> PDFThumbnailView {
        let thumbnail = PDFThumbnailView()
        thumbnail.thumbnailSize = CGSize(width: 180, height: 220)
        thumbnail.backgroundColor = .clear
        thumbnail.pdfView = session.pdfView
        return thumbnail
    }

    func updateNSView(_ thumbnail: PDFThumbnailView, context: Context) {
        if thumbnail.pdfView !== session.pdfView {
            thumbnail.pdfView = session.pdfView
        }
    }
}
