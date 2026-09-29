import Foundation

struct TranslationConfig: Equatable {
    var apiKey: String
    var endpoint: URL
    var model: String

    static let defaultEndpoint = URL(string: "https://api.deepseek.com/chat/completions")!
    static let defaultModel = "deepseek-v4-flash"
    static let provider = "deepseek"

    /// Target language label used in the prompt + cache key. Phase 3 hard-codes Chinese; later
    /// phases can expose this as a setting.
    static let defaultTargetLanguage = "简体中文"
}

/// Coarse classification of a failed translation, so the UI can pick a recovery affordance
/// (e.g. the "打开设置" button) from the case instead of matching message text.
enum TranslationErrorKind: Equatable {
    /// The DeepSeek config is missing, unreadable, malformed or has no API key — all fixed in
    /// Settings → 翻译.
    case needsConfiguration
}

extension TranslationConfig {
    /// Minimal hand-written config.json (§8). Shown in Settings → 翻译 under "配置文件格式" rather
    /// than inside the translation error, which stays a single line.
    static let fileFormatSample = """
    {
      "deepseek": {
        "apiKey": "sk-...",
        "endpoint": "https://api.deepseek.com/chat/completions",
        "model": "deepseek-v4-flash"
      }
    }
    手动编辑后建议执行：chmod 600 ~/.config/pdflite/config.json
    """
}

enum TranslationConfigError: LocalizedError {
    case fileMissing(URL)
    case unreadable(URL, underlying: Error)
    case malformed(String)
    case missingAPIKey

    var errorDescription: String? {
        switch self {
        case .fileMissing, .missingAPIKey:
            // One line on purpose: the floating card clips long text and the fix (a button that
            // opens Settings, which shows the file path) doesn't need explaining here.
            return "尚未配置 DeepSeek API Key"
        case .unreadable(let url, let underlying):
            return "无法读取配置文件 \(url.path)：\(underlying.localizedDescription)"
        case .malformed(let detail):
            return "配置文件格式错误：\(detail)"
        }
    }
}
