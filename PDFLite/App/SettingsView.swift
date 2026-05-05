import AppKit
import KeyboardShortcuts
import SwiftUI

/// Macos `Settings { ... }` window content. Three tabs: 翻译 (DeepSeek API config), 阅读
/// (selection / highlight behaviour), 快捷键 (read-only cheat sheet — users can re-map any
/// menu item via System Settings → Keyboard → App Shortcuts).
struct SettingsView: View {
    var body: some View {
        TabView {
            TranslationSettingsView()
                .tabItem { Label("翻译", systemImage: "character.bubble") }
            ReadingSettingsView()
                .tabItem { Label("阅读", systemImage: "highlighter") }
            ShortcutsSettingsView()
                .tabItem { Label("快捷键", systemImage: "keyboard") }
        }
        .frame(width: 520, height: 420)
    }
}

// MARK: - Translation tab

private struct TranslationSettingsView: View {
    @State private var apiKey: String = ""
    @State private var endpoint: String = ""
    @State private var model: String = ""
    @State private var statusMessage: String?
    @State private var isError: Bool = false

    var body: some View {
        Form {
            Section {
                SecureField("API Key", text: $apiKey, prompt: Text("sk-…"))
                TextField("Endpoint", text: $endpoint,
                          prompt: Text(TranslationConfig.defaultEndpoint.absoluteString))
                    .autocorrectionDisabled()
                TextField("Model", text: $model,
                          prompt: Text(TranslationConfig.defaultModel))
                    .autocorrectionDisabled()
            } header: {
                Text("DeepSeek")
            } footer: {
                Text("配置文件：\(AppPaths.configFileURL.path)")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 4)
            }

            if let statusMessage {
                Text(statusMessage)
                    .font(.system(size: 11))
                    .foregroundStyle(isError ? Color.red : Color.secondary)
            }

            HStack {
                Spacer()
                Button("重新读取") { reload() }
                Button("保存") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .formStyle(.grouped)
        .padding(.horizontal, 8)
        .onAppear { reload() }
    }

    private func reload() {
        if let config = ConfigLoader.loadOptional() {
            apiKey = config.apiKey
            endpoint = config.endpoint.absoluteString
            model = config.model
            statusMessage = nil
            isError = false
        } else {
            apiKey = ""
            endpoint = ""
            model = ""
            statusMessage = "尚未保存任何配置"
            isError = false
        }
    }

    private func save() {
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedEndpoint = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else { return }

        let endpointURL: URL
        if trimmedEndpoint.isEmpty {
            endpointURL = TranslationConfig.defaultEndpoint
        } else if let parsed = URL(string: trimmedEndpoint), parsed.scheme?.hasPrefix("http") == true {
            endpointURL = parsed
        } else {
            statusMessage = "Endpoint 不是合法 URL"
            isError = true
            return
        }

        let config = TranslationConfig(
            apiKey: trimmedKey,
            endpoint: endpointURL,
            model: trimmedModel.isEmpty ? TranslationConfig.defaultModel : trimmedModel
        )
        do {
            try ConfigLoader.save(config)
            statusMessage = "已保存"
            isError = false
        } catch {
            statusMessage = "保存失败：\(error.localizedDescription)"
            isError = true
        }
    }
}

// MARK: - Reading tab

private struct ReadingSettingsView: View {
    @State private var settings = ReaderSettings.shared

    var body: some View {
        Form {
            Section {
                Picker("划词后", selection: $settings.selectionAutoAction) {
                    ForEach(SelectionAutoAction.allCases) { option in
                        Text(option.label).tag(option)
                    }
                }
                .pickerStyle(.segmented)
            } header: {
                Text("划词")
            } footer: {
                Text("决定每次完成划词后自动执行什么。「自动翻译」会立即向 LLM 发请求，需要先在「翻译」中填好 API Key。「自动高亮」会沉默地把选区落库为高亮。")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 4)
            }

            Section {
                Toggle("高亮时自动翻译并绑定", isOn: $settings.autoTranslateOnHighlight)
            } header: {
                Text("高亮")
            } footer: {
                Text("开启后，每次创建高亮会自动调用翻译并把结果与该高亮绑定。需要在「翻译」中先填好 API Key。")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 4)
            }
        }
        .formStyle(.grouped)
        .padding(.horizontal, 8)
    }
}

// MARK: - Shortcuts tab

private struct ShortcutsSettingsView: View {
    @State private var shortcuts = AppShortcuts.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                ForEach(ShortcutCatalog.sections) { section in
                    sectionView(section)
                }

                Divider()

                HStack {
                    Text("⌘O / ⌘F 等系统通用键未列出，仍按 Apple 约定固定。点录入栏后按下新键可自定义；按 ⌫ 清空。")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("恢复默认") {
                        shortcuts.resetAll()
                    }
                    .controlSize(.small)
                }
            }
            .padding(16)
        }
    }

    private func sectionView(_ section: ShortcutSection) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(section.title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)

            VStack(spacing: 0) {
                ForEach(section.entries) { entry in
                    HStack {
                        Text(entry.title)
                            .font(.system(size: 12))
                        Spacer()
                        KeyboardShortcuts.Recorder(for: entry.name) { _ in
                            shortcuts.notifyChange()
                        }
                    }
                    .padding(.vertical, 4)
                    .padding(.horizontal, 10)
                    if entry.id != section.entries.last?.id {
                        Divider().opacity(0.4)
                    }
                }
            }
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
        }
    }
}
