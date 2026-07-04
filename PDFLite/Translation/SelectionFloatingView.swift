import SwiftUI

/// SwiftUI content of the NSPanel that sits next to the user's text selection. Two modes:
/// - When the right-side translation Inspector is *closed*, the panel shows action buttons with
///   labels and a single-line streaming preview (so the user gets feedback without opening the
///   inspector).
/// - When the Inspector is *open*, the panel collapses to icon-only buttons and skips the
///   preview entirely — duplicating the streaming body next to the selection while it's already
///   showing in the Inspector is just visual noise (per Gemini review + §3.9).
struct SelectionFloatingView: View {
    let translation: TranslationOutput?
    let figureReference: FigureReference?
    let inspectorOpen: Bool
    let onTranslate: () -> Void
    let onHighlight: () -> Void
    let onCopy: () -> Void
    let onCancel: () -> Void
    let onRetry: () -> Void
    let onJumpToFigure: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            if !inspectorOpen, let translation, shouldShowPreview(translation) {
                preview(for: translation)
                Divider().opacity(0.55)
            }
            HStack(spacing: 3) {
                if let figureReference {
                    // Figure jump always carries its label — an arrow alone wouldn't say "Fig 3".
                    actionButton(
                        systemName: "arrow.right.circle",
                        title: "跳到 \(figureReference.canonicalLabel)",
                        helpText: "跳到 \(figureReference.canonicalLabel)",
                        action: onJumpToFigure,
                        forceLabel: true
                    )
                    Divider().frame(height: 14)
                }
                actionButton(systemName: "character.bubble", title: "翻译",
                             helpText: "翻译", action: onTranslate)
                actionButton(systemName: "highlighter", title: "高亮",
                             helpText: "高亮", action: onHighlight)
                actionButton(systemName: "doc.on.doc", title: "复制",
                             helpText: "复制", action: onCopy)
                if translation?.isStreaming == true {
                    Divider().frame(height: 14)
                    actionButton(systemName: "stop.circle", title: "取消",
                                 helpText: "取消翻译", action: onCancel)
                }
                if translation?.errorMessage != nil {
                    Divider().frame(height: 14)
                    actionButton(systemName: "arrow.clockwise", title: "重试",
                                 helpText: "重试翻译", action: onRetry)
                }
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.white.opacity(0.16)))
        .frame(
            minWidth: inspectorOpen ? 130 : 220,
            idealWidth: inspectorOpen ? 180 : 300,
            maxWidth: inspectorOpen ? 240 : 330
        )
    }

    private func actionButton(
        systemName: String,
        title: String,
        helpText: String,
        action: @escaping () -> Void,
        forceLabel: Bool = false
    ) -> some View {
        let showLabel = forceLabel || !inspectorOpen
        return Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: systemName)
                    .font(.system(size: 12))
                if showLabel {
                    Text(title)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, showLabel ? 7 : 5)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(helpText)
    }

    private func shouldShowPreview(_ translation: TranslationOutput) -> Bool {
        if translation.errorMessage != nil { return true }
        if translation.isStreaming { return true }
        return false
    }

    @ViewBuilder
    private func preview(for translation: TranslationOutput) -> some View {
        if let error = translation.errorMessage {
            Text(error)
                .font(.system(size: 11))
                .foregroundStyle(.red)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.mini)
                Text(translation.partial.isEmpty ? "翻译中…" : translation.partial)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}
