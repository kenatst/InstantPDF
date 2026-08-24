import XCTest
import PDFKit
import UIKit
@testable import PDFIt

/// IDENTITY INTEGRATION REGRESSIONS.
///
/// The shipped bug: tapping one PDF sometimes opened another, and some PDFs
/// wouldn't open at all. These tests encode the contract that would have
/// caught it: whatever the sort order / filter / folder / rename / delete
/// neighborhood, resolving a persistent record ID must yield EXACTLY that
/// document's file.
final class LibraryIdentityTests: XCTestCase {

    private var container: URL!
    private var storage: StorageManager!

    override func setUpWithError() throws {
        container = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdfit-identity-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
        storage = StorageManager(containerURL: container)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: container)
    }

    /// Makes a PDF whose first page carries a unique marker so we can verify
    /// WHICH document the viewer would actually show.
    private func makeMarkedPDF(marker: String) -> Data {
        let bounds = CGRect(x: 0, y: 0, width: 400, height: 600)
        return UIGraphicsPDFRenderer(bounds: bounds).pdfData { context in
            context.beginPage()
            marker.draw(at: CGPoint(x: 30, y: 30),
                        withAttributes: [.font: UIFont.boldSystemFont(ofSize: 36)])
        }
    }

    @discardableResult
    private func saveNamed(_ name: String) throws -> StoredPDFRecord {
        let document = ConvertedDocument(data: makeMarkedPDF(marker: "MARKER-\(name)"),
                                         pageCount: 1,
                                         suggestedTitle: name,
                                         sourceURL: nil,
                                         source: .photos)
        return try storage.save(document: document)
    }

    // MARK: - Core identity contract

    func testTapBIdentityResolvesBFile() throws {
        _ = try saveNamed("AAA")
        let b = try saveNamed("BBB")
        _ = try saveNamed("CCC")

        // Simulate exactly what the viewer does with a tapped record ID:
        let resolved = try XCTUnwrap(storage.record(withID: b.id))
        XCTAssertEqual(resolved.id, b.id)
        XCTAssertEqual(resolved.filename, b.filename)
        let text = PDFDocument(url: try XCTUnwrap(storage.fileURL(for: resolved)))?
            .page(at: 0)?.string ?? ""
        XCTAssertTrue(text.contains("MARKER-BBB"),
                      "tapping B must display B's content; got \(text)")
    }

    func testDifferentSortOrderKeepsSameIDSameFile() throws {
        let records = (0..<20).map { index -> StoredPDFRecord in
            try! saveNamed("Doc-\(String(format: "%02d", index))")
        }
        // Shuffle "display order" — resolution must be order-independent.
        for record in records.shuffled() {
            let resolved = storage.record(withID: record.id)
            XCTAssertEqual(resolved?.filename, record.filename)
        }
    }

    func testSearchFilterDoesNotAffectResolution() throws {
        _ = try saveNamed("Alpha Report")
        let target = try saveNamed("Beta Invoice")
        _ = try saveNamed("Gamma Notes")

        // UI filters by search text, then taps the surviving row:
        let filtered = storage.fetchRecords()
            .filter { $0.displayName.localizedCaseInsensitiveContains("beta") }
        XCTAssertEqual(filtered.count, 1)
        let tapped = filtered[0]
        XCTAssertEqual(storage.record(withID: tapped.id)?.id, target.id)
    }

    func testRenameKeepsIdentityStable() throws {
        let original = try saveNamed("Old Name")
        let updated = try storage.rename(original, to: "Brand New Name")

        let resolved = try XCTUnwrap(storage.record(withID: original.id))
        XCTAssertEqual(resolved.id, original.id)
        XCTAssertEqual(resolved.displayName, "Brand New Name")
        XCTAssertEqual(resolved.filename, updated.filename)
    }

    func testMoveToFolderKeepsIdentityStable() throws {
        let folder = try storage.createFolder(named: "Work")
        let record = try saveNamed("Movable")
        try storage.move(records: [record], toFolder: folder.id)

        let resolved = try XCTUnwrap(storage.record(withID: record.id))
        XCTAssertEqual(resolved.folderID, folder.id)
        XCTAssertTrue(try XCTUnwrap(storage.fileURL(for: resolved)).lastPathComponent == record.filename)
    }

    func testDeleteNeighborDoesNotBreakOtherIDs() throws {
        let a = try saveNamed("Neighbor A")
        let b = try saveNamed("Neighbor B")
        let c = try saveNamed("Neighbor C")

        try storage.delete(a)

        XCTAssertNil(storage.record(withID: a.id), "deleted ID must not resolve")
        let resolvedB = try XCTUnwrap(storage.record(withID: b.id))
        XCTAssertEqual(resolvedB.filename, b.filename)
        let resolvedC = try XCTUnwrap(storage.record(withID: c.id))
        XCTAssertEqual(resolvedC.filename, c.filename)
    }

    func testDuplicateFilenamesEachResolveOwnFile() throws {
        // Two DIFFERENT documents saved under the same visible title —
        // FilenameGenerator uniquifies on-disk names ("X.pdf", "X 2.pdf").
        let first = try saveNamed("Invoice")
        let second = try saveNamed("Invoice")

        XCTAssertNotEqual(first.filename, second.filename,
                          "collisions must get unique on-disk names")
        let r1 = try XCTUnwrap(storage.record(withID: first.id))
        let r2 = try XCTUnwrap(storage.record(withID: second.id))
        XCTAssertNotEqual(r1.relativePath, r2.relativePath,
                          "each identity maps to its own file path")

        // And each file contains its own marker.
        let text1 = PDFDocument(url: try XCTUnwrap(storage.fileURL(for: r1)))?.page(at: 0)?.string ?? ""
        let text2 = PDFDocument(url: try XCTUnwrap(storage.fileURL(for: r2)))?.page(at: 0)?.string ?? ""
        XCTAssertTrue(text1.contains("MARKER-Invoice"))
        XCTAssertTrue(text2.contains("MARKER-Invoice"))
    }

    func testMissingFileResolvesRecordButViewerShowsMissingState() throws {
        let record = try saveNamed("Vanishing")
        // File vanishes out-of-band (iCloud purge, user fiddling…).
        try FileManager.default.removeItem(at: XCTUnwrap(storage.fileURL(for: record)))

        // Record still resolves (metadata intact)…
        let resolved = storage.record(withID: record.id)
        XCTAssertNotNil(resolved)
        // …but its file is gone — the viewer's fileIsAvailable check fails,
        // showing the missing-document state. It NEVER falls back to another
        // document's file because navigation only carries the ID + relativePath.
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: storage.fileURL(for: try XCTUnwrap(resolved))!.path))
    }

    func testHundredPDFsAllResolveExactlyByID() throws {
        var ids: [UUID] = []
        var names: [String] = []
        for index in 0..<100 {
            let name = "Scale-\(String(format: "%03d", index))"
            names.append(name)
            ids.append(try saveNamed(name).id)
        }
        for (id, name) in zip(ids, names) {
            let resolved = try XCTUnwrap(storage.record(withID: id))
            XCTAssertTrue(resolved.filename.hasPrefix(name),
                          "\(resolved.filename) must resolve to \(name)")
        }
    }

    // MARK: - Tool outputs keep the identity contract

    func testToolOutputCreatesNewDistinctRecordAndOriginalUntouched() throws {
        let original = try saveNamed("Source Doc")
        let originalBytes = try Data(contentsOf: XCTUnwrap(storage.fileURL(for: original)))
        let pageCountBefore = PDFAssembly.pageCount(of: originalBytes)

        // Simulate an extract-style output through the same save path tools use.
        let extractedData = try PDFTools.extractPages(from: XCTUnwrap(storage.fileURL(for: original)),
                                                      pageNumbers: [1])
        let outputName = "\(original.displayName) — Extract"
        let outputDocument = ConvertedDocument(data: extractedData,
                                               pageCount: PDFAssembly.pageCount(of: extractedData),
                                               suggestedTitle: outputName,
                                               sourceURL: nil,
                                               source: original.contentSource)
        let newRecord = try storage.save(document: outputDocument)

        // New record is distinct and opens ITS OWN file.
        XCTAssertNotEqual(newRecord.id, original.id)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(storage.fileURL(for: original))), originalBytes,
                       "original bytes untouched")
        XCTAssertEqual(PDFAssembly.pageCount(of: originalBytes), pageCountBefore)
        let newText = PDFDocument(data: extractedData)?.page(at: 0)?.string ?? ""
        XCTAssertTrue(newText.contains("MARKER-Source Doc"))
    }
}
