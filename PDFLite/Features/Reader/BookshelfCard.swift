import AppKit
import SwiftUI

struct BookshelfCard: View {
    let recent: RecentFile
    /// The window is already opening a file. Clicking another card meanwhile would route the
    /// second open into a new window, so the card is inert until the first open settles.
    var isOpeningDocument: Bool = false
    let openAction: () -> Void
    let removeAction: () -> Void

    @State private var thumbnail: NSImage?
    @State private var isHovering = false

    private var hasTimestamp: Bool {
        recent.lastOpenedAt > Date(timeIntervalSince1970: 0)
    }

    var body: some View {
        // A real Button (not onTapGesture) so the card is keyboard-focusable (Tab + Space/Return)
        // and reads as a proper element to VoiceOver.
        Button(action: openAction) {
            VStack(alignment: .leading, spacing: 6) {
                cover
                Text(recent.displayName)
                    .font(.system(size: 12))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(.primary)
                if hasTimestamp {
                    Text(recent.lastOpenedAt, format: .relative(presentation: .named))
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            .frame(width: 130, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isOpeningDocument)
        .accessibilityLabel("打开 \(recent.displayName)")
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.15)) {
                isHovering = hovering
            }
        }
        .contextMenu {
            Button("打开", action: openAction)
                .disabled(isOpeningDocument)
            Button("在 Finder 中显示") {
                NSWorkspace.shared.activateFileViewerSelecting([recent.url])
            }
            Divider()
            Button("从最近移除", role: .destructive, action: removeAction)
        }
        .task(id: recent.id) {
            let image = await ThumbnailCache.shared.thumbnail(for: recent.url)
            withAnimation(.easeIn(duration: 0.2)) {
                thumbnail = image
            }
        }
    }

    private var cover: some View {
        ZStack {
            if let thumbnail {
                Image(nsImage: thumbnail)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .transition(.opacity)
            } else {
                Rectangle()
                    .fill(Color(nsColor: .controlBackgroundColor))
                Image(systemName: "doc.richtext")
                    .font(.system(size: 36, weight: .light))
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(width: 130, height: 170)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
        )
        .shadow(
            color: Color.black.opacity(isHovering ? 0.18 : 0.08),
            radius: isHovering ? 8 : 3,
            y: isHovering ? 4 : 2
        )
        .offset(y: isHovering ? -2 : 0)
    }
}
