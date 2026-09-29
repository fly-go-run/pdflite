import CryptoKit
import Foundation

enum FileHash {
    /// SHA-256 of the whole file, lowercase hex. Reads in 1 MB chunks so multi-MB PDFs don't
    /// allocate the entire file in memory. Throws if the file isn't readable, and throws
    /// `CancellationError` between chunks when the calling task is cancelled — a window closed
    /// or a second file requested mid-open shouldn't keep a background thread reading a
    /// several-hundred-MB PDF to the end.
    static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        var hasher = SHA256()
        let chunkSize = 1024 * 1024
        var reachedEnd = false
        while !reachedEnd {
            try Task.checkCancellation()
            // Each chunk's Data is autoreleased Foundation storage; without a pool per iteration
            // every chunk of the file stays alive until the whole call returns.
            try autoreleasepool {
                let chunk = try handle.read(upToCount: chunkSize) ?? Data()
                if chunk.isEmpty {
                    reachedEnd = true
                } else {
                    hasher.update(data: chunk)
                }
            }
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
