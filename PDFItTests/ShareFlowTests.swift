import XCTest
import UIKit
import PDFKit
import UniformTypeIdentifiers
@testable import PDFIt

// MARK: - Test harness: synthetic Share Sheet inputs

/// Builds the exact provider shapes real hosts deliver, so the whole
/// NSItemProvider → InputProcessor → Ready state → ConversionCoordinator →
/// StorageManager lifecycle is exercised — not just helper methods.
enum ShareInput {

    static func solidImage(_ color: UIColor) -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: 60, height: 80)).image { context in
            color.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 60, height: 80))
        }
    }

    static func pdfFileURL(title: String = "Doc", pages: Int = 1) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("share-test-\(UUID().uuidString)-\(title).pdf")
        let data = try pdfData(pages: pages)
        try data.write(to: url, options: .atomic)
        return url
    }

    static func pdfData(pages: Int = 1) throws -> Data {
        let bounds = CGRect(x: 0, y: 0, width: 400, height: 600)
        return UIGraphicsPDFRenderer(bounds: bounds).pdfData { context in
            for index in 0..<pages {
                context.beginPage()
                "Page \(index + 1)".draw(at: CGPoint(x: 20, y: 20),
                                         withAttributes: [.font: UIFont.systemFont(ofSize: 16)])
            }
        }
    }

    /// Photos-style image share (registered object representation).
    static func imageProvider(_ color: UIColor) -> NSItemProvider {
        NSItemProvider(object: solidImage(color))
    }

    /// Files-app style PDF share.
    static func pdfProvider(url: URL) -> NSItemProvider {
        NSItemProvider(contentsOf: url)!
    }

    /// Notes-style plain text share.
    static func textProvider(_ text: String) -> NSItemProvider {
        NSItemProvider(object: text as NSString)
    }

    /// Safari-style URL share. Registered as a data representation because
    /// NSURL doesn't adopt NSItemProviderWriting — this mirrors what real
    /// hosts hand over far better than an object registration.
    static func urlProvider(_ url: URL) -> NSItemProvider {
        let provider = NSItemProvider()
        provider.registerDataRepresentation(forTypeIdentifier: UTType.url.identifier,
                                            visibility: .all) { completion in
            completion(Data(url.absoluteString.utf8), nil)
            return nil
        }
        return provider
    }

    /// A webpage-ish provider advertising URL + HTML + text simultaneously —
    /// exactly what several browsers and reader apps hand over.
    static func webComboProvider(url: URL, html: String, text: String) -> NSItemProvider {
        let provider = NSItemProvider()
        provider.registerDataRepresentation(forTypeIdentifier: UTType.url.identifier,
                                            visibility: .all) { completion in
            completion(Data(url.absoluteString.utf8), nil)
            return nil
        }
        provider.registerDataRepresentation(forTypeIdentifier: UTType.html.identifier,
                                            visibility: .all) { completion in
            completion(Data(html.utf8), nil)
            return nil
        }
        provider.registerDataRepresentation(forTypeIdentifier: UTType.plainText.identifier,
                                            visibility: .all) { completion in
            completion(Data(text.utf8), nil)
            return nil
        }
        return provider
    }

    /// HTML + plain text WITHOUT a URL (e.g. Mail selection shares).
    static func htmlAndTextProvider(html: String, text: String) -> NSItemProvider {
        let provider = NSItemProvider()
        for (identifier, payload) in [(UTType.html.identifier, html),
                                      (UTType.plainText.identifier, text)] {
            provider.registerDataRepresentation(forTypeIdentifier: identifier,
                                                visibility: .all) { completion in
                completion(Data(payload.utf8), nil)
                return nil
            }
        }
        return provider
    }

    /// Safari's property-list style webpage payload ("_webURL").
    static func safariPropertyListProvider(url: URL) -> NSItemProvider {
        let provider = NSItemProvider()
        provider.registerDataRepresentation(forTypeIdentifier: UTType.propertyList.identifier,
                                            visibility: .all) { completion in
            let plist = ["_webURL": url.absoluteString]
            let data = try? PropertyListSerialization.data(fromPropertyList: plist,
                                                           format: .xml,
                                                           options: 0)
            completion(data, nil)
            return nil
        }
        return provider
    }

    /// UTF-8 bytes instead of a string object — some hosts do this.
    static func utf8DataProvider(_ text: String) -> NSItemProvider {
        let provider = NSItemProvider()
        provider.registerDataRepresentation(forTypeIdentifier: UTType.utf8PlainText.identifier,
                                            visibility: .all) { completion in
            completion(Data(text.utf8), nil)
            return nil
        }
        return provider
    }

    /// A video attachment we must refuse but count as skipped.
    static func videoProvider() -> NSItemProvider {
        let provider = NSItemProvider()
        provider.registerDataRepresentation(forTypeIdentifier: UTType.movie.identifier,
                                            visibility: .all) { completion in
            completion(Data([0x00, 0x00]), nil)
            return nil
        }
        return provider
    }

    static func extensionItem(attachments: [NSItemProvider]) -> NSExtensionItem {
        let item = NSExtensionItem()
        item.attachments = attachments
        return item
    }
}

