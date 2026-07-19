import AppKit
import CryptoKit
import Foundation
import PDFKit
import os.log

/// Renders and caches first-page thumbnails for the bookshelf. Cache key is derived from
/// (path, size, mtime) so opening the same file at the same path with unchanged content
/// hits cache, while a content change at the same path naturally rotates the key.
actor ThumbnailCache {
    static let shared = ThumbnailCache()

    private let logger = Logger(subsystem: "com.pdflite.app", category: "ThumbnailCache")
    private let directory: URL
    private var memory: [String: NSImage] = [:]
    /// LRU order for `memory` (least recently used first). The bookshelf holds at most 10 items,
    /// but keys rotate with file mtime — without a cap, long sessions would pin every generation
    /// of every thumbnail in memory.
    private var memoryOrder: [String] = []
    private let maxMemoryEntries = 24
    private var inFlight: [String: Task<NSImage?, Never>] = [:]
    /// Cache keys embed mtime, so a re-downloaded/edited file strands its old PNG on disk
    /// forever. Prune once per launch, keeping the most recently written files.
    private var didScheduleDiskPrune = false
    private let maxDiskEntries = 60

    init(directory: URL = AppPaths.thumbnailsDirectory) {
        self.directory = directory
    }

    func thumbnail(for url: URL) async -> NSImage? {
        scheduleDiskPruneIfNeeded()
        guard let key = Self.cacheKey(for: url) else { return nil }
        if let cached = memory[key] {
            markRecentlyUsed(key)
            return cached
        }
        if let pending = inFlight[key] { return await pending.value }

        let directory = self.directory
        let task = Task<NSImage?, Never>.detached(priority: .utility) {
            let cacheURL = directory.appendingPathComponent("\(key).png", isDirectory: false)
            if let onDisk = NSImage(contentsOf: cacheURL) {
                return onDisk
            }
            guard let rendered = Self.renderFirstPage(of: url) else { return nil }
            if let png = rendered.pngData() {
                try? png.write(to: cacheURL, options: .atomic)
            }
            return rendered
        }
        inFlight[key] = task
        let result = await task.value
        inFlight[key] = nil
        if let result {
            memory[key] = result
            markRecentlyUsed(key)
            if memoryOrder.count > maxMemoryEntries, let evicted = memoryOrder.first {
                memoryOrder.removeFirst()
                memory[evicted] = nil
            }
        }
        return result
    }

    private func markRecentlyUsed(_ key: String) {
        if let index = memoryOrder.firstIndex(of: key) {
            memoryOrder.remove(at: index)
        }
        memoryOrder.append(key)
    }

    private func scheduleDiskPruneIfNeeded() {
        guard !didScheduleDiskPrune else { return }
        didScheduleDiskPrune = true
        let directory = self.directory
        let keep = maxDiskEntries
        Task.detached(priority: .background) {
            let fm = FileManager.default
            guard let urls = try? fm.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: .skipsHiddenFiles
            ), urls.count > keep else { return }
            let dated = urls.map { url -> (url: URL, date: Date) in
                let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate ?? .distantPast
                return (url, date)
            }.sorted { $0.date > $1.date }
            for entry in dated.dropFirst(keep) {
                try? fm.removeItem(at: entry.url)
            }
        }
    }

    private static func cacheKey(for url: URL) -> String? {
        let path = url.standardizedFileURL.path
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let size = attrs[.size] as? Int,
              let mtime = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970
        else { return nil }
        let raw = "\(path)|\(size)|\(mtime)"
        let digest = SHA256.hash(data: Data(raw.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func renderFirstPage(of url: URL) -> NSImage? {
        guard let document = PDFDocument(url: url),
              let page = document.page(at: 0)
        else { return nil }
        let bounds = page.bounds(for: .cropBox)
        guard bounds.width > 0, bounds.height > 0 else { return nil }
        // Long edge ≈ 280pt at 2× for retina sharpness; aspect preserved.
        let scale = 280.0 / max(bounds.width, bounds.height) * 2.0
        let target = NSSize(width: bounds.width * scale, height: bounds.height * scale)
        return page.thumbnail(of: target, for: .cropBox)
    }
}

private extension NSImage {
    func pngData() -> Data? {
        guard let tiff = tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff)
        else { return nil }
        return rep.representation(using: .png, properties: [:])
    }
}
