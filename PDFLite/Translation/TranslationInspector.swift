import PDFKit
import SwiftUI

struct TranslationInspector: View {
    @Bindable var session: DocumentSession
    @State private var isSourceExpanded = false
    @State private var historyTimeLabels: [String: String] = [:]

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
                VStack(alignment: .leading, spacing: 16) {
                    currentSection
                    if !session.translation.history.isEmpty {
                        Divider()
                        historySection
                    }
                }
                .padding(12)
            }
        }
        .onAppear {
            refreshHistoryTimeLabels()
        }
        .onChange(of: session.translation.current?.startedAt) { _, _ in
            isSourceExpanded = false
        }
        .onChange(of: session.translation.history.map(historyKey)) { _, _ in
            addMissingHistoryTimeLabels()
        }
    }

    @ViewBuilder
    private var currentSection: some View {
        if let translation = session.translation.current {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Label("当前选区", systemImage: "text.cursor")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    if let pageIndex = translation.pageIndex {
                        Text("第 \(pageIndex + 1) 页")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    Spacer()
                    if translation.isStreaming {
                        ProgressView()
                            .controlSize(.mini)
                    } else if translation.fromCache {
                        Image(systemName: "checkmark.circle")
                            .font(.caption)
                            .foregroundStyle(.green)
                    }
                }

                DisclosureGroup(isExpanded: $isSourceExpanded) {
                    Text(translation.sourceText)
                        .font(.system(size: 12))
                        .lineSpacing(1.5)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 4)
                        .textSelection(.enabled)
                } label: {
                    Text("原文")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .disclosureGroupStyle(.automatic)

                if let error = translation.errorMessage {
                    Text(error)
                        .font(.system(size: 12))
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                } else if !translation.partial.isEmpty {
                    Text(translation.partial)
                        .font(.system(size: 14))
                        .lineSpacing(3)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }

                HStack(spacing: 8) {
                    if translation.isStreaming {
                        Text("翻译中…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("取消") { session.cancelTranslation() }
                            .buttonStyle(.borderless)
                    } else if !translation.partial.isEmpty {
                        if translation.fromCache {
                            Text("缓存命中")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
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
            VStack(alignment: .leading, spacing: 10) {
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
        HStack(spacing: 6) {
            Button {
                if let pageIndex = record.pageIndex {
                    session.goToPage(pageIndex)
                }
            } label: {
                HStack(spacing: 6) {
                    if let pageIndex = record.pageIndex {
                        Text("第 \(pageIndex + 1) 页")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    Text("·")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    Text(historyTimeLabel(for: record))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .frame(minWidth: 44, alignment: .leading)
                    Text(record.targetText)
                        .font(.system(size: 12))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(record.pageIndex == nil)
            compactCopyButton(text: record.targetText)
        }
        .padding(.vertical, 4)
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

    private func compactCopyButton(text: String) -> some View {
        Button {
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setString(text, forType: .string)
        } label: {
            Image(systemName: "doc.on.doc")
                .font(.system(size: 11))
        }
        .buttonStyle(.borderless)
        .help("复制译文")
    }

    private func historyTimeLabel(for record: TranslationRecord) -> String {
        historyTimeLabels[historyKey(for: record)] ?? makeHistoryTimeLabel(from: record.createdAt)
    }

    private func refreshHistoryTimeLabels() {
        historyTimeLabels = Dictionary(
            uniqueKeysWithValues: session.translation.history.map { record in
                (historyKey(for: record), makeHistoryTimeLabel(from: record.createdAt))
            }
        )
    }

    private func addMissingHistoryTimeLabels() {
        let visibleKeys = Set(session.translation.history.map(historyKey))
        var labels = historyTimeLabels.filter { visibleKeys.contains($0.key) }
        var changed = labels.count != historyTimeLabels.count

        for record in session.translation.history {
            let key = historyKey(for: record)
            if labels[key] == nil {
                labels[key] = makeHistoryTimeLabel(from: record.createdAt)
                changed = true
            }
        }

        if changed {
            historyTimeLabels = labels
        }
    }

    private func historyKey(for record: TranslationRecord) -> String {
        if let id = record.id {
            return "id:\(id)"
        }
        return "pending:\(record.textHash):\(record.createdAt.timeIntervalSince1970)"
    }

    private func makeHistoryTimeLabel(from date: Date) -> String {
        let elapsed = max(0, Int(Date().timeIntervalSince(date)))
        if elapsed < 60 {
            return "刚刚"
        }
        if elapsed < 3600 {
            return "\(elapsed / 60) 分钟前"
        }
        if elapsed < 86_400 {
            return "\(elapsed / 3600) 小时前"
        }
        return "\(elapsed / 86_400) 天前"
    }
}
