import os
import XCTest

/// `ConfigLoader` against injected temp URLs only — the real ~/.config/pdflite is never touched.
final class ConfigLoaderTests: XCTestCase {
    private var directory: URL!
    private var configURL: URL { directory.appendingPathComponent("pdflite/config.json") }

    private let config = TranslationConfig(
        apiKey: "sk-test-key",
        endpoint: URL(string: "https://example.test/v1/chat/completions")!,
        model: "test-model"
    )

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: directory)
    }

    private func write(_ text: String) throws {
        try FileManager.default.createDirectory(at: configURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data(text.utf8).write(to: configURL)
    }

    private func json() throws -> [String: Any] {
        let data = try Data(contentsOf: configURL)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func mode(of url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }

    // MARK: - Round trip

    func testSaveThenLoadRoundTripsThroughTheInjectedURL() throws {
        try ConfigLoader.save(config, to: configURL)
        XCTAssertEqual(try ConfigLoader.load(from: configURL), config)
        XCTAssertEqual(ConfigLoader.loadOptional(from: configURL), config)
    }

    func testLoadOfMissingFileThrowsFileMissingForThatURL() {
        XCTAssertThrowsError(try ConfigLoader.load(from: configURL)) { error in
            guard case TranslationConfigError.fileMissing(let url) = error else {
                return XCTFail("Expected fileMissing, got \(error)")
            }
            XCTAssertEqual(url, configURL)
        }
        XCTAssertNil(ConfigLoader.loadOptional(from: configURL))
    }

    func testSaveWritesReadableJSONWithoutEscapedSlashes() throws {
        try ConfigLoader.save(config, to: configURL)
        let text = try String(contentsOf: configURL, encoding: .utf8)
        XCTAssertTrue(text.contains("https://example.test/v1/chat/completions"), text)
    }

    // MARK: - Merging

    func testSavePreservesUnknownKeysAtTopLevelAndInsideDeepseek() throws {
        try write("""
        {
          "deepseek": {
            "apiKey": "old-key",
            "model": "old-model",
            "temperature": 0.7,
            "extraHeaders": { "X-Test": "1" }
          },
          "theme": "dark",
          "future": { "list": [1, 2, 3], "flag": true }
        }
        """)

        try ConfigLoader.save(config, to: configURL)

        let root = try json()
        XCTAssertEqual(root["theme"] as? String, "dark")
        XCTAssertEqual((root["future"] as? [String: Any])?["list"] as? [Int], [1, 2, 3])
        XCTAssertEqual((root["future"] as? [String: Any])?["flag"] as? Bool, true)
        let block = try XCTUnwrap(root["deepseek"] as? [String: Any])
        XCTAssertEqual(block["apiKey"] as? String, "sk-test-key")
        XCTAssertEqual(block["endpoint"] as? String, "https://example.test/v1/chat/completions")
        XCTAssertEqual(block["model"] as? String, "test-model")
        XCTAssertEqual(block["temperature"] as? Double, 0.7)
        XCTAssertEqual((block["extraHeaders"] as? [String: String])?["X-Test"], "1")
        XCTAssertEqual(try ConfigLoader.load(from: configURL), config)
    }

    func testSaveIntoBlankOrDeepseekLessFileWorks() throws {
        try write("  \n")
        try ConfigLoader.save(config, to: configURL)
        XCTAssertEqual(try ConfigLoader.load(from: configURL), config)

        try write(#"{"note": "keep me", "deepseek": null}"#)
        try ConfigLoader.save(config, to: configURL)
        XCTAssertEqual(try json()["note"] as? String, "keep me")
        XCTAssertEqual(try ConfigLoader.load(from: configURL), config)
    }

    // MARK: - Refusing to clobber

    func testMalformedJSONIsNeverOverwritten() throws {
        let broken = #"{"deepseek": {"apiKey": "sk-hand-edited",  "model": "m",}"#  // trailing comma, unclosed
        try write(broken)

        XCTAssertThrowsError(try ConfigLoader.save(config, to: configURL)) { error in
            guard case ConfigSaveError.invalidJSON(let url, _) = error else {
                return XCTFail("Expected invalidJSON, got \(error)")
            }
            XCTAssertEqual(url.lastPathComponent, "config.json")
            let message = error.localizedDescription
            XCTAssertTrue(message.contains("不是合法 JSON"), message)
            XCTAssertFalse(message.contains("sk-hand-edited"), "The error must never echo key material")
        }
        XCTAssertEqual(try String(contentsOf: configURL, encoding: .utf8), broken)
        XCTAssertNil(ConfigLoader.loadOptional(from: configURL))
    }

    func testNonObjectRootAndNonObjectDeepseekAreNeverOverwritten() throws {
        for original in ["[1, 2]", #"{"deepseek": "sk-string"}"#] {
            try write(original)
            XCTAssertThrowsError(try ConfigLoader.save(config, to: configURL), original) { error in
                guard case ConfigSaveError.unexpectedStructure = error else {
                    return XCTFail("Expected unexpectedStructure, got \(error)")
                }
            }
            XCTAssertEqual(try String(contentsOf: configURL, encoding: .utf8), original)
        }
    }

    func testFailedSaveDoesNotPostTheChangeNotification() throws {
        try write("not json")
        // queue: nil delivers synchronously on the posting thread, but the block is @Sendable, so
        // the flag lives in a lock-protected box rather than a captured var.
        let posted = OSAllocatedUnfairLock(initialState: false)
        let token = NotificationCenter.default.addObserver(forName: ConfigLoader.configChangedNotification,
                                                           object: nil, queue: nil) { _ in
            posted.withLock { $0 = true }
        }
        defer { NotificationCenter.default.removeObserver(token) }

        XCTAssertThrowsError(try ConfigLoader.save(config, to: configURL))
        XCTAssertFalse(posted.withLock { $0 })
    }

    // MARK: - Permissions

    func testSavedFileIsOwnerOnlyAndNewDirectoryIsPrivate() throws {
        XCTAssertFalse(FileManager.default.fileExists(atPath: configURL.deletingLastPathComponent().path))
        try ConfigLoader.save(config, to: configURL)

        XCTAssertEqual(try mode(of: configURL), 0o600)
        XCTAssertEqual(try mode(of: configURL.deletingLastPathComponent()), 0o700)
    }

    func testOverwritingAWorldReadableFileTightensItToOwnerOnly() throws {
        try write(#"{"deepseek":{"apiKey":"k"}}"#)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: configURL.path)

        try ConfigLoader.save(config, to: configURL)
        XCTAssertEqual(try mode(of: configURL), 0o600)
    }

    func testExistingDirectoryPermissionsAreLeftAlone() throws {
        let dir = configURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o755])
        try ConfigLoader.save(config, to: configURL)
        XCTAssertEqual(try mode(of: dir), 0o755, "An existing directory must never be chmod'ed")
    }

    func testSaveLeavesNoTemporaryFilesBehind() throws {
        try ConfigLoader.save(config, to: configURL)
        try ConfigLoader.save(config, to: configURL)
        let entries = try FileManager.default.contentsOfDirectory(atPath: configURL.deletingLastPathComponent().path)
        XCTAssertEqual(entries, ["config.json"])
    }

    func testSavingThroughASymlinkKeepsTheLinkAndUpdatesItsTarget() throws {
        let realDir = directory.appendingPathComponent("dotfiles", isDirectory: true)
        try FileManager.default.createDirectory(at: realDir, withIntermediateDirectories: true)
        let real = realDir.appendingPathComponent("real.json")
        try Data(#"{"keep":"me"}"#.utf8).write(to: real)
        let link = directory.appendingPathComponent("link.json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)

        try ConfigLoader.save(config, to: link)

        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link.path), real.path)
        let stored = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: real)) as? [String: Any])
        XCTAssertEqual(stored["keep"] as? String, "me")
        XCTAssertEqual(try ConfigLoader.load(from: link), config)
    }
}