// MARK: - The release-blocking share flow regressions

final class ShareFlowTests: XCTestCase {

    private var container: URL!

    override func setUpWithError() throws {
        container = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdfit-flow-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: container)
    }

    private func makeStorage() -> StorageManager {
        StorageManager(containerURL: container)
    }

    // MARK: Waiting helpers

    @MainActor
    private func waitForState(of model: ShareFlowModel,
                              timeout: TimeInterval = 15,
                              where predicate: @escaping (ShareFlowModel.State) -> Bool) async throws -> ShareFlowModel.State {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if predicate(model.state) { return model.state }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("Timed out waiting for state; stuck at \(model.state)")
        throw NSError(domain: "ShareFlowTests", code: 1)
    }

    private func extract(_ attachments: [NSItemProvider]) async throws -> ExtractedInput {
        let processor = InputProcessor()
        return await processor.extract(extensionItems: [ShareInput.extensionItem(attachments: attachments)])
    }

    // MARK: P0 BUG 2 — staging files survive extraction

    /// THE regression for destroyed temp staging: extraction returns items
    /// pointing at staged files that MUST still exist on disk. On the broken
    /// code the staging directory was wiped when `extract` returned, so every
    /// file-backed item was a dangling reference.
    func testExtractedImageStagedFileExistsAfterExtractionReturns() async throws {
        let extracted = try await extract([ShareInput.imageProvider(.systemRed)])

        XCTAssertEqual(extracted.items.count, 1, "One image share yields one item")
        let item = try XCTUnwrap(extracted.items.first)
        guard case .image(let stagedURL) = item.kind else {
            return XCTFail("Expected an image item, got \(item.kind)")
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: stagedURL.path),
                      "Staged file must still exist after extraction returns")
        XCTAssertNotNil(extracted.staging, "Extraction must hand back a live staging session")

        // And the staged file is real image data, not an empty husk.
        let size = (try? FileManager.default.attributesOfItem(atPath: stagedURL.path)[.size] as? Int) ?? nil
        XCTAssertTrue((size ?? 0) > 0, "Staged image has content")
        _ = size

        extracted.staging?.cleanUp()
    }

    /// Same guarantee for PDFs — the Quick passthrough lane depends on it.
    func testExtractedPDFRemainsAvailableForConversionLifecycle() async throws {
        let originalURL = try ShareInput.pdfFileURL(title: "Report", pages: 2)
        let originalData = try Data(contentsOf: originalURL)

        let extracted = try await extract([ShareInput.pdfProvider(url: originalURL)])
        let item = try XCTUnwrap(extracted.items.first)
        guard case .pdf(let stagedURL) = item.kind else {
            return XCTFail("Expected a pdf item, got \(item.kind)")
        }

        XCTAssertTrue(FileManager.default.fileExists(atPath: stagedURL.path))
        let stagedData = try Data(contentsOf: stagedURL)
        XCTAssertEqual(stagedData, originalData,
                       "Staging copies bytes faithfully; passthrough depends on this")

        // Simulate Ready screen dwell time — nothing may clean up here.
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertTrue(FileManager.default.fileExists(atPath: stagedURL.path),
                      "Files survive while the user sits on the Ready screen")

        extracted.staging?.cleanUp()
    }

    /// Cleanup happens at lifecycle end, not during Ready/convert.
    func testStagingSurvivesReadyScreenAndDiesAtTerminalState() async throws {
        let extracted = try await extract([ShareInput.imageProvider(.systemBlue)])
        let stagingDirectory = try XCTUnwrap(extracted.staging?.directory)

        let model = await MainActor.run {
            ShareFlowModel(convert: { items, options, onStage in
                onStage(.creatingPDF)
                return try await ConversionCoordinator().convert(items: items, options: options)
            }, storage: self.makeStorage())
        }

        await MainActor.run { model.handle(extracted: extracted) }
        await MainActor.run {
            guard case .ready = model.state else {
                XCTFail("Expected ready state, got \(model.state)")
                return
            }
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: stagingDirectory.path),
                      "Ready screen must NOT clean staging")

        await MainActor.run { model.createTapped() }
        _ = try await waitForState(of: model) {
            if case .preview = $0 { return true }
            return false
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: stagingDirectory.path),
                       "Successful conversion cleans staging")
    }

    // MARK: P0 BUG 1 — Ready state retains the exact extracted items

    /// Empty input can never produce a Ready state — invalid states are
    /// impossible by construction.
    func testReadySummaryRefusesEmptyInput() async throws {
        let empty = ExtractedInput(items: [], skippedCount: 0, staging: TempFileStore())
        XCTAssertNil(ShareFlowModel.ReadySummary.build(for: empty))

        let model = await MainActor.run {
            ShareFlowModel(convert: { _, _, _ in
                XCTFail("Conversion must not run without items")
                throw ConversionError.noUsableContent
            }, storage: nil)
        }

        await MainActor.run { model.handle(extracted: empty) }
        await MainActor.run {
            XCTAssertEqual(model.state, .failed(.noUsableContent))
        }
        await MainActor.run { model.createTapped() } // must be a no-op
        await MainActor.run {
            XCTAssertEqual(model.state, .failed(.noUsableContent), "Create from failure does nothing")
        }
    }

    /// THE regression for lost Ready items: whatever Create PDF converts is
    /// EXACTLY what extraction produced — same ids, same order, non-empty.
    func testReadyStateRetainsExactItemsThroughConversionStart() async throws {
        let extracted = try await extract([
            ShareInput.imageProvider(.systemGreen),
            ShareInput.imageProvider(.systemOrange),
        ])
        let readyItems = try XCTUnwrap(
            ShareFlowModel.ReadySummary.build(for: extracted)?.items,
            "Ready summary must carry the extracted items"
        )
        XCTAssertEqual(readyItems.map(\.id), extracted.items.map(\.id))
        XCTAssertEqual(readyItems.count, 2)

        final class CaptureBox: @unchecked Sendable {
            var received: [[IncomingItem]] = []
        }
        let box = CaptureBox()

        let model = await MainActor.run {
            ShareFlowModel(convert: { items, _, _ in
                box.received.append(items)
                return ConvertedDocument(data: Data(), pageCount: 0,
                                         suggestedTitle: "stub", sourceURL: nil, source: .mixed)
            }, storage: nil)
        }

        await MainActor.run { model.handle(extracted: extracted) }
        await MainActor.run {
            guard case .ready(let summary) = model.state else {
                return XCTFail("Expected ready")
            }
            XCTAssertEqual(summary.items.map(\.id), extracted.items.map(\.id),
                           "State carries the exact extracted instances")
        }
        await MainActor.run { model.createTapped() }

        let deadline = Date().addingTimeInterval(5)
        while box.received.isEmpty && Date() < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let converted = try XCTUnwrap(box.received.first, "Conversion never started")
        XCTAssertEqual(converted.map(\.id), extracted.items.map(\.id),
                       "Create PDF receives the exact retained items — never an empty array")
    }

    // MARK: IMAGE FLOW — provider → extraction → ready → valid PDF

    func testImageFlowFromProviderToValidPDF() async throws {
        let extracted = try await extract([ShareInput.imageProvider(.systemPurple)])

        let coordinator = ConversionCoordinator()
        let summary = try XCTUnwrap(ShareFlowModel.ReadySummary.build(for: extracted))
        let document = try await coordinator.convert(items: summary.items, options: ConversionOptions())

        let pdf = try XCTUnwrap(PDFKit.PDFDocument(data: document.data),
                                "Image share produces a parseable PDF")
        XCTAssertEqual(pdf.pageCount, 1)
        XCTAssertEqual(document.source, .photos)
        XCTAssertGreaterThan(document.data.count, 500, "PDF contains actual rendered pixels")

        extracted.staging?.cleanUp()
    }

    // MARK: PDF FLOW — byte-perfect passthrough through the real lifecycle

    func testExistingPDFQuickModeIsBytePerfectThroughFullPipeline() async throws {
        let originalURL = try ShareInput.pdfFileURL(title: "Passthrough", pages: 3)
        let originalData = try Data(contentsOf: originalURL)

        let extracted = try await extract([ShareInput.pdfProvider(url: originalURL)])
        let summary = try XCTUnwrap(ShareFlowModel.ReadySummary.build(for: extracted))
        XCTAssertTrue(summary.isPDFPassthrough, "Single existing PDF offers passthrough UI semantics")

        var quickOptions = ConversionOptions.fromSharedDefaults()
        quickOptions.mode = .quick
        let document = try await ConversionCoordinator().convert(items: summary.items,
                                                                 options: quickOptions)
        XCTAssertEqual(document.data, originalData,
                       "Quick mode preserves the ORIGINAL BYTES through extraction → conversion")
        XCTAssertEqual(document.pageCount, 3)

        extracted.staging?.cleanUp()
    }

    // MARK: TEXT FLOW

    func testTextFlowFromProviderToValidPDF() async throws {
        let extracted = try await extract([ShareInput.textProvider("Hello from Notes")])
        let summary = try XCTUnwrap(ShareFlowModel.ReadySummary.build(for: extracted))
        XCTAssertEqual(summary.title, String(localized: "Text"))
        XCTAssertEqual(summary.availableModes, [.quick])

        let document = try await ConversionCoordinator().convert(items: summary.items,
                                                                 options: ConversionOptions())
        let pdf = try XCTUnwrap(PDFKit.PDFDocument(data: document.data))
        XCTAssertEqual(pdf.pageCount, 1)
        XCTAssertEqual(document.source, .textEditor)

        extracted.staging?.cleanUp()
    }

    // MARK: MULTI-IMAGE FLOW

    func testMultiImageFlowCountOrderExistenceAndPageCount() async throws {
        let extracted = try await extract([
            ShareInput.imageProvider(.systemRed),
            ShareInput.imageProvider(.systemGreen),
            ShareInput.imageProvider(.systemBlue),
        ])

        XCTAssertEqual(extracted.items.count, 3)
        XCTAssertEqual(extracted.items.map(\.index).sorted(), [0, 1, 2], "Order preserved")

        for item in extracted.items {
            guard case .image(let url) = item.kind else {
                return XCTFail("All three items must be images")
            }
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path),
                          "Every staged image survives until conversion")
        }

        let summary = try XCTUnwrap(ShareFlowModel.ReadySummary.build(for: extracted))
        XCTAssertEqual(summary.title, String(localized: "plural.images \(3)"))
        XCTAssertEqual(summary.subtitle, String(localized: "Order preserved"))

        let document = try await ConversionCoordinator().convert(items: summary.items,
                                                                 options: ConversionOptions())
        let pdf = try XCTUnwrap(PDFKit.PDFDocument(data: document.data))
        XCTAssertEqual(pdf.pageCount, 3, "Three images → three pages")
        XCTAssertEqual(document.source, .photos, "Homogeneous photos stay labeled Photos")

        extracted.staging?.cleanUp()
    }

    // MARK: Full model journey — preview + Library persistence

    func testFullJourneyPreviewShowsSavedRecordInLibrary() async throws {
        let extracted = try await extract([ShareInput.textProvider("Journey body text")])
        let storage = makeStorage()

        let model = await MainActor.run {
            ShareFlowModel(convert: { items, options, onStage in
                onStage(.creatingPDF)
                return try await ConversionCoordinator().convert(items: items, options: options)
            }, storage: storage)
        }

        await MainActor.run { model.handle(extracted: extracted) }
        await MainActor.run { model.createTapped() }

        let state = try await waitForState(of: model) {
            if case .preview = $0 { return true }
            return false
        }
        guard case .preview(let info) = state else { return XCTFail("unreachable") }
        XCTAssertTrue(info.savedToLibrary, "PDF persisted to Library storage")
        let savedURL = try XCTUnwrap(info.savedURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: savedURL.path))
        XCTAssertEqual(storage.fetchRecords().count, 1, "Library sees the new document")

        await MainActor.run { model.complete() }
    }

    /// Storage failure must NOT discard the generated PDF nor report full
    /// failure — preview still appears with savedToLibrary == false.
    func testStorageFailureStillPreviewsCreatedPDF() async throws {
        let extracted = try await extract([ShareInput.textProvider("Survives storage loss")])

        let model = await MainActor.run {
            ShareFlowModel(convert: { items, options, onStage in
                onStage(.creatingPDF)
                return try await ConversionCoordinator().convert(items: items, options: options)
            }, storage: nil) // App Group unavailable
        }

        await MainActor.run { model.handle(extracted: extracted) }
        await MainActor.run { model.createTapped() }

        let state = try await waitForState(of: model) {
            if case .preview = $0 { return true }
            if case .failed = $0 { return true }
            return false
        }
        guard case .preview(let info) = state else {
            return XCTFail("Storage failure must not become conversion failure; got \(state)")
        }
        XCTAssertFalse(info.savedToLibrary)
        XCTAssertFalse(info.document.data.isEmpty, "The created PDF is intact")
    }

    // MARK: Cancellation

    /// Cancellation propagates AS cancellation — no fallback conversion, no
    /// misleading failure, staging cleaned, host notified once.
    func testCancelDuringConversionPropagatesAsCancellation() async throws {
        let extracted = try await extract([ShareInput.imageProvider(.systemTeal)])
        let stagingDirectory = try XCTUnwrap(extracted.staging?.directory)

        final class FlagBox: @unchecked Sendable {
            var finishedValues: [Bool] = []
            var fallbackAttempts = 0
        }
        let flags = FlagBox()

        let model = await MainActor.run {
            ShareFlowModel(convert: { _, _, _ in
                try await Task.sleep(nanoseconds: 30_000_000_000) // far beyond the test
                flags.fallbackAttempts += 1
                throw ConversionError.generationFailed
            }, storage: nil)
        }

        await MainActor.run {
            model.onFinish = { success in flags.finishedValues.append(success) }
            model.handle(extracted: extracted)
            model.createTapped()
        }

        _ = try await waitForState(of: model) {
            if case .converting = $0 { return true }
            return false
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: stagingDirectory.path),
                      "Files alive while converting")

        await MainActor.run { model.cancelConversion() }

        let deadline = Date().addingTimeInterval(5)
        while flags.finishedValues.isEmpty && Date() < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(flags.finishedValues, [false], "Exactly one cancellation notification")
        XCTAssertEqual(flags.fallbackAttempts, 0, "No silent fallback conversion after cancel")
        await MainActor.run {
            XCTAssertNotEqual(model.state, .failed(.generationFailed),
                              "Cancellation must not surface as generation failure")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: stagingDirectory.path),
                       "Cancellation cleans staging")

        // Double-cancel is safe: no second notification.
        await MainActor.run { model.cancelConversion() }
        XCTAssertEqual(flags.finishedValues.count, 1)
    }

    /// Backing out from the Ready screen cleans staging too.
    func testCancelFromReadyScreenCleansStagingWithoutConverting() async throws {
        let extracted = try await extract([ShareInput.imageProvider(.systemMint)])
        let stagingDirectory = try XCTUnwrap(extracted.staging?.directory)

        final class FlagBox: @unchecked Sendable { var finished: [Bool] = [] }
        let flags = FlagBox()

        let model = await MainActor.run {
            ShareFlowModel(convert: { _, _, _ in
                XCTFail("No conversion should run")
                throw ConversionError.generationFailed
            }, storage: nil)
        }

        await MainActor.run {
            model.onFinish = { success in flags.finished.append(success) }
            model.handle(extracted: extracted)
        }
        await MainActor.run {
            guard case .ready = model.state else { return XCTFail("expected ready") }
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: stagingDirectory.path))

        await MainActor.run { model.cancelConversion() }
        XCTAssertEqual(flags.finished, [false])
        XCTAssertFalse(FileManager.default.fileExists(atPath: stagingDirectory.path))
    }

    // MARK: Extraction failures

    func testVideoOnlyShareFailsAsNoUsableContentWithSkipNoticeContext() async throws {
        let extracted = try await extract([ShareInput.videoProvider()])
        XCTAssertEqual(extracted.items.isEmpty, true)
        XCTAssertEqual(extracted.skippedCount, 1)

        let model = await MainActor.run {
            ShareFlowModel(convert: { _, _, _ in
                XCTFail("Nothing to convert")
                throw ConversionError.generationFailed
            }, storage: nil)
        }
        await MainActor.run { model.handle(extracted: extracted) }
        await MainActor.run {
            XCTAssertEqual(model.state, .failed(.noUsableContent))
        }
    }

    // MARK: Web retry retains items

    func testWebFailureRetryUsesRetainedItemsNotFreshEmptyOnes() async throws {
        let url = URL(string: "https://example.com/article")!
        let extracted = try await extract([ShareInput.urlProvider(url)])

        final class AttemptBox: @unchecked Sendable {
            var attempts: [[IncomingItem]] = []
        }
        let attempts = AttemptBox()

        let model = await MainActor.run {
            ShareFlowModel(convert: { items, _, _ in
                attempts.attempts.append(items)
                throw ConversionError.pageTooSlow
            }, storage: nil)
        }

        await MainActor.run { model.handle(extracted: extracted) }
        await MainActor.run {
            XCTAssertEqual(model.readySummary?.failingURL, url,
                           "Extraction must produce the web item; got \(extracted.items)")
        }
        await MainActor.run { model.createTapped() }
        await MainActor.run { model.retryFailedWebConversion() }

        let deadline = Date().addingTimeInterval(5)
        while attempts.attempts.count < 2 && Date() < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(attempts.attempts.count, 2, "Retry ran again")
        for attempt in attempts.attempts {
            let first = try XCTUnwrap(attempt.first)
            guard case .url(let retriedURL) = first.kind else {
                return XCTFail("Retry must reuse web items; got \(first.kind)")
            }
            XCTAssertEqual(retriedURL, url,
                           "Retry reuses the SAME retained items — never empty ones")
        }
    }
}

