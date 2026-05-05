import SwiftUI

/// SwiftUI content of the NSPanel that sits next to the user's text selection. Shows three quick
/// actions; while a translation is streaming, also shows a short preview at the top.
struct SelectionFloatingView: View {
    let translation: TranslationOutput?
    let onTranslate: () -> Void
    let onHighlight: () -> Void
    let onCopy: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let translation, shouldShowPreview(translation) {
                preview(for: translation)
                Divider()
            }
            HStack(spacing: 4) {
                actionButton(systemName: "character.bubble", title: "翻译", action: onTranslate)
                actionButton(systemName: "highlighter", title: "高亮", action: onHighlight)
                actionButton(systemName: "doc.on.doc", title: "复制", action: onCopy)
                if translation?.isStreaming == true {
                    Divider().frame(height: 14)
                    actionButton(systemName: "stop.circle", title: "取消", action: onCancel)
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.white.opacity(0.18)))
        .frame(minWidth: 220, idealWidth: 320, maxWidth: 360)
        .frame(maxHeight: 220)
    }

    private func actionButton(systemName: String, title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: systemName)
                    .font(.system(size: 12))
                Text(title)
                    .font(.system(size: 12, weight: .medium))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func shouldShowPreview(_ translation: TranslationOutput) -> Bool {
        if translation.errorMessage != nil { return true }
        if translation.fromCache { return true }
        if translation.isStreaming { return true }
        if !translation.partial.isEmpty { return true }
        return false
    }

    @ViewBuilder
    private func preview(for translation: TranslationOutput) -> some View {
        if let error = translation.errorMessage {
            ScrollView {
                Text(error)
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .frame(maxHeight: 140)
        } else {
            ScrollView {
                Text(translation.partial)
                    .font(.system(size: 12))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .frame(maxHeight: 120)
            if translation.isStreaming {
                HStack(spacing: 4) {
                    ProgressView()
                        .controlSize(.mini)
                    Text("翻译中…")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            } else if translation.fromCache {
                Text("缓存命中")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
        }
    }
}
