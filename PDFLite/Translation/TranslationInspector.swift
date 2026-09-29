import PDFKit
import SwiftUI

/// Right-side inspector. Translation is the visual focus; the source text is collapsed into a
/// disclosure group so the body of the panel is dominated by readable Chinese (the user can
/// always glance at the PDF for the original). No history list — the cache layer makes
/// re-translating cheap, so persisting a list view here would just clutter the panel.
struct TranslationInspector: View {
    @Bindable var session: DocumentSession
    @State private var isSourceExpanded = false

    var body: some View {
        VStack(spacing: 0) {
            Text("翻译")
                .font(.headline)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)

            Divider()

            ScrollView {
                currentSection
                    .padding(12)
            }
        }
        .onChange(of: session.translation.current?.startedAt) { _, _ in
            isSourceExpanded = false
        }
    }

    @ViewBuilder
    private var currentSection: some View {
        if let translation = session.translation.current {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Label(session.translationMatchingCurrentSelection == nil ? "最近翻译" : "当前选区", systemImage: "text.cursor")
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

                if let error = translation.errorMessage {
                    Text(error)
                        .font(.system(size: 12))
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                    HStack(spacing: 8) {
                        if translation.errorKind == .needsConfiguration {
                            Button {
                                SettingsWindow.open(tab: .translation)
                            } label: {
                                Label("打开设置", systemImage: "gearshape")
                                    .font(.system(size: 12))
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                            .help("打开设置 → 翻译，填写 DeepSeek API Key")
                        }
                        if session.translation.canRetry {
                            Button {
                                session.retryTranslation()
                            } label: {
                                Label("重试", systemImage: "arrow.clockwise")
                                    .font(.system(size: 12))
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                    }
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

    private func copyButton(text: String) -> some View {
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
}