// MARK: - Cross-process storage safety (app + extension)

final class StorageCrossProcessTests: XCTestCase {

    private var container: URL!

    override func setUpWithError() throws {
        container = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdfit-xproc-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: container)
    }

    private func doc(_ title: String) throws -> ConvertedDocument {
        ConvertedDocument(data: try ShareInput.pdfData(),
                          pageCount: 1,
                          suggestedTitle: title,
                          sourceURL: nil,
                          source: .files)
    }

    /// The canonical interleaving from the release gate:
    /// ext saves A → app sees A → app saves B → ext sees A+B →
    /// ext saves C → app sees A+B+C → deleting B keeps A/C.
    func testAppAndExtensionSeeEachOthersChangesWithoutLoss() throws {
        // Two INDEPENDENT processes simulated by two independent managers;
        // neither may rely on cached in-memory records.
        let appStorage = StorageManager(containerURL: container)
        let extensionStorage = StorageManager(containerURL: container)

        // 1. extension saves A
        let a = try extensionStorage.save(document: doc("Alpha"))
        // 2. app fetches and sees A
        XCTAssertEqual(appStorage.fetchRecords().map(\.filename), [a.filename],
                       "App must see extension-created documents WITHOUT relaunch")

        // 3. app saves B
        let b = try appStorage.save(document: doc("Bravo"))
        // 4. extension fetches and sees A + B
        XCTAssertEqual(Set(extensionStorage.fetchRecords().map(\.filename)),
                       Set([a.filename, b.filename]))

        // 5. extension saves C
        let c = try extensionStorage.save(document: doc("Charlie"))
        // 6. app sees A + B + C
        XCTAssertEqual(Set(appStorage.fetchRecords().map(\.filename)),
                       Set([a.filename, b.filename, c.filename]),
                       "No metadata update was overwritten")

        // 7. app deletes B; A and C must survive everywhere
        try appStorage.delete(b)
        XCTAssertEqual(Set(extensionStorage.fetchRecords().map(\.filename)),
                       Set([a.filename, c.filename]))
        XCTAssertTrue(extensionStorage.exists(a))
        XCTAssertTrue(extensionStorage.exists(c))
        XCTAssertFalse(extensionStorage.exists(b))
    }

    /// Concurrent saves from both processes: every save lands, nothing is
    /// clobbered. This is the regression that stale in-memory indexes fail.
    func testInterleavedConcurrentWritesLoseNothing() throws {
        let appStorage = StorageManager(containerURL: container)
        let extensionStorage = StorageManager(containerURL: container)

        let total = 16
        DispatchQueue.concurrentPerform(iterations: total) { iteration in
            let manager = iteration.isMultiple(of: 2) ? appStorage : extensionStorage
            _ = try? manager.save(document: try! doc("Racer \(iteration)"))
        }

        // Both processes converge on the SAME complete set.
        XCTAssertEqual(appStorage.fetchRecords().count, total,
                       "All concurrent saves survived — none overwritten")
        XCTAssertEqual(extensionStorage.fetchRecords().count, total)

        let filenames = appStorage.fetchRecords().map(\.filename)
        XCTAssertEqual(Set(filenames).count, total, "Collision handling kept every name unique")

        for record in appStorage.fetchRecords() {
            XCTAssertTrue(appStorage.exists(record), "\(record.filename) present on disk")
        }
    }

    /// Filename collision checks run against CURRENT DISK STATE: an orphaned
    /// file (metadata lost) still blocks reuse of its name.
    func testCollisionCheckUsesCurrentDiskStateNotStaleMemory() throws {
        let documentsDir = container.appendingPathComponent("Documents/PDFs", isDirectory: true)
        try FileManager.default.createDirectory(at: documentsDir, withIntermediateDirectories: true)

        // Orphaned PDF on disk with NO metadata record.
        let orphanData = try ShareInput.pdfData(pages: 2)
        try orphanData.write(to: documentsDir.appendingPathComponent("Orphan.pdf"), options: .atomic)

        let freshProcess = StorageManager(containerURL: container) // knows nothing about it
        let saved = try freshProcess.save(document: ConvertedDocument(data: orphanData,
                                                                      pageCount: 2,
                                                                      suggestedTitle: "Orphan",
                                                                      sourceURL: nil,
                                                                      source: .files))
        XCTAssertEqual(saved.filename, "Orphan 2.pdf",
                       "Must not overwrite the orphaned file already on disk")
        XCTAssertTrue(FileManager.default.fileExists(atPath: documentsDir.appendingPathComponent("Orphan.pdf").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: documentsDir.appendingPathComponent("Orphan 2.pdf").path))
    }

    /// A long-lived main-app instance picks up extension writes made AFTER
    /// the instance existed — the Library staleness bug.
    func testLongLivedInstanceSeesLaterExternalWrites() throws {
        let appStorage = StorageManager(containerURL: container)
        XCTAssertEqual(appStorage.fetchRecords().count, 0)

        // Extension process writes later, while the app instance lives on.
        let extensionStorage = StorageManager(containerURL: container)
        let saved = try extensionStorage.save(document: doc("Late Arrival"))

        XCTAssertEqual(appStorage.fetchRecords().map(\.filename), [saved.filename],
                       "fetchRecords refreshes from disk — no stale cache")
    }
}

