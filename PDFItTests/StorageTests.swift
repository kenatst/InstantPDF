import XCTest
import UIKit
@testable import PDFIt

/// Library storage: persistence, deletion, renaming, collisions — and the
/// guarantee that documents are never auto-deleted.
final class StorageTests: XCTestCase {

    private var container: URL!
    private var storage: StorageManager!

    override func setUpWithError() throws {
        container = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdfit-storage-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
        storage = StorageManager(containerURL: container)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: container)
    }

    private func makeDocument(title: String, pages: Int = 1) throws -> ConvertedDocument {
        let bounds = CGRect(x: 0, y: 0, width: 400, height: 600)
        let renderer = UIGraphicsPDFRenderer(bounds: bounds)
        let data = renderer.pdfData { context in
            for index in 0..<pages {
                context.beginPage()
                "Page \(index)".draw(at: CGPoint(x: 20, y: 20),
                                     withAttributes: [.font: UIFont.systemFont(ofSize: 16)])
            }
        }
        return ConvertedDocument(data: data, pageCount: pages,
                                 suggestedTitle: title, sourceURL: nil, source: .photos)
    }

    // MARK: - Persistence

    func testSavePersistsRecordAndFile() throws {
        let document = try makeDocument(title: "Holiday Photos")
        let record = try storage.save(document: document)

        XCTAssertEqual(storage.fetchRecords().count, 1)
        XCTAssertEqual(record.pageCount, 1)
        XCTAssertEqual(record.sourceType, ContentSource.photos.rawValue)
        XCTAssertEqual(record.fileSize, Int64(document.data.count))

        let url = try XCTUnwrap(storage.fileURL(for: record))
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        XCTAssertTrue(record.filename.hasSuffix(".pdf"))
        XCTAssertTrue(record.filename.hasPrefix("Holiday Photos"),
                      "Filenames should be human: \(record.filename)")
    }

    func testRecordsSurviveReload() throws {
        try storage.save(document: makeDocument(title: "First"))
        try storage.save(document: makeDocument(title: "Second"))

        // A fresh manager over the same container must see both records.
        let reloaded = StorageManager(containerURL: container)
        XCTAssertEqual(reloaded.fetchRecords().count, 2)
        XCTAssertTrue(reloaded.fetchRecords().first?.displayName.hasPrefix("Second") == true,
                      "Newest first, with its date suffix")
    }

    // MARK: - No silent deletion

    func testDocumentsAreNeverAutoDeleted() throws {
        for index in 0..<30 {
            try storage.save(document: makeDocument(title: "Doc \(index)"))
        }
        XCTAssertEqual(storage.fetchRecords().count, 30,
                       "User documents must never be pruned just because history grew")
        for record in storage.fetchRecords() {
            XCTAssertTrue(storage.exists(record), "Every saved PDF still exists on disk")
        }
    }

    // MARK: - Deletion

    func testExplicitDeleteRemovesRecordAndFile() throws {
        let record = try storage.save(document: makeDocument(title: "To Delete"))
        try storage.delete(record)

        XCTAssertTrue(storage.fetchRecords().isEmpty)
        XCTAssertFalse(storage.exists(record))
    }

    func testDeleteTwiceIsSafe() throws {
        let record = try storage.save(document: makeDocument(title: "To Delete"))
        try storage.delete(record)
        XCTAssertNoThrow(try storage.delete(record))
    }

    // MARK: - Collisions

    func testDuplicateNamesGetNumericSuffix() throws {
        try storage.save(document: makeDocument(title: "Report"))
        let second = try storage.save(document: makeDocument(title: "Report"))

        // Photo-source names carry a date suffix; collisions append " 2".
        XCTAssertTrue(second.filename.hasPrefix("Report — "), second.filename)
        XCTAssertTrue(second.filename.hasSuffix(" 2.pdf"), second.filename)
        XCTAssertEqual(storage.fetchRecords().count, 2,
                       "Never silently overwrite an existing PDF")
    }

    // MARK: - Rename

    func testRenameMovesFileAndUpdatesRecord() throws {
        let record = try storage.save(document: makeDocument(title: "Old Name"))
        let updated = try storage.rename(record, to: "New Name")

        XCTAssertEqual(updated.displayName, "New Name")
        XCTAssertTrue(storage.exists(updated))
        XCTAssertFalse(storage.exists(record), "Old path is gone")
        XCTAssertEqual(storage.fetchRecords().count, 1)
    }

    func testRenameCollidesGracefully() throws {
        let first = try storage.save(document: makeDocument(title: "Alpha"))
        let beta = try storage.save(document: makeDocument(title: "Beta"))
        let renamed = try storage.rename(first, to: beta.displayName)

        XCTAssertEqual(renamed.displayName, beta.displayName + " 2")
        XCTAssertEqual(storage.fetchRecords().count, 2)
    }

    // MARK: - Duplicate

    func testDuplicateCreatesIndependentCopy() throws {
        let record = try storage.save(document: makeDocument(title: "Original"))
        let copy = try XCTUnwrap(try storage.duplicate(record))

        XCTAssertEqual(storage.fetchRecords().count, 2)
        XCTAssertNotEqual(record.id, copy.id)
        XCTAssertTrue(storage.exists(record))
        XCTAssertTrue(storage.exists(copy))
    }

    // MARK: - Ghost pruning

    func testMissingFilesArePrunedFromIndexNotCountedAsData() throws {
        try storage.save(document: makeDocument(title: "Ghost"))

        // Simulate the file vanishing outside the app.
        let reloaded = StorageManager(containerURL: container)
        let record = try XCTUnwrap(reloaded.fetchRecords().first)
        try? FileManager.default.removeItem(at: reloaded.fileURL(for: record)!)

        let afterLoss = StorageManager(containerURL: container)
        XCTAssertTrue(afterLoss.fetchRecords().isEmpty,
                      "Records whose file is gone are pruned from the index")
    }

    func testFallbackReconciliationMigratesStrandedRecords() throws {
        // Create local fallback container
        let localDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LocalLibrary", isDirectory: true)
        try FileManager.default.createDirectory(at: localDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: localDir) }

        let localManager = StorageManager(containerURL: localDir)
        let saved = try localManager.save(document: makeDocument(title: "Stranded Fallback Scan"))
        XCTAssertEqual(localManager.fetchRecords().count, 1)

        // Mock App Group container with the bundle group identifier in path
        let appGroupDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("group.com.kenatst.pdfit-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: appGroupDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: appGroupDir) }

        let appGroupManager = StorageManager(containerURL: appGroupDir)
        appGroupManager.reconcileLocalFallbackIfNeeded()

        // App Group should now have the migrated record
        let migratedRecords = appGroupManager.fetchRecords()
        XCTAssertEqual(migratedRecords.count, 1)
        XCTAssertEqual(migratedRecords.first?.id, saved.id)
        XCTAssertTrue(appGroupManager.exists(migratedRecords[0]))
    }
}
