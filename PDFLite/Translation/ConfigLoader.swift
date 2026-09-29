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
    /// malformed — settings can show empty fields instead of erroring out. That is safe because
    /// `save` refuses to overwrite a file it cannot parse.
    /// `url` is injectable so tests never touch the real `~/.config/pdflite/config.json`.
    static func loadOptional(from url: URL = AppPaths.configFileURL) -> TranslationConfig? {
        try? load(from: url)
    }

    static func load(from url: URL = AppPaths.configFileURL) throws -> TranslationConfig {
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

    /// Persist the config back to ~/.config/pdflite/config.json, keeping the API key private
    /// (§9): the file is born 0600 — written to a sibling temp file created with mode 0600 and
    /// renamed over the target — so there is no window where it is world-readable. The directory
    /// is created 0700 only when absent; an existing directory's permissions are never touched.
    ///
    /// Only `deepseek.{apiKey,endpoint,model}` are updated: the existing JSON is parsed and
    /// merged so any other keys the user added (top level or inside `deepseek`) survive. A
    /// non-empty file that is not valid JSON is never overwritten — it throws `ConfigSaveError`
    /// instead, so a hand-edit typo can't be silently replaced by the Settings form.
    /// Posts `configChangedNotification` on success so any TranslationService instances can drop
    /// their cached copy on the next request.
    static func save(_ config: TranslationConfig, to url: URL = AppPaths.configFileURL) throws {
        // Write through a symlink (dotfiles-managed config) instead of replacing the link.
        let target = url.resolvingSymlinksInPath()

        var root = try existingRoot(at: target)
        var block: [String: Any]
        switch root["deepseek"] {
        case nil, is NSNull:
            block = [:]
        case let existing as [String: Any]:
            block = existing
        default:
            throw ConfigSaveError.unexpectedStructure(target, detail: "deepseek 字段不是对象")
        }
        block["apiKey"] = config.apiKey
        block["endpoint"] = config.endpoint.absoluteString
        block["model"] = config.model
        root["deepseek"] = block

        let data = try JSONSerialization.data(
            withJSONObject: root,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        try ensureDirectory(target.deletingLastPathComponent())
        try writeReplacing(target, with: data)

        NotificationCenter.default.post(name: configChangedNotification, object: nil)
    }

    // MARK: - Save helpers

    /// The current top-level JSON object, or `[:]` when there is no file / it is blank. Throws
    /// rather than returning `[:]` for content we can't faithfully merge into.
    private static func existingRoot(at url: URL) throws -> [String: Any] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw TranslationConfigError.unreadable(url, underlying: error)
        }
        let blank: Set<UInt8> = [0x20, 0x09, 0x0A, 0x0D]
        if data.allSatisfy({ blank.contains($0) }) { return [:] }

        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data)
        } catch {
            let detail = (error as NSError).userInfo[NSDebugDescriptionErrorKey] as? String
                ?? error.localizedDescription
            throw ConfigSaveError.invalidJSON(url, detail: detail)
        }
        guard let dictionary = object as? [String: Any] else {
            throw ConfigSaveError.unexpectedStructure(url, detail: "顶层不是 JSON 对象")
        }
        return dictionary
    }

    private static func ensureDirectory(_ dir: URL) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: dir.path) { return }
        // Only the leaf is private; a missing ~/.config keeps the usual default permissions.
        let parent = dir.deletingLastPathComponent()
        if !fm.fileExists(atPath: parent.path) {
            try fm.createDirectory(at: parent, withIntermediateDirectories: true)
        }
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: false,
                                   attributes: [.posixPermissions: 0o700])
        } catch {
            // Lost a race with another creator: fine as long as the directory now exists.
            if !fm.fileExists(atPath: dir.path) { throw error }
        }
    }

    /// Atomic replace with the restrictive mode set at creation. `Data.write(.atomic)` would
    /// create the temp file with the umask default (0644) and only later allow a chmod.
    private static func writeReplacing(_ target: URL, with data: Data) throws {
        let dir = target.deletingLastPathComponent()
        let temp = dir.appendingPathComponent(".\(target.lastPathComponent).\(UUID().uuidString).tmp")
        let fd = Darwin.open(temp.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard fd >= 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        do {
            try handle.write(contentsOf: data)
            try handle.synchronize()
            try handle.close()
            guard Darwin.rename(temp.path, target.path) == 0 else {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
            }
        } catch {
            try? handle.close()
            unlink(temp.path)
            throw error
        }
    }
}

/// Reasons `ConfigLoader.save` refuses to touch an existing config file. Both leave the file
/// exactly as it was.
enum ConfigSaveError: LocalizedError {
    case invalidJSON(URL, detail: String)
    case unexpectedStructure(URL, detail: String)

    var errorDescription: String? {
        switch self {
        case .invalidJSON(let url, let detail):
            return "配置文件 \(url.path) 不是合法 JSON（\(detail)），为避免覆盖你手工编辑的内容，已取消保存。请先修正或删除该文件。"
        case .unexpectedStructure(let url, let detail):
            return "配置文件 \(url.path) 的结构不符合预期（\(detail)），为避免丢失内容，已取消保存。请先修正该文件。"
        }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
