import XCTest
import UIKit
import PDFKit
@testable import PDFIt

/// Scan pipeline regressions: order, rotation, deletion, grouping,
/// enhancement application, output page counts, temp cleanup.
final class ScanFlowTests: XCTestCase {

    private var store: TempFileStore!

    override func setUpWithError() throws {
        store = TempFileStore()
    }

    override func tearDownWithError() throws {
        store.cleanUp()
    }

    private func makeJPEGData(color: UIColor = .orange, size: CGSize = CGSize(width: 80, height: 110)) throws -> Data {
        let renderer = UIGraphicsImageRenderer(size: size)
        let image = renderer.image { context in
            color.setFill()
            context.fill(CGRect(origin: .zero, size: size))
        }
        return try XCTUnwrap(image.jpegData(compressionQuality: 0.8))
    }

    @MainActor
    private func makeSession(pageCount: Int) throws -> (ScanSessionModel, [ScannedPage]) {
        var session = ScanSessionModel()
        var pages: [ScannedPage] = []
        for index in 0..<pageCount {
            let data = try makeJPEGData(color: UIColor(hue: CGFloat(index) / 10, saturation: 1, brightness: 1, alpha: 1))
            let url = try XCTUnwrap(try? store.stage(data: data, fileExtension: "jpg"))
            let page = ScannedPage(id: UUID(), imageURL: url)
            pages.append(page)
            session.append(page: page)
        }
        return (session, pages)
    }

    // MARK: - Order / structure

    @MainActor
    func testAppendPreservesOrderAndSingleGroup() throws {
        let (session, _) = try makeSession(pageCount: 4)
        XCTAssertEqual(session.pages.count, 4)
        XCTAssertEqual(session.groups.count, 1, "multipage scan stays ONE document")
        XCTAssertEqual(session.groups[0].pageIDs.count, 4)
        // Order preserved: group membership matches page insertion order.
        XCTAssertEqual(session.groups[0].pageIDs, session.pages.map(\.id))
    }

    @MainActor
    func testRemovePageUpdatesPagesAndGroups() throws {
        let (session, pages) = try makeSession(pageCount: 3)
        var mutated = session
        mutated.removePage(id: pages[1].id)
        XCTAssertEqual(mutated.pages.count, 2)
        XCTAssertFalse(mutated.pages.contains { $0.id == pages[1].id })
        XCTAssertEqual(mutated.groups[0].pageIDs.count, 2)
        XCTAssertTrue(mutated.groups.allSatisfy { $0.pageIDs.contains(pages[0].id) || $0.pageIDs.contains(pages[2].id) })
    }

    // MARK: - Rotation

    func testRotationQuarterTurnsWrapModuloFour() {
        var page = ScannedPage(id: UUID(), imageURL: URL(fileURLWithPath: "/tmp/x.jpg"))
        for _ in 0..<7 {
            page.rotationQuarterTurns = (page.rotationQuarterTurns + 1) % 4
        }
        XCTAssertEqual(page.rotationQuarterTurns, 3 % 4)
    }

    func testRotatedJPEGSwapsDimensionsOnQuarterTurn() throws {
        let data = try makeJPEGData(size: CGSize(width: 100, height: 60))
        let rotated = ScanFlowModel.rotatedJPEG(data, quarterTurns: 1)
        let original = try XCTUnwrap(UIImage(data: data))
        let after = try XCTUnwrap(UIImage(data: rotated))
        // Rotation swaps pixel dimensions (scale accounted for).
        XCTAssertEqual(after.size.width, original.size.height, accuracy: 1.0)
        XCTAssertEqual(after.size.height, original.size.width, accuracy: 1.0)
    }

    func testZeroRotationReturnsOriginalBytes() throws {
        let data = try makeJPEGData()
        XCTAssertEqual(ScanFlowModel.rotatedJPEG(data, quarterTurns: 0).count, data.count)
    }

    // MARK: - Enhancement presets

    func testOriginalPresetReturnsInputUnchanged() throws {
        let data = try makeJPEGData(color: .systemTeal)
        XCTAssertEqual(ScanEnhancement.processData(data, enhancement: .original), data)
    }

    func testAllPresetsProduceDecodableOutputWithoutCrash() throws {
        let data = try makeJPEGData(color: .lightGray)
        for preset in ScanEnhancement.allCases {
            let out = ScanEnhancement.processData(data, enhancement: preset)
            XCTAssertNotNil(UIImage(data: out), "\(preset.rawValue) must produce decodable image")
        }
    }

    func testDocumentPresetChangesPixels() throws {
        let gradient = UIGraphicsImageRenderer(size: CGSize(width: 64, height: 64)).image { _ in
            UIColor.white.setFill()
            UIBezierPath(rect: CGRect(x: 0, y: 0, width: 64, height: 64)).fill()
            UIColor.black.setStroke()
            let path = UIBezierPath()
            path.move(to: CGPoint(x: 8, y: 8))
            path.addLine(to: CGPoint(x: 56, y: 56))
            path.lineWidth = 2
            path.stroke()
        }
        let data = try XCTUnwrap(gradient.jpegData(compressionQuality: 0.9))
        XCTAssertNotEqual(ScanEnhancement.processData(data, enhancement: .document), data,
                          "document preset must actually transform pixels")
    }

    // MARK: - Batch grouping model

