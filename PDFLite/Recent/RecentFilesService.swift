import Foundation
import Observation
import os.log

struct RecentFile: Identifiable, Codable, Hashable {
    let url: URL

    var id: String { url.standardizedFileURL.path }
    var displayName: String { url.deletingPathExtension().lastPathComponent }
}

@MainActor
@Observable
final class RecentFilesService {
    static let shared = RecentFilesService()

    private let logger = Logger(subsystem: "com.pdflite.app", category: "RecentFiles")
    private let storageKey = "RecentFiles.v1"
    private let maxItems = 10
    private let defaults: UserDefaults

    private(set) var recentFiles: [RecentFile] = []

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        load()
    }

    func add(_ url: URL) {
        guard url.pathExtension.lowercased() == "pdf" else { return }
        let canonical = url.standardizedFileURL
        var updated = recentFiles.filter { $0.url.standardizedFileURL != canonical }
        updated.insert(RecentFile(url: canonical), at: 0)
        if updated.count > maxItems {
            updated = Array(updated.prefix(maxItems))
        }
        recentFiles = updated
        save()
    }

    func clear() {
        recentFiles = []
        defaults.removeObject(forKey: storageKey)
    }

    private func load() {
        guard let data = defaults.data(forKey: storageKey) else { return }
        do {
            let decoded = try JSONDecoder().decode([RecentFile].self, from: data)
            recentFiles = decoded.filter { FileManager.default.fileExists(atPath: $0.url.path) }
        } catch {
            logger.error("Failed to decode recent files: \(error.localizedDescription)")
        }
    }

    private func save() {
        do {
            let data = try JSONEncoder().encode(recentFiles)
            defaults.set(data, forKey: storageKey)
        } catch {
            logger.error("Failed to encode recent files: \(error.localizedDescription)")
        }
    }
}
