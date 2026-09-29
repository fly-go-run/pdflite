import CryptoKit
import XCTest

/// `FileHash.sha256` streams the file in 1 MB chunks off the main thread. Temp files only.
final class FileHashTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: directory)
    }

    private func write(_ bytes: Int, name: String) throws -> URL {
        var generator = SystemRandomNumberGenerator()
        let data = Data((0..<bytes).map { _ in UInt8.random(in: .min ... .max, using: &generator) })
        let url = directory.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    private func reference(_ url: URL) throws -> String {
        SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
    }

    func testMatchesCryptoKitAcrossChunkBoundaries() throws {
        let chunk = 1024 * 1024
        // Ragged tail, exact multiple (last read returns empty), sub-chunk, and empty.
        for size in [chunk * 3 + 12_345, chunk * 2, 777, 0] {
            let url = try write(size, name: "f\(size)")
            XCTAssertEqual(try FileHash.sha256(of: url), try reference(url), "size \(size)")
        }
    }

    func testUnreadableFileThrows() {
        XCTAssertThrowsError(try FileHash.sha256(of: directory.appendingPathComponent("missing")))
    }

    func testAlreadyCancelledTaskThrowsBeforeReading() async throws {
        let url = try write(1024 * 1024 * 2, name: "cancelled")
        let task = Task.detached { () throws -> String in
            // Wait for the cancel to land, then hash: the very first chunk boundary must bail out.
            while !Task.isCancelled { await Task.yield() }
            return try FileHash.sha256(of: url)
        }
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("a cancelled task must not finish hashing")
        } catch {
            XCTAssertTrue(error is CancellationError, "\(error)")
        }
    }

    /// Cancelled while hashing: a sparse 1 GiB file (no real disk use) takes far longer than the
    /// 20 ms head start, so a loop that ignored cancellation would return a hash instead.
    func testCancellationStopsAHashInFlight() async throws {
        let url = directory.appendingPathComponent("sparse")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: 1024 * 1024 * 1024)
        try handle.close()

        let task = Task.detached { try FileHash.sha256(of: url) }
        try await Task.sleep(for: .milliseconds(20))
        let cancelledAt = ContinuousClock.now
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("hashing 1 GiB finished before the cancel — cancellation was ignored")
        } catch {
            XCTAssertTrue(error is CancellationError, "\(error)")
            XCTAssertLessThan(ContinuousClock.now - cancelledAt, .seconds(1),
                              "cancellation should stop within about one chunk")
        }
    }
}
