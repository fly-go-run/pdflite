import PDFKit
import SwiftUI

struct TranslationInspector: View {
    @Bindable var session: DocumentSession

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("翻译")
                    .font(.headline)
                Spacer()
                Button {
                    session.isTranslationInspectorVisible = false
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.borderless)
                .help("Hide Inspector")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    currentSection
                    Divider()
                    historySection
                }
                .padding(12)
            }
        }
    }

    @ViewBuilder
    private var currentSection: some View {
        if let translation = session.translation.current {
            VStack(alignment: .leading, spacing: 6) {
                Label("当前选区", systemImage: "text.cursor")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                if let pageIndex = translation.pageIndex {
                    Text("第 \(pageIndex + 1) 页")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                Text(translation.sourceText)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                    .textSelection(.enabled)

                if let error = translation.errorMessage {
                    Text(error)
                        .font(.system(size: 12))
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                } else if !translation.partial.isEmpty {
                    Text(translation.partial)
                        .font(.system(size: 13))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }

                HStack(spacing: 8) {
                    if translation.isStreaming {
                        ProgressView()
                            .controlSize(.mini)
                        Text("翻译中…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("取消") { session.cancelTranslation() }
                            .buttonStyle(.borderless)
                    } else if translation.fromCache {
                        Image(systemName: "checkmark.seal")
                            .foregroundStyle(.green)
                        Text("缓存命中")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        copyButton(text: translation.partial)
                    } else if !translation.partial.isEmpty {
                        Spacer()
                        copyButton(text: translation.partial)
                    } else {
                        Spacer()
                    }
                }
            }
        } else {
            VStack(spacing: 6) {
                Image(systemName: "character.bubble")
                    .font(.title2)
                    .foregroundStyle(.tertiary)
                Text("选中文本后点击浮卡上的“翻译”")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 24)
        }
    }

    @ViewBuilder
    private var historySection: some View {
        let history = session.translation.history
        if history.isEmpty {
            EmptyView()
        } else {
            VStack(alignment: .leading, spacing: 8) {
                Label("历史", systemImage: "clock")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                ForEach(history, id: \.id) { record in
                    historyRow(record)
                }
            }
        }
    }

    private func historyRow(_ record: TranslationRecord) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                if let pageIndex = record.pageIndex {
                    Text("第 \(pageIndex + 1) 页")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                Spacer()
                Text(record.createdAt, style: .relative)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Text(record.sourceText)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .truncationMode(.tail)
            Text(record.targetText)
                .font(.system(size: 12))
                .lineLimit(3)
                .truncationMode(.tail)
            HStack(spacing: 8) {
                if let pageIndex = record.pageIndex {
                    Button {
                        session.goToPage(pageIndex)
                    } label: {
                        Label("跳回原文", systemImage: "arrow.uturn.backward")
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                }
                copyButton(text: record.targetText)
            }
        }
        .padding(8)
        .background(.quinary, in: RoundedRectangle(cornerRadius: 6))
    }

    private func copyButton(text: String) -> some View {
        Button {
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setString(text, forType: .string)
        } label: {
            Label("复制", systemImage: "doc.on.doc")
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
    }
}