// MARK: - Source metadata inference

final class SourceMetadataTests: XCTestCase {

    private func item(kind: IncomingKind, source: ContentSource, index: Int) -> IncomingItem {
        IncomingItem(kind: kind, source: source, index: index)
    }

    private func imageURL() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).jpg") }

    func testSingleItemKeepsItsOwnSource() {
        XCTAssertEqual(ConversionCoordinator.inferredSource(for: [
            item(kind: .text("hi"), source: .textEditor, index: 0),
        ]), .textEditor)

        XCTAssertEqual(ConversionCoordinator.inferredSource(for: [
            item(kind: .pdf(imageURL()), source: .files, index: 0),
        ]), .files)

        XCTAssertEqual(ConversionCoordinator.inferredSource(for: [
            item(kind: .url(URL(string: "https://x.com/u/s/1")!), source: .x, index: 0),
        ]), .x)
    }

    func testHomogeneousCollectionsUseCommonSource() {
        let fiveImages = (0..<5).map { item(kind: .image(imageURL()), source: .photos, index: $0) }
        XCTAssertEqual(ConversionCoordinator.inferredSource(for: fiveImages), .photos)

        let notes = (0..<2).map { item(kind: .text("n\($0)"), source: .textEditor, index: $0) }
        XCTAssertEqual(ConversionCoordinator.inferredSource(for: notes), .textEditor)
    }

    func testMixedCollectionIsHonestlyMixedNotFirstItemMislabel() {
        let mixed = [
            item(kind: .image(imageURL()), source: .photos, index: 0),
            item(kind: .text("body"), source: .textEditor, index: 1),
            item(kind: .pdf(imageURL()), source: .files, index: 2),
        ]
        XCTAssertEqual(ConversionCoordinator.inferredSource(for: mixed), .mixed,
                       "Mixed content must not be labeled by its first element")
    }

    func testConvertedDocumentsCarryCorrectSources() async throws {
        let coordinator = ConversionCoordinator()
        let options = ConversionOptions()

        let textOnly = try await coordinator.convert(items: [
            item(kind: .text("plain note"), source: .textEditor, index: 0),
        ], options: options)
        XCTAssertEqual(textOnly.source, .textEditor)

        let image = ShareInput.solidImage(.systemBrown)
            .pngData() ?? Data()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).png")
        try image.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let imageOnly = try await coordinator.convert(items: [
            item(kind: .image(url), source: .photos, index: 0),
        ], options: options)
        XCTAssertEqual(imageOnly.source, .photos)

        let merged = try await coordinator.convert(items: [
            item(kind: .image(url), source: .photos, index: 0),
            item(kind: .text("and words"), source: .textEditor, index: 1),
        ], options: options)
        XCTAssertEqual(merged.source, .mixed)
    }
}

