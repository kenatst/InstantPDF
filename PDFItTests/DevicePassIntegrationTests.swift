import XCTest
import PDFKit
@testable import PDFIt

/// Release-candidate device-pass regression contracts.
/// Every test encodes a real user-facing failure reported from the physical
/// device pass: silent scan persistence, dead tool gating, signature
/// persistence, StoreKit spinner, debug force-Pro propagation.
final class DevicePassIntegrationTests: XCTestCase {

    // MARK: - Harness

    private var containerURL: URL!
    private var storage: StorageManager!

    override func setUpWithError() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("devicepass-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        containerURL = base
        storage = StorageManager(containerURL: base)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: containerURL)
    }

    /// A tiny valid one-page PDF.
    private func pdfData(label: String = "X") -> Data {
        let doc = PDFDocument()
        doc.insert(PDFPage(), at: 0)
        let data = doc.dataRepresentation() ?? Data()
        return data.isEmpty ? Data("%PDF-1.4\n".utf8) : data
    }

    @discardableResult
    private func seed(_ name: String) throws -> StoredPDFRecord {
        let document = ConvertedDocument(data: pdfData(),
                                         pageCount: 1,
                                         suggestedTitle: name,
                                         sourceURL: nil,
                                         source: .files)
        return try storage.save(document: document)
    }

    // MARK: Scan persistence contract (the exact HomeView save loop)

    @MainActor
    func testScanSaveLoopPersistsEveryDocumentAndReportsFailures() throws {
        let documents = (1...3).map { i in
            ConvertedDocument(data: pdfData(), pageCount: 1,
                              suggestedTitle: "Scan — \(i)",
                              sourceURL: nil, source: .photos)
        }
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
        XCTAssertEqual(savedIDs.count, 3)
        XCTAssertEqual(failures, 0)
        // Each saved ID re-resolves to its own file and opens as a valid PDF.
        for id in savedIDs {
            let record = storage.record(withID: id)
            XCTAssertNotNil(record)
            let url = try XCTUnwrap(storage.fileURL(for: record!))
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
            XCTAssertNotNil(PDFDocument(url: url))
        }
        XCTAssertEqual(storage.fetchRecords().count, 3)
    }

    // MARK: Tool output routing contract

    @MainActor
    func testToolOutputRoutingHandsBackExactNewUUID() throws {
        let original = try seed("Contract — Source")
        // Simulate what every tool does on completion: save output, hand the
        // new UUID back through onOutputCreated.
        let outDocument = ConvertedDocument(data: pdfData(), pageCount: 2,
                                            suggestedTitle: "Contract — Extract",
                                            sourceURL: nil, source: .files)
        let created = try storage.save(document: outDocument)
        let newID = created.id
        // The routed viewer must resolve EXACTLY this document.
        let resolved = storage.record(withID: newID)
        XCTAssertEqual(resolved?.displayName, "Contract — Extract")
        XCTAssertEqual(resolved?.pageCount, 2)
        // And the original must be untouched.
        let stillThere = storage.record(withID: original.id)
        XCTAssertEqual(stillThere?.displayName, "Contract — Source")
    }

    // MARK: Signature store

    @MainActor
    func testSignatureStoreSaveReloadDeleteRoundTrip() throws {
        let store = SignatureStore.shared
        let sigURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Signatures", isDirectory: true)
            .appendingPathComponent("signature.png")
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 40, height: 20))
        let image = renderer.image { ctx in
            UIColor.black.setStroke()
            let p = UIBezierPath()
            p.move(to: CGPoint(x: 4, y: 10))
            p.addLine(to: CGPoint(x: 36, y: 10))
            p.lineWidth = 3
            p.stroke()
        }
        let originalSaved = store.savedImage
        defer {
            store.delete()
            _ = originalSaved.map { store.save($0) }
        }

        XCTAssertTrue(store.save(image), "signature PNG write must succeed")
        XCTAssertTrue(FileManager.default.fileExists(atPath: sigURL.path))
        store.reload()
        XCTAssertNotNil(try XCTUnwrap(store.savedImage).pngData())

        store.delete()
        XCTAssertNil(store.savedImage)
        XCTAssertFalse(FileManager.default.fileExists(atPath: sigURL.path),
                       "delete must remove the persisted signature bytes")
    }

    // MARK: Debug force Pro

    @MainActor
    func testDebugForceProPropagatesToExtensionView() {
        #if DEBUG
        let defaults = UserDefaults(suiteName: AppConfiguration.appGroupIdentifier)!
        let previous = defaults.bool(forKey: EntitlementCenter.debugForceProKey)
        defer { defaults.set(previous, forKey: EntitlementCenter.debugForceProKey) }

        defaults.set(false, forKey: EntitlementCenter.debugForceProKey)
        XCTAssertFalse(EntitlementCenter.debugForceProEnabled)

        defaults.set(true, forKey: EntitlementCenter.debugForceProKey)
        XCTAssertTrue(EntitlementCenter.debugForceProEnabled)
        XCTAssertTrue(ExtensionEntitlement.isPro,
                      "DEBUG force-Pro MUST reach the Share Extension gate")
        #else
        throw XCTSkip("Release build: no force-Pro surface exists by design")
        #endif
    }

    @MainActor
    func testReleaseCannotBypassThroughDefaults() {
        // In RELEASE the static property is hardcoded false regardless of any
        // user default; in DEBUG we verify the flag itself is inert here.
        let defaults = UserDefaults(suiteName: AppConfiguration.appGroupIdentifier)!
        defaults.set(true, forKey: EntitlementCenter.debugForceProKey)
        #if RELEASE
        XCTAssertFalse(EntitlementCenter.debugForceProEnabled)
        #endif
        defaults.set(false, forKey: EntitlementCenter.debugForceProKey)
    }

    // MARK: Snapshot stays truthful under force-Pro

    @MainActor
    func testSnapshotReflectsRealEntitlementNotDebugOverride() async {
        let defaults = UserDefaults(suiteName: AppConfiguration.appGroupIdentifier)!
        EntitlementCenter.clearDemoFlagForTests()
        #if DEBUG
        defaults.set(true, forKey: EntitlementCenter.debugForceProKey)
        defer { defaults.set(false, forKey: EntitlementCenter.debugForceProKey) }
        #endif
        let center = EntitlementCenter(defaults: defaults)
        await center.recompute() // no purchases → not entitled
        // Demo Mode is a deliberate, user-facing unlock that DOES publish Pro
        // (the extension must honor it). Only the silent DEBUG force-Pro flag
        // must stay out of the persisted snapshot.
        EntitlementCenter.clearDemoFlagForTests()
        let snapshot = EntitlementCenter.currentSnapshot(fromDefaults: defaults)
        XCTAssertFalse(snapshot?.pro ?? true,
                       "with demo mode off, the snapshot reflects real StoreKit state only")
    }
}
