import Foundation

struct TranslationConfig: Equatable {
    var apiKey: String
    var endpoint: URL
    var model: String

    static let defaultEndpoint = URL(string: "https://api.deepseek.com/v1/chat/completions")!
    static let defaultModel = "deepseek-chat"
    static let provider = "deepseek"

    /// Target language label used in the prompt + cache key. Phase 3 hard-codes Chinese; later
    /// phases can expose this as a setting.
    static let defaultTargetLanguage = "简体中文"
}

enum TranslationConfigError: LocalizedError {
    case fileMissing(URL)
    case unreadable(URL, underlying: Error)
    case malformed(String)
    case missingAPIKey

    var errorDescription: String? {
        switch self {
        case .fileMissing(let url):
            return "未找到 DeepSeek 配置文件：\(url.path)"
        case .unreadable(let url, let underlying):
            return "无法读取配置文件 \(url.path)：\(underlying.localizedDescription)"
        case .malformed(let detail):
            return "配置文件格式错误：\(detail)"
        case .missingAPIKey:
            return "配置文件中没有 deepseek.apiKey"
        }
    }

    var recoverySuggestion: String? {
        switch self {
        case .fileMissing, .missingAPIKey:
            return """
            请在 ~/.config/pdflite/config.json 中提供：
            {
              "deepseek": {
                "apiKey": "sk-...",
                "endpoint": "https://api.deepseek.com/v1/chat/completions",
                "model": "deepseek-chat"
              }
            }
            建议执行：chmod 600 ~/.config/pdflite/config.json
            """
        default:
            return nil
        }
    }
}