// MARK: - Fallback titles

final class FallbackTitleTests: XCTestCase {

    private func textItem(_ text: String, title: String? = nil, index: Int = 0) -> IncomingItem {
        IncomingItem(kind: .text(text), title: title, source: .textEditor, index: index)
    }

    /// THE ordering regression: single text previously always fell into the
    /// generic branch and became "Note" before first-line logic could run.
    func testSingleTextSharesUseFirstMeaningfulLine() {
        let title = ConversionCoordinator.fallbackTitle(for: [
            textItem("Meeting Notes for Project Atlas\n\nBudget discussion…"),
        ])
        XCTAssertEqual(title, "Meeting Notes for Project Atlas",
                       "A single shared note deserves its own headline, not 'Note'")
    }

    func testWhitespaceOnlyTextStillProducesSomethingSane() {
        let title = ConversionCoordinator.fallbackTitle(for: [textItem("   \n  ")])
        XCTAssertEqual(title, "Note")
    }

    func testMultipleTextItemsStayDated() {
        let title = ConversionCoordinator.fallbackTitle(for: [
            textItem("First", index: 0),
            textItem("Second", index: 1),
        ])
        XCTAssertEqual(title, "2 Notes")
    }

    func testFirstLineSkipsLeadingBlankLinesAndCapsLength() {
        let title = ConversionCoordinator.fallbackTitle(for: [
            textItem("\n\n  \n Real heading here"),
        ])
        XCTAssertEqual(title, "Real heading here")

        let long = ConversionCoordinator.fallbackTitle(for: [
            textItem(String(repeating: "word ", count: 40)),
        ])
        XCTAssertLessThanOrEqual(long?.count ?? 0, 61)
    }

