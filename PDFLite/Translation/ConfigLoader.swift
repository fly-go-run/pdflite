import Foundation

/// Reads the on-disk DeepSeek config. Per §3.8 the API key never goes into source / SQLite /
/// logs — this loader is the only thing that ever sees it, and the resulting struct is held in
/// memory only.
enum ConfigLoader {
    private struct Payload: Codable {
        struct DeepSeek: Codable {
            let apiKey: String?
            let endpoint: String?
            let model: String?
        }
        let deepseek: DeepSeek?
    }

    static let configChangedNotification = Notification.Name("com.pdflite.configChanged")

    /// Best-effort read for prefilling the settings UI. Returns nil when the file is missing or
    /// malformed — settings can show empty fields instead of erroring out.
    static func loadOptional() -> TranslationConfig? {
        try? load()
    }

    static func load() throws -> TranslationConfig {
        let url = AppPaths.configFileURL
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw TranslationConfigError.fileMissing(url)
        }

        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw TranslationConfigError.unreadable(url, underlying: error)
        }

        let payload: Payload
        do {
            payload = try JSONDecoder().decode(Payload.self, from: data)
        } catch {
            throw TranslationConfigError.malformed(error.localizedDescription)
        }

        guard let block = payload.deepseek else {
            throw TranslationConfigError.malformed("缺少顶层 deepseek 块")
        }

        guard let apiKey = block.apiKey?.trimmingCharacters(in: .whitespacesAndNewlines),
              !apiKey.isEmpty else {
            throw TranslationConfigError.missingAPIKey
        }

        let endpoint: URL
        if let raw = block.endpoint?.trimmingCharacters(in: .whitespacesAndNewlines),
           !raw.isEmpty {
            guard let parsed = URL(string: raw), parsed.scheme?.hasPrefix("http") == true else {
                throw TranslationConfigError.malformed("endpoint 不是合法 URL：\(raw)")
            }
            endpoint = parsed
        } else {
            endpoint = TranslationConfig.defaultEndpoint
        }

        let model = block.model?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            ?? TranslationConfig.defaultModel

        return TranslationConfig(apiKey: apiKey, endpoint: endpoint, model: model)
    }

    /// Persist the config back to ~/.config/pdflite/config.json (creating the directory if
    /// needed) and chmod 600 so the API key isn't world-readable. Posts
    /// `configChangedNotification` on success so any TranslationService instances can drop
    /// their cached copy on the next request.
    static func save(_ config: TranslationConfig) throws {
        let url = AppPaths.configFileURL
        let dir = url.deletingLastPathComponent()
        let fm = FileManager.default
        if !fm.fileExists(atPath: dir.path) {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }

        let payload = Payload(deepseek: Payload.DeepSeek(
            apiKey: config.apiKey,
            endpoint: config.endpoint.absoluteString,
            model: config.model
        ))

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(payload)
        try data.write(to: url, options: [.atomic])
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)

        NotificationCenter.default.post(name: configChangedNotification, object: nil)
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
