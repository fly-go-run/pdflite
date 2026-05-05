import CryptoKit
import Foundation

enum FileHash {
    /// SHA-256 of the whole file, lowercase hex. Reads in 1 MB chunks so multi-MB PDFs don't
    /// allocate the entire file in memory. Throws if the file isn't readable.
    static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        var hasher = SHA256()
        let chunkSize = 1024 * 1024
        while true {
            let chunk = try handle.read(upToCount: chunkSize) ?? Data()
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