    func testNamedTextItemPrefersExplicitTitleForCollections() {
        let title = ConversionCoordinator.fallbackTitle(for: [
            textItem("Body", title: "Grocery list", index: 0),
            textItem("More", index: 1),
        ])
        XCTAssertEqual(title, "Grocery list")
    }
}

// MARK: - Provider priority & Safari representations

final class InputPriorityTests: XCTestCase {

    private func extract(_ attachments: [NSItemProvider]) async throws -> ExtractedInput {
        let processor = InputProcessor()
        return await processor.extract(extensionItems: [ShareInput.extensionItem(attachments: attachments)])
    }

    /// Providers advertising URL + HTML + text simultaneously (common for
    /// browsers): the WEBPAGE intent wins — never generic plain text.
    func testWebpageComboChoosesURLRepresentation() async throws {
        let url = URL(string: "https://example.com/post")!
        let extracted = try await extract([
            ShareInput.webComboProvider(url: url,
                                        html: "<html><body><h1>Post</h1></body></html>",
                                        text: "Post"),
        ])
        let item = try XCTUnwrap(extracted.items.single)
        XCTAssertTrue(hasURLEqual(item, url),
                      "URL representation wins for webpage shares; got \(item.kind)")
    }

    /// HTML + text WITHOUT a URL: HTML wins because it preserves structure.
    func testHTMLBeatsPlainTextWhenNoURLPresent() async throws {
        let extracted = try await extract([
            ShareInput.htmlAndTextProvider(html: "<html><body>Rich body</body></html>",
                                           text: "Rich body"),
        ])
        let item = try XCTUnwrap(extracted.items.single)
        guard case .html(let html, _) = item.kind else {
            return XCTFail("HTML must be preferred over plain text; got \(item.kind)")
        }
        XCTAssertTrue(html.contains("Rich body"))
    }

