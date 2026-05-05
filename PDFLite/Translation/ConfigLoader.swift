import Foundation

/// Reads the on-disk DeepSeek config. Per §3.8 the API key never goes into source / SQLite /
/// logs — this loader is the only thing that ever sees it, and the resulting struct is held in
/// memory only.
enum ConfigLoader {
    private struct Payload: Decodable {
        struct DeepSeek: Decodable {
            let apiKey: String?
            let endpoint: String?
            let model: String?
        }
        let deepseek: DeepSeek?
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
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
