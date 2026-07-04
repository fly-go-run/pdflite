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
    private var inFlight: [String: Task<NSImage?, Never>] = [:]

    init(directory: URL = AppPaths.thumbnailsDirectory) {
        self.directory = directory
    }

    func thumbnail(for url: URL) async -> NSImage? {
        guard let key = Self.cacheKey(for: url) else { return nil }
        if let cached = memory[key] { return cached }
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
        }
        return result
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