    /// Safari's property-list webpage activation actually parses.
    func testSafariPropertyListPayloadYieldsURLItem() async throws {
        let url = URL(string: "https://example.com/safari-page")!
        let extracted = try await extract([ShareInput.safariPropertyListProvider(url: url)])
        let item = try XCTUnwrap(extracted.items.single)
        XCTAssertTrue(hasURLEqual(item, url), "Got \(item.kind)")
        XCTAssertEqual(item.source, .website)
    }

    /// UTF-8 byte payloads decode instead of being dropped.
    func testUTF8BytePayloadDecodesToText() async throws {
        let extracted = try await extract([ShareInput.utf8DataProvider("Bytes to text")])
        let item = try XCTUnwrap(extracted.items.single)
        XCTAssertTrue(hasTextEqual(item, "Bytes to text"), "Got \(item.kind)")
    }

    /// Videos are refused but counted, keeping surrounding items intact.
    func testVideoBetweenImagesIsSkippedNotFatal() async throws {
        let extracted = try await extract([
            ShareInput.imageProvider(.systemRed),
            ShareInput.videoProvider(),
            ShareInput.imageProvider(.systemBlue),
        ])
        XCTAssertEqual(extracted.items.count, 2, "Both images survive the skipped video")
        XCTAssertEqual(extracted.skippedCount, 1)
    }

