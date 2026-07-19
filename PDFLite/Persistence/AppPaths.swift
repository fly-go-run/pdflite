import Foundation

enum AppPaths {
    /// `~/Library/Application Support/PDFLite/`. Created lazily on first access.
    static var supportDirectory: URL {
        let fm = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = base.appendingPathComponent("PDFLite", isDirectory: true)
        if !fm.fileExists(atPath: dir.path) {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    /// SQLite sidecar — single file, all user data lives here.
    static var sqliteURL: URL {
        supportDirectory.appendingPathComponent("reader.sqlite", isDirectory: false)
    }

    /// `~/Library/Application Support/PDFLite/thumbnails/` — bookshelf cover cache (Phase 5).
    static var thumbnailsDirectory: URL {
        let dir = supportDirectory.appendingPathComponent("thumbnails", isDirectory: true)
        let fm = FileManager.default
        if !fm.fileExists(atPath: dir.path) {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    /// `~/Library/Application Support/PDFLite/library/` — PDFs downloaded from URLs (arXiv
    /// papers etc.). These are permanent library copies, not a cache: the bookshelf, reading
    /// state and annotations all reference them by this stable path.
    static var remoteLibraryDirectory: URL {
        let dir = supportDirectory.appendingPathComponent("library", isDirectory: true)
        let fm = FileManager.default
        if !fm.fileExists(atPath: dir.path) {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    /// `~/.config/pdflite/config.json` — DeepSeek key & similar runtime config (Phase 3).
    static var configFileURL: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(".config/pdflite/config.json", isDirectory: false)
    }
}
