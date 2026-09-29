import AppKit
import PDFKit
import SwiftUI
import XCTest

/// Reading-position restore when the saved position is only found once the full-file hash
/// resolves (moved / renamed file), plus the first-layout timing of the point-level restore.
///
/// The tests drive the real `PDFKitRepresentable` (makeNSView / updateNSView / Coordinator
/// notifications) inside a fully transparent window that is never ordered front, and hold the hash
/// back so the view is attached — and PDFKit has posted its own layout notifications — BEFORE the
/// hash lands. Temp PDFs and databases only.
@MainActor
final class PositionRestoreTests: XCTestCase {
    private var directory: URL!
    private var sessions: [DocumentSession] = []
    private var windows: [NSWindow] = []

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        for window in windows { window.contentView = nil; window.close() }
        windows = []
        for session in sessions {
            session.closeDocument()
            DocumentOpener.unregister(session)
        }
        sessions = []
        try FileManager.default.removeItem(at: directory)
    }

    // MARK: - Helpers

    /// Holds the content hash of a file back until `release()`, so a test decides what happens on
    /// screen before the hash resolves. Blocks a background thread only.
    private final class HashGate: @unchecked Sendable {
        private let semaphore = DispatchSemaphore(value: 0)
        private let lock = NSLock()
        private var cancelled = false
        private var released = false

        func release() { semaphore.signal() }
        /// Whether the hasher's task had been cancelled by the time it was released.
        var sawCancellation: Bool { lock.withLock { cancelled } }
        var didRun: Bool { lock.withLock { released } }

        var hasher: @Sendable (URL) throws -> String {
            { [self] url in
                semaphore.wait()
                let isCancelled = Task.isCancelled
                lock.withLock { cancelled = isCancelled; released = true }
                if isCancelled { throw CancellationError() }
                return try FileHash.sha256(of: url)
            }
        }
    }

    private struct Fixture {
        let repository: DocumentRepository
        let database: Database
        let hash: String
        let movedURL: URL
        let saved: ReadingLocation
    }

    private func session(database: Database,
                         didOpen: @escaping (URL) -> Void = { _ in },
                         hasher: (@Sendable (URL) throws -> String)? = nil) -> DocumentSession {
        let session = DocumentSession(documentRepository: DocumentRepository(database: database),
                                      annotationRepository: AnnotationRepository(database: database),
                                      didOpenDocument: didOpen,
                                      fileHasher: hasher ?? { try FileHash.sha256(of: $0) })
        sessions.append(session)
        return session
    }

    private func pdf(_ name: String, pages: Int = 8) throws -> URL {
        let data = NSMutableData()
        let consumer = try XCTUnwrap(CGDataConsumer(data: data))
        var box = CGRect(x: 0, y: 0, width: 600, height: 900)
        let context = try XCTUnwrap(CGContext(consumer: consumer, mediaBox: &box, nil))
        for index in 0..<pages {
            context.beginPDFPage(nil)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
            for row in 0..<12 {
                ("Anchor page \(index) line \(row)" as NSString).draw(
                    at: CGPoint(x: 60, y: 800 - row * 40),
                    withAttributes: [.font: NSFont.systemFont(ofSize: 16)]
                )
            }
            NSGraphicsContext.restoreGraphicsState()
            context.endPDFPage()
        }
        context.closePDF()
        let url = directory.appendingPathComponent(name + ".pdf")
        try (data as Data).write(to: url)
        return url
    }

    /// A record saved under an OLD path with the file's real hash, and a byte-identical copy at a
    /// NEW path that has no record of its own — the "moved / renamed" case.
    private func movedFileFixture() async throws -> Fixture {
        let database = Database(url: directory.appendingPathComponent(UUID().uuidString + ".sqlite"))
        let original = try pdf("old-name")
        let hash = try FileHash.sha256(of: original)
        let repository = DocumentRepository(database: database)
        let record = try await repository.upsert(fileHash: hash,
            fileURL: directory.appendingPathComponent("old-name.pdf"), title: "Original", pageCount: 8)
        let saved = ReadingLocation(pageIndex: 4, point: CGPoint(x: 25, y: 520),
                                    scale: 1.7, autoScales: false)
        try await repository.updateReadingState(documentId: XCTUnwrap(record.id), location: saved)
        let moved = directory.appendingPathComponent("new-name.pdf")
        try FileManager.default.copyItem(at: original, to: moved)
        return Fixture(repository: repository, database: database, hash: hash,
                       movedURL: moved, saved: saved)
    }

    private func waitUntil(_ message: String = "Timed out waiting for the reader state",
                           _ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !predicate(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(predicate(), message)
    }

    private func spin(_ milliseconds: Int) async throws {
        try await Task.sleep(for: .milliseconds(milliseconds))
    }

    /// Hosts `PDFKitRepresentable` in a borderless window that is fully transparent, ignores mouse
    /// events, can never become key and is never ordered front — invisible and unable to take
    /// focus. (SwiftUI still runs makeNSView / updateNSView and PDFKit still lays out and posts
    /// its notifications without the window being ordered in.)
    @discardableResult
    private func host(_ session: DocumentSession) -> NSWindow {
        let hosting = NSHostingView(rootView: PDFKitRepresentable(session: session))
        hosting.frame = CGRect(x: 0, y: 0, width: 600, height: 500)
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.alphaValue = 0
        window.ignoresMouseEvents = true
        window.hasShadow = false
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        windows.append(window)
        return window
    }

    /// A `ReaderPDFView` attached to `reader` at zero size — the state SwiftUI hands over — inside
    /// an invisible window. Wired the way `PDFKitRepresentable.makeNSView` wires the size handler.
    private func unsizedView(for reader: DocumentSession) throws -> ReaderPDFView {
        let container = NSView(frame: CGRect(x: 0, y: 0, width: 600, height: 500))
        let window = NSWindow(contentRect: container.frame, styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.alphaValue = 0
        window.ignoresMouseEvents = true
        window.contentView = container
        windows.append(window)
        let view = ReaderPDFView(frame: .zero)
        container.addSubview(view)
        view.document = try XCTUnwrap(reader.document)
        reader.pdfView = view
        view.sizeBecameUsableHandler = { [weak view, weak reader] in
            guard let view else { return }
            reader?.restoreBridgeIfNeeded(in: view)
        }
        return view
    }

    private func assertLocation(_ actual: ReadingLocation?, matches expected: ReadingLocation,
                                _ context: String, file: StaticString = #filePath, line: UInt = #line) {
        guard let actual else {
            return XCTFail("\(context): no location captured", file: file, line: line)
        }
        XCTAssertEqual(actual.pageIndex, expected.pageIndex, "\(context): page", file: file, line: line)
        XCTAssertEqual(actual.point?.y ?? .nan, expected.point!.y, accuracy: 2, "\(context): y", file: file, line: line)
        XCTAssertEqual(actual.point?.x ?? .nan, expected.point!.x, accuracy: 2, "\(context): x", file: file, line: line)
        XCTAssertEqual(actual.scale ?? .nan, expected.scale!, accuracy: 0.01, "\(context): scale", file: file, line: line)
    }

    /// Opens the moved file with the hash held back, attaches the real bridge and lets PDFKit post
    /// its own layout notifications. Returns with the hash still unresolved.
    private func openMovedFileWithViewAttachedBeforeHash(
        _ fixture: Fixture, gate: HashGate
    ) async throws -> (DocumentSession, ReaderPDFView) {
        let reader = session(database: fixture.database, hasher: gate.hasher)
        reader.openDocument(url: fixture.movedURL)
        try await waitUntil { reader.hasDocument }
        XCTAssertNil(reader.documentId, "the hash is still held back")
        host(reader)
        try await spin(400)
        let view = try XCTUnwrap(reader.pdfView)
        XCTAssertNotNil(view.window, "the bridge view must be attached before the hash resolves")
        XCTAssertNil(reader.documentId)
        return (reader, view)
    }

    // MARK: - Moved file: hash-matched location vs. PDFKit's own notifications

    /// Moved file, view attached (and laid out by PDFKit) before the hash resolves. PDFKit's own
    /// page / scale / scroll notifications must not be mistaken for the user navigating: the
    /// hash-matched saved position is applied, and a later flush doesn't overwrite it with page 0.
    func testMovedFileKeepsSavedLocationWhenViewAttachesBeforeHash() async throws {
        let fixture = try await movedFileFixture()
        let gate = HashGate()
        let (reader, view) = try await openMovedFileWithViewAttachedBeforeHash(fixture, gate: gate)

        gate.release()
        try await waitUntil("hash never resolved") { reader.annotationsReady }
        try await spin(200)

        assertLocation(ReadingLocation.capture(in: view), matches: fixture.saved, "moved file")
        reader.flushReadingState()
        let saved = try await fixture.repository.find(byHash: fixture.hash)
        XCTAssertEqual(saved.map(ReadingLocation.init(record:))?.pageIndex, fixture.saved.pageIndex,
                       "a flush overwrote the saved reading position of the moved file")
    }

    /// While the hash is unresolved the session has no document identity, so nothing may be written
    /// no matter how many layout notifications PDFKit posts or how often a flush is requested.
    func testFlushBeforeHashResolvesLeavesSavedLocationUntouched() async throws {
        let fixture = try await movedFileFixture()
        let gate = HashGate()
        let (reader, _) = try await openMovedFileWithViewAttachedBeforeHash(fixture, gate: gate)

        reader.flushReadingState()
        try await spin(700) // longer than the save debounce
        let before = try await fixture.repository.find(byHash: fixture.hash)
        XCTAssertEqual(before.map(ReadingLocation.init(record:)), fixture.saved)
        gate.release()
    }

    /// The user scrolls (real input path: `ReaderPDFView.scrollWheel`) while the hash is pending.
    /// That is navigation: the saved position must not yank the view away afterwards.
    func testUserScrollBeforeHashWinsOverSavedLocation() async throws {
        let fixture = try await movedFileFixture()
        let gate = HashGate()
        let (reader, view) = try await openMovedFileWithViewAttachedBeforeHash(fixture, gate: gate)

        let cgEvent = try XCTUnwrap(CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1,
                                            wheel1: -30, wheel2: 0, wheel3: 0))
        view.scrollWheel(with: try XCTUnwrap(NSEvent(cgEvent: cgEvent)))
        let userLocation = try XCTUnwrap(ReadingLocation.capture(in: view))
        XCTAssertEqual(userLocation.pageIndex, 0)

        gate.release()
        try await waitUntil("hash never resolved") { reader.annotationsReady }
        try await spin(200)

        let after = try XCTUnwrap(ReadingLocation.capture(in: view))
        XCTAssertEqual(after.pageIndex, 0, "the saved page must not override a user scroll")
        XCTAssertTrue(after.autoScales, "the saved (fixed) zoom must not override a user scroll")
    }

    /// A navigation command that stays on the presented page (zoom) also counts as the user taking
    /// control — only the page-index backstop can't catch this one.
    func testZoomCommandBeforeHashWinsOverSavedLocation() async throws {
        let fixture = try await movedFileFixture()
        let gate = HashGate()
        let (reader, view) = try await openMovedFileWithViewAttachedBeforeHash(fixture, gate: gate)

        reader.zoomIn()
        gate.release()
        try await waitUntil("hash never resolved") { reader.annotationsReady }
        try await spin(200)

        let after = try XCTUnwrap(ReadingLocation.capture(in: view))
        XCTAssertEqual(after.pageIndex, 0)
        XCTAssertNotEqual(after.scale ?? 0, fixture.saved.scale ?? 0, accuracy: 0.01)
    }

    /// A page change nobody attributed to an input hook (thumbnail click, scroller drag → PDFKit
    /// moves the page itself) still counts as the user having moved on.
    func testUnattributedPageChangeBeforeHashIsNotOverridden() async throws {
        let fixture = try await movedFileFixture()
        let gate = HashGate()
        let (reader, view) = try await openMovedFileWithViewAttachedBeforeHash(fixture, gate: gate)

        view.go(to: try XCTUnwrap(view.document?.page(at: 2)))
        try await spin(150)
        XCTAssertEqual(reader.currentPageIndex, 2)

        gate.release()
        try await waitUntil("hash never resolved") { reader.annotationsReady }
        try await spin(200)
        XCTAssertEqual(ReadingLocation.capture(in: view)?.pageIndex, 2)
        reader.flushReadingState()
        let saved = try await fixture.repository.find(byHash: fixture.hash)
        XCTAssertEqual(saved?.lastPage, 2, "the user's own page is what gets saved")
    }

    // MARK: - First-layout timing of the point-level restore

    /// The point-level restore used to run inside the first `updateNSView`, when the PDFView is
    /// still zero-sized and windowless, and PDFKit settled on the page top. The intra-page offset
    /// and scale must survive the first real layout.
    func testURLMatchedLocationSurvivesFirstLayout() async throws {
        let database = Database(url: directory.appendingPathComponent("url.sqlite"))
        let url = try pdf("same-place")
        let repository = DocumentRepository(database: database)
        let record = try await repository.upsert(fileHash: FileHash.sha256(of: url), fileURL: url,
                                                 title: "Same", pageCount: 8)
        let saved = ReadingLocation(pageIndex: 4, point: CGPoint(x: 25, y: 520),
                                    scale: 1.7, autoScales: false)
        try await repository.updateReadingState(documentId: XCTUnwrap(record.id), location: saved)

        let reader = session(database: database)
        reader.openDocument(url: url)
        try await waitUntil { reader.annotationsReady }
        host(reader)
        try await spin(400)
        assertLocation(ReadingLocation.capture(in: try XCTUnwrap(reader.pdfView)), matches: saved,
                       "URL-matched restore")
    }

    /// Zero-sized view first, real size later: the restore waits (and history / flushes keep seeing
    /// the pending location, not the unrestored view), then lands on the first real size.
    func testRestoreWaitsForFirstUsableSize() async throws {
        let database = Database(url: directory.appendingPathComponent("sized.sqlite"))
        let url = try pdf("sized")
        let repository = DocumentRepository(database: database)
        let record = try await repository.upsert(fileHash: FileHash.sha256(of: url), fileURL: url,
                                                 title: "Sized", pageCount: 8)
        let saved = ReadingLocation(pageIndex: 3, point: CGPoint(x: 30, y: 480),
                                    scale: 1.4, autoScales: false)
        try await repository.updateReadingState(documentId: XCTUnwrap(record.id), location: saved)

        let reader = session(database: database)
        reader.openDocument(url: url)
        try await waitUntil { reader.annotationsReady }

        let view = try unsizedView(for: reader)
        reader.restoreBridgeIfNeeded(in: view)
        XCTAssertTrue(reader.needsBridgeRestore, "an unsized view must not consume the pending restore")
        reader.flushReadingState()
        let whileUnsized = try await repository.find(byURL: url)
        XCTAssertEqual(whileUnsized.map(ReadingLocation.init(record:)), saved,
                       "until then a flush writes the pending location, not the unrestored view")

        view.setFrameSize(CGSize(width: 600, height: 500))
        view.layoutSubtreeIfNeeded()
        XCTAssertFalse(reader.needsBridgeRestore)
        try await spin(200)
        assertLocation(ReadingLocation.capture(in: view), matches: saved, "restore after first size")
    }

    /// Moved file whose hash lands while the view still has no size: the hash-matched location
    /// replaces the pending one and is applied on the first real size.
    func testMovedFileWhoseHashLandsBeforeFirstSizeRestoresOnFirstSize() async throws {
        let fixture = try await movedFileFixture()
        let gate = HashGate()
        let reader = session(database: fixture.database, hasher: gate.hasher)
        reader.openDocument(url: fixture.movedURL)
        try await waitUntil { reader.hasDocument }
        let view = try unsizedView(for: reader)
        reader.restoreBridgeIfNeeded(in: view)
        XCTAssertTrue(reader.needsBridgeRestore)

        gate.release()
        try await waitUntil("hash never resolved") { reader.annotationsReady }
        XCTAssertTrue(reader.needsBridgeRestore, "still waiting for a usable size")
        reader.flushReadingState()
        let whileUnsized = try await fixture.repository.find(byHash: fixture.hash)
        XCTAssertEqual(whileUnsized.map(ReadingLocation.init(record:)), fixture.saved,
                       "a flush before the first size writes the hash-matched location, not page 0")

        view.setFrameSize(CGSize(width: 600, height: 500))
        view.layoutSubtreeIfNeeded()
        try await spin(200)
        assertLocation(ReadingLocation.capture(in: view), matches: fixture.saved, "moved file, late size")
    }

    // MARK: - Open pipeline

    /// Cancelling an open (window closed, another file requested) must reach the detached hash
    /// task, otherwise a large file keeps being read to the end for nobody.
    func testClosingDuringHashCancelsTheHashTask() async throws {
        let fixture = try await movedFileFixture()
        let gate = HashGate()
        let reader = session(database: fixture.database, hasher: gate.hasher)
        reader.openDocument(url: fixture.movedURL)
        try await waitUntil { reader.hasDocument }

        reader.closeDocument()
        gate.release()
        try await waitUntil("hasher never ran") { gate.didRun }
        XCTAssertTrue(gate.sawCancellation, "closing the document must cancel the in-flight hash")
        let row = try await fixture.repository.find(byHash: fixture.hash)
        XCTAssertEqual(row.map(ReadingLocation.init(record:)), fixture.saved,
                       "a cancelled open must not touch the saved location")
    }

    /// A PDF that parses but has no pages (typically a truncated download) is an open failure: a
    /// clear error, no reader, no database row, no recents entry. This macOS's PDFKit returns nil
    /// for every truncated / hand-made zero-page file I could construct (those already take the
    /// generic failure path), so the parser is injected to hand back an empty `PDFDocument`.
    func testZeroPagePDFIsAnOpenFailure() async throws {
        let url = try pdf("no-pages", pages: 1)
        XCTAssertEqual(PDFDocument().pageCount, 0)

        let database = Database(url: directory.appendingPathComponent("empty.sqlite"))
        var opened: [URL] = []
        let reader = DocumentSession(
            documentRepository: DocumentRepository(database: database),
            annotationRepository: AnnotationRepository(database: database),
            didOpenDocument: { opened.append($0) },
            documentParser: { _ in ParsedDocument(document: PDFDocument(), outline: nil, isLikelyScanned: false) })
        sessions.append(reader)
        reader.openDocument(url: url)
        XCTAssertEqual(reader.openingURL, url)
        try await waitUntil { reader.loadError != nil }

        XCTAssertTrue(reader.loadError?.contains("no-pages.pdf") == true)
        XCTAssertTrue(reader.loadError?.contains("不含任何页面") == true, reader.loadError ?? "")
        XCTAssertFalse(reader.hasDocument)
        XCTAssertEqual(reader.pageCount, 0)
        XCTAssertTrue(reader.canAcceptOpen, "the reservation must be released so another file can open")
        XCTAssertTrue(opened.isEmpty, "a failed open must not reach recents")
        try await spin(150)
        let row = try await DocumentRepository(database: database).find(byURL: url)
        XCTAssertNil(row, "a failed open must not leave a database row")
        XCTAssertNil(reader.documentId)
    }
}