    /// Non-http URLs don't masquerade as webpages.
    func testNonHTTPURLDoesNotBecomeWebpageItem() async throws {
        let extracted = try await extract([ShareInput.urlProvider(URL(string: "ftp://example.com/file")!)])
        XCTAssertTrue(extracted.items.isEmpty || !extracted.items.contains {
            if case .url = $0.kind { return true }
            return false
        })
    }
}

private func hasURLEqual(_ item: IncomingItem?, _ expected: URL) -> Bool {
    guard case .url(let actual) = item?.kind else { return false }
    return actual == expected
}

private func hasTextEqual(_ item: IncomingItem?, _ expected: String) -> Bool {
    guard case .text(let actual) = item?.kind else { return false }
    return actual == expected
}

private extension Array {
    /// Unwrapping helper for exactly-one-element arrays in tests.
    var single: Element? {
        count == 1 ? first : nil
    }
}

// MARK: - Micro-hardening regressions

/// The background-tap recognizer must only cancel for touches OUTSIDE the
/// card. This policy is exactly what the gesture delegate calls in
/// `ShareViewController`, so these tests cover the shipped rule: Create PDF /
/// Share / Done / Retry / segmented controls can never trigger dismissal.
final class CardTapPolicyTests: XCTestCase {

    private let card = CGRect(x: 0, y: 0, width: 300, height: 500)

    func tapCancels(_ x: CGFloat, _ y: CGFloat) -> Bool {
        CardTapPolicy.cancels(locationInCard: CGPoint(x: x, y: y), cardBounds: card)
    }

    func testTapsInsideCardNeverCancel() {
        XCTAssertFalse(tapCancels(150, 250), "Card center")
        XCTAssertFalse(tapCancels(150, 470), "Create PDF button region")
        XCTAssertFalse(tapCancels(40, 470), "Mode segmented control region")
        XCTAssertFalse(tapCancels(150, 60), "Title area")
    }

    func testTapsOutsideCardAlwaysCancel() {
        XCTAssertTrue(tapCancels(-1, 250), "Left of card")
        XCTAssertTrue(tapCancels(301, 250), "Right of card")
        XCTAssertTrue(tapCancels(150, -1), "Above card")
        XCTAssertTrue(tapCancels(150, 501), "Below card")
    }

    func testCardEdgeMatchesUIKitHitTestingSemantics() {
        // CGRect.contains / UIView.point(inside:) exclude the max edge;
        // the policy deliberately matches UIKit's own hit-testing rule so
        // recognizer decisions can never disagree with button hit areas.
        XCTAssertFalse(tapCancels(0, 0), "Origin belongs to the card")
        XCTAssertTrue(tapCancels(300, 500), "Max-edge corner is outside, like UIView hit-testing")
    }
}
