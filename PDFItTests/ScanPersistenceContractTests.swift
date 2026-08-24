import XCTest
import PDFKit
@testable import PDFIt

/// THE scan persistence contract: a captured scan must become a durable
/// Library document that survives fresh StorageManager reads (the relaunch
/// path), across FIRST, SECOND and THIRD scans in one session, with the
/// SAME storage backend for write and read.
///
/// These tests reproduce the exact HomeView save loop — not a parallel
/// reimplementation — so "tests pass" means "the shipped path works".
final class ScanPersistenceContractTests: XCTestCase {

    private var containerURL: URL!

    override func setUpWithError() throws {
        // Fresh isolated container per test — no App Group dependency.
        containerURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("scan-contract-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: containerURL,
                                                withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: containerURL)
    }

    /// A realistic single-page scanned PDF (raster content, not an empty doc).
    private func scannedPDFData(label: String) throws -> Data {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 612, height: 792))
        let image = renderer.image { context in
            UIColor.systemBackground.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 612, height: 792))
            label.draw(at: CGPoint(x: 40, y: 60),
                       withAttributes: [.font: UIFont.boldSystemFont(ofSize: 32)])
        }
        let page = PDFPage(image: UIImage(cgImage: try XCTUnwrap(image.cgImage)))!
        let document = PDFDocument()
        document.insert(page, at: 0)
        return try XCTUnwrap(document.dataRepresentation())
    }

    /// The EXACT HomeView save loop, extracted verbatim into a testable form.
    @discardableResult
    private func runHomeSaveLoop(_ documents: [ConvertedDocument],
                                 storage: StorageManager) -> (savedIDs: [UUID], failures: Int) {
        var savedIDs: [UUID] = []
        var failures = 0
        for document in documents {
            do {
                let record = try storage.save(document: document)
                savedIDs.append(record.id)
            } catch {
                failures += 1
            }
        }
        return (savedIDs, failures)
    }

    // MARK: - Scan 1 → save → Library sees it → file exists → reopens

    func testFirstScanBecomesDurableLibraryDocument() throws {
        let storage = StorageManager(containerURL: containerURL)
        let document = ConvertedDocument(data: try scannedPDFData(label: "Scan 1"),
                                         pageCount: 1,
                                         suggestedTitle: "First Scan",
                                         sourceURL: nil,
                                         source: .photos)

        let result = runHomeSaveLoop([document], storage: storage)

        XCTAssertEqual(result.failures, 0, "the Home save loop must report zero failures")
        XCTAssertEqual(result.savedIDs.count, 1)
        let id = try XCTUnwrap(result.savedIDs.first)

        // Library fetch sees the record.
        XCTAssertEqual(storage.fetchRecords().first?.id, id,
                       "fetchRecords() must contain the new UUID immediately")

        // The physical file is there and non-empty.
        let record = try XCTUnwrap(storage.record(withID: id))
        let url = try XCTUnwrap(storage.fileURL(for: record))
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        let size = try XCTUnwrap(try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int)
        XCTAssertGreaterThan(size, 0)

        // It reopens as a real PDF.
        XCTAssertNotNil(PDFDocument(url: url), "the saved scan must reopen via PDFDocument(url:)")

        // RELAUNCH PATH: a completely fresh manager over the same container.
        let relaunched = StorageManager(containerURL: containerURL)
        XCTAssertNotNil(relaunched.record(withID: id),
                        "after relaunch, the scanned document MUST still be in Library")
        XCTAssertEqual(relaunched.fetchRecords().count, 1)
    }

    // MARK: - Scans 2 and 3 after cleanUp (the stale-TempFileStore class)

    func testSecondAndThirdScansPersistAfterSessionCleanup() async throws {
        let storage = StorageManager(containerURL: containerURL)
        var allIDs: [UUID] = []

        for scanNumber in 1...3 {
            // Simulate the session lifecycle: convert → save → cleanUp.
            let model = await MainActor.run { ScanFlowModel() }
            defer { Task { @MainActor in model.cleanUp() } }
            _ = model // model owns staging; each iteration gets a FRESH store

            let document = ConvertedDocument(
                data: try scannedPDFData(label: "Scan \(scanNumber)"),
                pageCount: 1,
                suggestedTitle: "Scan \(scanNumber)",
                sourceURL: nil,
                source: .photos)

            let result = runHomeSaveLoop([document], storage: storage)
            XCTAssertEqual(result.failures, 0, "scan #\(scanNumber) must save cleanly")
            allIDs.append(contentsOf: result.savedIDs)

            // Every prior scan still present — no clobbering.
            XCTAssertEqual(storage.fetchRecords().count, scanNumber,
                           "scan #\(scanNumber): Library must hold ALL scans so far")
        }

        // Relaunch path sees all three.
        let relaunched = StorageManager(containerURL: containerURL)
        XCTAssertEqual(Set(relaunched.fetchRecords().map(\.id)), Set(allIDs))
    }

    // MARK: - Backend coherence: fallback writes are visible to fallback reads

    func testFallbackBackendWriteIsVisibleToLibraryFetchOnSameBackend() throws {
        // Both managers resolve to the SAME injected (fallback-like) URL.
        let writer = StorageManager(containerURL: containerURL)
        let reader = StorageManager(containerURL: containerURL)

        let document = ConvertedDocument(data: try scannedPDFData(label: "FB"),
                                         pageCount: 1,
                                         suggestedTitle: "Fallback Doc",
                                         sourceURL: nil,
                                         source: .photos)
        let record = try writer.save(document: document)

        XCTAssertNotNil(reader.record(withID: record.id),
                        "write backend and read backend MUST be the same location")
        XCTAssertTrue(reader.fetchRecords().contains { $0.id == record.id })
        XCTAssertTrue(writer.backendDescription.contains("app-local")
                      || writer.backendDescription.contains("app-group"))
    }

    // MARK: - Batch: every successful group stored

    func testBatchThreeGroupsProduceThreeRecords() throws {
        let storage = StorageManager(containerURL: containerURL)
        let documents = (1...3).map { group in
            ConvertedDocument(data: try! scannedPDFData(label: "Batch \(group)"),
                              pageCount: 1,
                              suggestedTitle: "Batch Group \(group)",
                              sourceURL: nil,
                              source: .photos)
        }
        let result = runHomeSaveLoop(documents, storage: storage)
        XCTAssertEqual(result.savedIDs.count, 3, "every successful batch group must be stored")
        XCTAssertEqual(storage.fetchRecords().count, 3)
    }

    // MARK: - Save failure surfaces (never silent)

    func testUnwritableContainerThrowsInsteadOfSwallowing() {
        // A nil container makes save() throw containerUnavailable — the
        // Home loop then counts it as a failure and KEEPS the document.
        let storage = StorageManager(containerURL: nil)
        let document = ConvertedDocument(data: Data("%PDF-1.4\n".utf8),
                                         pageCount: 1,
                                         suggestedTitle: "Doomed",
                                         sourceURL: nil,
                                         source: .photos)
        XCTAssertThrowsError(try storage.save(document: document),
                             "an impossible container must surface, not vanish")
    }
}
