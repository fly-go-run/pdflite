import AppKit
import GRDB
import PDFKit
import XCTest

@MainActor
final class ReaderRegressionTests: XCTestCase {
    private var directory: URL!
    private var sessions: [DocumentSession] = []

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        for session in sessions {
            session.closeDocument()
            DocumentOpener.unregister(session)
        }
        sessions = []
        DocumentOpener.spawnWindow = nil
        try FileManager.default.removeItem(at: directory)
    }

    private func session(database: Database? = nil) -> DocumentSession {
        let database = database ?? Database(url: directory.appendingPathComponent(UUID().uuidString + ".sqlite"))
        let session = DocumentSession(documentRepository: DocumentRepository(database: database),
                                      annotationRepository: AnnotationRepository(database: database),
                                      didOpenDocument: { _ in })
        sessions.append(session)
        return session
    }

    private func pdf(_ name: String = "test", pages: Int = 3) throws -> URL {
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

    private func waitUntil(_ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !predicate(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(predicate(), "Timed out waiting for the reader state")
    }

    private func attachView(to session: DocumentSession) throws -> (ReaderPDFView, NSWindow) {
        let view = ReaderPDFView(frame: CGRect(x: 0, y: 0, width: 600, height: 500))
        let window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        view.document = try XCTUnwrap(session.document)
        view.displayMode = .singlePageContinuous
        view.autoScales = false
        view.scaleFactor = 1.5
        view.layoutSubtreeIfNeeded()
        session.pdfView = view
        session.restoreBridgeIfNeeded(in: view)
        return (view, window)
    }

    func testMultipleOpensReserveSessionsAndDeduplicatePendingURLs() throws {
        let urls = try (0..<3).map { try pdf("file\($0)") }
        let first = session()
        DocumentOpener.register(first)
        var windowRequests = 0
        DocumentOpener.spawnWindow = { windowRequests += 1 }

        for url in urls { DocumentOpener.requestOpen(url: url, preferring: first) }
        DocumentOpener.requestOpen(url: urls[0])
        DocumentOpener.requestOpen(url: urls[1])
        XCTAssertEqual(first.openingURL, urls[0])
        XCTAssertFalse(first.canAcceptOpen)
        XCTAssertEqual(windowRequests, 2)

        let second = session()
        DocumentOpener.register(second)
        let third = session()
        DocumentOpener.register(third)
        XCTAssertEqual(second.openingURL, urls[1])
        XCTAssertEqual(third.openingURL, urls[2])
        XCTAssertEqual(windowRequests, 2, "Registering requested windows must not spawn extra empty tabs")
    }

    func testFailedOpenReleasesReservationAndCloseCancelsLoad() async throws {
        let broken = directory.appendingPathComponent("broken.pdf")
        try Data("not a PDF".utf8).write(to: broken)
        let reader = session()
        reader.openDocument(url: broken)
        XCTAssertEqual(reader.openingURL, broken)
        try await waitUntil { reader.loadError != nil }
        XCTAssertTrue(reader.canAcceptOpen)

        reader.openDocument(url: try pdf())
        reader.closeDocument()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(reader.canAcceptOpen)
        XCTAssertFalse(reader.hasDocument)
    }

    func testEphemeralDatabaseIsVisibleAndDoesNotEnableHighlights() async throws {
        // Opening a directory as a SQLite file must fail without touching the real database.
        let database = Database(url: directory)
        XCTAssertFalse(database.isPersistent)
        let reader = session(database: database)
        reader.openDocument(url: try pdf())
        try await waitUntil { reader.annotationsReady }
        XCTAssertNotNil(reader.persistenceNotice)
        let page = try XCTUnwrap(reader.document?.page(at: 0))
        reader.handleSelectionChanged(SelectionSnapshot(pages: [PageSelection(
            pageIndex: 0, page: page, lineRects: [CGRect(x: 60, y: 760, width: 100, height: 20)], text: "Anchor"
        )], rawText: "Anchor"))
        XCTAssertFalse(reader.canHighlight)
        reader.highlightSelection()
        XCTAssertTrue(page.annotations.isEmpty)
    }

    func testReadingLocationMigrationPreservesExistingRecords() async throws {
        let url = directory.appendingPathComponent("migration.sqlite")
        let database = Database(url: url)
        let repository = DocumentRepository(database: database)
        let row = try await repository.upsert(fileHash: "same-content", fileURL: directory.appendingPathComponent("book.pdf"), title: "Book", pageCount: 8)
        let id = try XCTUnwrap(row.id)
        try await database.writer.write { db in
            try db.execute(sql: "UPDATE documents SET last_page = 4, last_zoom = 1.75 WHERE id = ?", arguments: [id])
            try db.execute(sql: "ALTER TABLE documents DROP COLUMN last_scroll_x")
            try db.execute(sql: "ALTER TABLE documents DROP COLUMN last_auto_scales")
            try db.execute(sql: "DELETE FROM grdb_migrations WHERE identifier = 'v7_reading_location'")
        }
        let migrated = Database(url: url)
        XCTAssertTrue(migrated.isPersistent)
        let migratedRepository = DocumentRepository(database: migrated)
        let stored = try await migratedRepository.find(byHash: "same-content")
        let old = try XCTUnwrap(stored)
        XCTAssertEqual(old.id, id)
        XCTAssertEqual(old.lastPage, 4)
        XCTAssertNil(ReadingLocation(record: old).point)
        XCTAssertFalse(ReadingLocation(record: old).autoScales)

        let location = ReadingLocation(pageIndex: 6, point: CGPoint(x: 30, y: 480), scale: 1.6, autoScales: true, displayMode: 3)
        try await migratedRepository.updateReadingState(documentId: id, location: location)
        let updated = try await migratedRepository.find(byHash: "same-content")
        XCTAssertEqual(ReadingLocation(record: try XCTUnwrap(updated)), location)
    }

    func testHistoryKeepsDifferentPositionsOnSamePageAndClearsForwardBranch() {
        let history = NavigationHistoryService()
        let top = ReadingLocation(pageIndex: 1, point: CGPoint(x: 0, y: 800))
        let middle = ReadingLocation(pageIndex: 1, point: CGPoint(x: 0, y: 400))
        let next = ReadingLocation(pageIndex: 2)
        history.recordJump(from: top)
        history.recordJump(from: middle)
        XCTAssertEqual(history.goBack(saving: next), middle)
        XCTAssertTrue(history.canGoForward)
        history.recordJump(from: top) // duplicate back entry must still discard the old branch
        XCTAssertFalse(history.canGoForward)
        XCTAssertEqual(history.goBack(saving: middle), top)
    }

    func testViewportRoundTripAndSearchReturnsToOriginOnce() async throws {
        let reader = session()
        reader.openDocument(url: try pdf())
        try await waitUntil { reader.annotationsReady }
        let (view, window) = try attachView(to: reader)
        defer { window.close() }
        let coordinator = PDFKitRepresentable.Coordinator(session: reader)
        coordinator.attach(view: view)
        NotificationCenter.default.addObserver(coordinator,
            selector: #selector(PDFKitRepresentable.Coordinator.selectionChanged(_:)),
            name: .PDFViewSelectionChanged, object: view)
        defer {
            coordinator.cancelPendingSelectionSnapshot()
            coordinator.detachScrollObserver()
            NotificationCenter.default.removeObserver(coordinator)
        }
        let initial = ReadingLocation(pageIndex: 0, point: CGPoint(x: 30, y: 540), scale: 1.5, autoScales: false)
        initial.restore(in: view)
        let origin = try XCTUnwrap(ReadingLocation.capture(in: view))
        ReadingLocation(pageIndex: 2).restore(in: view)
        origin.restore(in: view)
        let restored = try XCTUnwrap(ReadingLocation.capture(in: view))
        XCTAssertEqual(restored.point!.y, origin.point!.y, accuracy: 2)
        XCTAssertEqual(restored.point!.x, origin.point!.x, accuracy: 2)
        XCTAssertEqual(restored.scale!, origin.scale!, accuracy: 0.01)

        reader.toggleSearch(open: true)
        reader.search.query = "Anchor"
        reader.search.search(in: try XCTUnwrap(reader.document))
        try await waitUntil { !reader.search.isSearching && reader.search.totalResults == 36 }
        for _ in 0..<25 { reader.search.next() }
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertFalse(reader.hasSelection, "Programmatic search results must not trigger selection actions")
        reader.goBack()
        let returned = try XCTUnwrap(ReadingLocation.capture(in: view))
        XCTAssertEqual(returned.point!.y, origin.point!.y, accuracy: 2)
        XCTAssertEqual(returned.pageIndex, origin.pageIndex)
        XCTAssertFalse(reader.navigation.canGoBack)

        let page = try XCTUnwrap(reader.document?.page(at: 0))
        view.setCurrentSelection(page.selection(for: NSRange(location: 0, length: 6)), animate: false)
        try await waitUntil { reader.hasSelection }
        XCTAssertTrue(reader.hasSelection, "A user selection must remain available while search is open")
    }

    func testFlushAndReopenRestoreViewportAndFitIntent() async throws {
        let database = Database(url: directory.appendingPathComponent("reading.sqlite"))
        let url = try pdf()
        let reader = session(database: database)
        reader.openDocument(url: url)
        try await waitUntil { reader.annotationsReady }
        let (view, window) = try attachView(to: reader)
        defer { window.close() }
        ReadingLocation(pageIndex: 1, point: CGPoint(x: 25, y: 520), scale: 1.7,
                        autoScales: false).restore(in: view)
        reader.handleScrollActivity()
        let expected = try XCTUnwrap(ReadingLocation.capture(in: view))
        DocumentOpener.register(reader)
        DocumentOpener.flushAllReadingStates()
        let repository = DocumentRepository(database: database)
        let saved = try await repository.find(byURL: url)
        XCTAssertEqual(ReadingLocation(record: try XCTUnwrap(saved)), expected)
        reader.closeDocument()

        let reopened = session(database: database)
        reopened.openDocument(url: url)
        try await waitUntil { reopened.annotationsReady }
        let (reopenedView, reopenedWindow) = try attachView(to: reopened)
        defer { reopenedWindow.close() }
        let restored = try XCTUnwrap(ReadingLocation.capture(in: reopenedView))
        XCTAssertEqual(restored.pageIndex, expected.pageIndex)
        XCTAssertEqual(restored.point!.y, expected.point!.y, accuracy: 2)
        XCTAssertEqual(restored.scale!, expected.scale!, accuracy: 0.01)
        reopened.fitWidth()
        reopened.flushReadingState()
        let fitted = try await repository.find(byURL: url)
        XCTAssertEqual(fitted?.lastAutoScales, true)
    }

    func testSelectionSnapshotExtractsEachPagesOwnText() throws {
        let document = try XCTUnwrap(PDFDocument(url: pdf()))
        let first = try XCTUnwrap(document.page(at: 0))
        let second = try XCTUnwrap(document.page(at: 1))
        let selection = try XCTUnwrap(first.selection(for: NSRange(location: 0, length: 20)))
        selection.add(try XCTUnwrap(second.selection(for: NSRange(location: 0, length: 40))))
        let view = PDFView()
        view.document = document
        view.setCurrentSelection(selection, animate: false)
        let snapshot = try XCTUnwrap(SelectionService.snapshot(from: view))
        XCTAssertEqual(snapshot.pages.count, 2)
        XCTAssertTrue(snapshot.pages[0].text.contains("page 0"))
        XCTAssertFalse(snapshot.pages[0].text.contains("page 1"))
        XCTAssertTrue(snapshot.pages[1].text.contains("page 1"))
        XCTAssertFalse(snapshot.pages[1].text.contains("page 0"))
        XCTAssertGreaterThan(snapshot.pages[1].text.count, snapshot.pages[0].text.count)
    }

    func testMovedFileRestoresHashLocationBeforeBridgeHasDocument() async throws {
        let database = Database(url: directory.appendingPathComponent("moved.sqlite"))
        let url = try pdf("moved")
        let repository = DocumentRepository(database: database)
        let record = try await repository.upsert(fileHash: FileHash.sha256(of: url),
            fileURL: directory.appendingPathComponent("old-name.pdf"), title: "Original", pageCount: 3)
        let expected = ReadingLocation(pageIndex: 1, point: CGPoint(x: 25, y: 520),
                                       scale: 1.7, autoScales: false)
        try await repository.updateReadingState(documentId: XCTUnwrap(record.id), location: expected)
        let reader = session(database: database)
        let unattachedView = ReaderPDFView()
        reader.pdfView = unattachedView
        reader.openDocument(url: url)
        try await waitUntil { reader.annotationsReady }
        let (view, window) = try attachView(to: reader)
        defer { window.close() }
        let restored = try XCTUnwrap(ReadingLocation.capture(in: view))
        XCTAssertEqual(restored.pageIndex, expected.pageIndex)
        XCTAssertEqual(restored.point!.y, expected.point!.y, accuracy: 2)
        XCTAssertEqual(restored.scale!, expected.scale!, accuracy: 0.01)
    }

    func testCitationMatcherDoesNotInterceptSectionTitles() {
        for text in ["1.2 系统设计", "见第 3 章", "Figure 3", "1234", "[12", "12]", "12.3"] {
            XCTAssertNil(PDFKitRepresentable.Coordinator.referenceNumber(in: text), text)
        }
        for text in ["12", "[12]", "[12, 13]", "12–15", " [12] "] {
            XCTAssertEqual(PDFKitRepresentable.Coordinator.referenceNumber(in: text), 12, text)
        }
    }

    func testOutlineUsesPagePointAndKeepsParentForIdenticalDestinations() {
        let entries = [
            FlatOutlineEntry(id: "chapter", pageIndex: 0, ancestorIDs: [], point: CGPoint(x: 0, y: 800)),
            FlatOutlineEntry(id: "first", pageIndex: 0, ancestorIDs: ["chapter"], point: CGPoint(x: 0, y: 800)),
            FlatOutlineEntry(id: "second", pageIndex: 0, ancestorIDs: ["chapter"], point: CGPoint(x: 0, y: 400))
        ]
        XCTAssertEqual(FlatOutlineEntry.active(in: entries, at: ReadingLocation(pageIndex: 0, point: CGPoint(x: 0, y: 650)))?.id, "chapter")
        XCTAssertEqual(FlatOutlineEntry.active(in: entries, at: ReadingLocation(pageIndex: 0, point: CGPoint(x: 0, y: 300)))?.id, "second")
    }

    func testCrossPageHighlightsUseExactPageTextAndFailedDeleteKeepsDisplay() async throws {
        let database = Database(url: directory.appendingPathComponent("annotations.sqlite"))
        let reader = session(database: database)
        reader.openDocument(url: try pdf())
        try await waitUntil { reader.annotationsReady }
        let doc = try XCTUnwrap(reader.document)
        let page0 = try XCTUnwrap(doc.page(at: 0))
        let page1 = try XCTUnwrap(doc.page(at: 1))
        let pages = [PageSelection(pageIndex: 0, page: page0, lineRects: [CGRect(x: 60, y: 760, width: 100, height: 20)], text: "Short"),
                     PageSelection(pageIndex: 1, page: page1, lineRects: [CGRect(x: 60, y: 760, width: 300, height: 20)], text: "A much longer second page selection")]
        let records = try XCTUnwrap(reader.annotationService).createHighlight(
            snapshot: SelectionSnapshot(pages: pages, rawText: "Short\n\nA much longer second page selection"),
            documentId: try XCTUnwrap(reader.documentId))
        XCTAssertEqual(records.map(\.selectedText), pages.map { Optional($0.text) })
        let repository = AnnotationRepository(database: database)
        try await repository.insertAll(records)
        try await database.writer.write { db in
            try db.execute(sql: "CREATE TRIGGER deny_delete BEFORE DELETE ON annotations BEGIN SELECT RAISE(ABORT, 'test failure'); END")
        }
        reader.deleteAnnotation(groupId: records[0].groupId)
        try await waitUntil { reader.persistenceNotice != nil }
        XCTAssertEqual(page0.annotations.count, 1)
        XCTAssertEqual(page1.annotations.count, 1)
        let stored = try await repository.list(forDocumentId: try XCTUnwrap(reader.documentId))
        XCTAssertEqual(stored.count, 2)
    }
}