    @MainActor
    func testGroupBreakSplitsTrailingPagesIntoNewGroup() throws {
        let (session, pages) = try makeSession(pageCount: 4)
        var mutated = session
        mutated.insertGroupBreak(afterPageIndex: 1)
        XCTAssertEqual(mutated.groups.count, 2)
        XCTAssertEqual(mutated.groups[0].pageIDs, [pages[0].id, pages[1].id])
        XCTAssertEqual(mutated.groups[1].pageIDs, [pages[2].id, pages[3].id])
    }

    @MainActor
    func testGroupReorderReordersMembershipNotPagePixels() throws {
        let (session, pages) = try makeSession(pageCount: 4)
        var mutated = session
        mutated.insertGroupBreak(afterPageIndex: 1) // [A: p1 p2][B: p3 p4]
        let firstID = mutated.groups[0].id
        let secondID = mutated.groups[1].id
        // Move group B before A.
        mutated.moveGroups(fromOffsets: IndexSet(integer: 1), toOffset: 0)
        XCTAssertEqual(mutated.groups[0].id, secondID)
        XCTAssertEqual(mutated.groups[1].id, firstID)
        // Page pixel order untouched — groups are views over the same pages.
        XCTAssertEqual(mutated.pages.map(\.id), pages.map(\.id))
    }

    @MainActor
    func testDeleteGroupDropsOnlyItsPages() throws {
        let (session, pages) = try makeSession(pageCount: 4)
        var mutated = session
        mutated.insertGroupBreak(afterPageIndex: 1)
        let doomed = mutated.groups[1]
        mutated.removeGroup(id: doomed.id)
        XCTAssertEqual(mutated.pages.count, 2)
        XCTAssertEqual(Set(mutated.pages.map(\.id)), Set([pages[0].id, pages[1].id]))
        XCTAssertTrue(mutated.groups.allSatisfy { $0.id != doomed.id })
    }

    @MainActor
    func testRenameGroupSanitizesEmptyToPreviousName() throws {
        let (session, _) = try makeSession(pageCount: 2)
        var mutated = session
        let id = mutated.groups[0].id
        mutated.renameGroup(id: id, to: "Facture Orange")
        XCTAssertEqual(mutated.groups[0].name, "Facture Orange")
        mutated.renameGroup(id: id, to: "   ")
        XCTAssertEqual(mutated.groups[0].name, "Facture Orange", "blank rename is a no-op")
    }

    @MainActor
    func testMovePageBetweenAdjacentGroups() throws {
        let (session, pages) = try makeSession(pageCount: 3)
        var mutated = session
        mutated.insertGroupBreak(afterPageIndex: 1)
        mutated.movePage(id: pages[2].id, toAdjacentGroup: -1)
        XCTAssertEqual(mutated.groups[0].pageIDs, [pages[0].id, pages[1].id, pages[2].id])
        XCTAssertEqual(mutated.groups.count, 1, "emptied trailing group prunes away")
    }

    @MainActor
    func testSaveAllProducesOnePDFPerGroupThroughSharedEngine() async throws {
        // End-to-end through ConversionCoordinator: 2 groups of 2+1 pages.
        let (session, _) = try makeSession(pageCount: 3)
        var mutated = session
        mutated.insertGroupBreak(afterPageIndex: 1)

        var options = ConversionOptions()
        options.paperSize = .a4

        let coordinator = ConversionCoordinator()
        var pageCounts: [Int] = []
        for group in mutated.groups {
            let items = mutated.pages(in: group).enumerated().map { index, page in
                IncomingItem(kind: .image(page.imageURL), source: .photos, index: index)
            }
            let document = try await coordinator.convert(items: items, options: options)
            pageCounts.append(document.pageCount)
        }
        XCTAssertEqual(pageCounts, [2, 1], "one PDF per group with exact page counts")
    }

    // MARK: - Temp lifecycle

    func testCleanUpRemovesStagedScanFiles() throws {
        weak var weakStore: TempFileStore?
        var stagedURL: URL?
        do {
            let localStore = TempFileStore()
            weakStore = localStore
            stagedURL = try localStore.stage(data: makeJPEGData(), fileExtension: "jpg")
            XCTAssertTrue(FileManager.default.fileExists(atPath: stagedURL!.path))
            localStore.cleanUp()
            XCTAssertFalse(FileManager.default.fileExists(atPath: stagedURL!.path))
        }
        XCTAssertTrue(weakStore?.isCleanedUp ?? true)
    }

    @MainActor
    func testScanModelCleanUpResetsSession() throws {
        let model = ScanFlowModel()
        let data = try makeJPEGData()
        let url = try XCTUnwrap(try? model.stagingForTesting.stage(data: data, fileExtension: "jpg"))
        model.ingestFromTesting([url])
        XCTAssertFalse(model.session.isEmpty)
        model.cleanUp()
        XCTAssertTrue(model.session.isEmpty, "cancel wipes the review session")
    }
}

// MARK: - Test hooks (main-actor isolated accessors)

@MainActor
extension ScanFlowModel {
    /// Test-only exposure of the staging store.
    /// `internal` so tests can seed staged files without the camera.
    var stagingForTesting: TempFileStore {
        staging
    }

    /// Test-only ingest from pre-staged files (camera can't run in CI).
    func ingestFromTesting(_ urls: [URL]) {
        for url in urls {
            session.append(page: ScannedPage(id: UUID(), imageURL: url))
        }
        showingReview = !session.isEmpty
    }
}
