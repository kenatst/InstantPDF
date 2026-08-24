import XCTest
import UIKit
import PDFKit
@testable import PDFIt

/// PDF Tools regressions: extraction ordering, compression behavior,
/// signature placement — originals always preserved, output always valid.
final class PDFToolsTests: XCTestCase {

    private var sourceURL: URL!

    override func setUpWithError() throws {
        // 4-page fixture: page N carries marker text "PAGE-N".
        let bounds = CGRect(x: 0, y: 0, width: 400, height: 600)
        let data = UIGraphicsPDFRenderer(bounds: bounds).pdfData { context in
            for index in 1...4 {
                context.beginPage()
                "PAGE-\(index)".draw(at: CGPoint(x: 40, y: 40),
                                     withAttributes: [.font: UIFont.boldSystemFont(ofSize: 32)])
            }
        }
        sourceURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdftools-\(UUID().uuidString).pdf")
        try data.write(to: sourceURL)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: sourceURL!)
    }

    private func originalBytes() throws -> Data {
        try Data(contentsOf: sourceURL)
    }

    // MARK: - Extract

    func testExtractSelectsPagesInUserOrder() throws {
        let extracted = try PDFTools.extractPages(from: sourceURL, pageNumbers: [3, 1])
        let document = try XCTUnwrap(PDFDocument(data: extracted))
        XCTAssertEqual(document.pageCount, 2)
        XCTAssertTrue(document.page(at: 0)?.string?.contains("PAGE-3") ?? false,
                      "user order wins: first output page is PAGE-3")
        XCTAssertTrue(document.page(at: 1)?.string?.contains("PAGE-1") ?? false)
    }

    func testExtractIgnoresOutOfRangePages() throws {
        let extracted = try PDFTools.extractPages(from: sourceURL, pageNumbers: [0, 2, 9])
        let document = try XCTUnwrap(PDFDocument(data: extracted))
        XCTAssertEqual(document.pageCount, 1)
        XCTAssertTrue(document.page(at: 0)?.string?.contains("PAGE-2") ?? false)
    }

    func testExtractPreservesOriginalFileBytes() throws {
        let before = try originalBytes()
        _ = try PDFTools.extractPages(from: sourceURL, pageNumbers: [1])
        XCTAssertEqual(try originalBytes(), before, "extraction must never touch the original")
    }

    // MARK: - Organize

    func testOrganizeRemovesAndRotatesPages() throws {
        // Output: page 2 rotated 90°, then page 4. Page 1 and 3 dropped.
        let organized = try PDFTools.organizePages(from: sourceURL,
                                                   operations: [(page: 2, quarterTurns: 1),
                                                                (page: 4, quarterTurns: 0)])
        let document = try XCTUnwrap(PDFDocument(data: organized))
        XCTAssertEqual(document.pageCount, 2)
        XCTAssertTrue(document.page(at: 0)?.string?.contains("PAGE-2") ?? false)

        // Rotation swaps the media box (portrait 400×600 → landscape).
        let box = document.page(at: 0)!.bounds(for: .mediaBox)
        XCTAssertEqual(box.width, 600, accuracy: 1.0)
        XCTAssertEqual(box.height, 400, accuracy: 1.0)
    }

    func testOrganizePreservesOriginalFileBytes() throws {
        let before = try originalBytes()
        _ = try PDFTools.organizePages(from: sourceURL, operations: [(page: 1, quarterTurns: 2)])
        XCTAssertEqual(try originalBytes(), before)
    }

    // MARK: - Compression

    /// Image-heavy fixture: one big photo per page.
    private func makeImageHeavyPDF(pages: Int) throws -> URL {
        // Deterministic pseudo-random noise: JPEG re-encode of noise is much
        // smaller than lossless-ish embedding, guaranteeing a real shrink
        // even with the readability-floor presets.
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 800, height: 1100))
        let noisyImage = renderer.image { context in
            UIColor.systemTeal.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 800, height: 1100))
            var seed: UInt64 = 0x9E3779B97F4A7C15
            func nextByte() -> UInt8 {
                seed = seed &* 6364136223846793005 &+ 1442695040888963407
                return UInt8(truncatingIfNeeded: seed >> 33)
            }
            for _ in 0..<(120_000) {
                let x = CGFloat(nextByte() % 200) * 4
                let y = CGFloat(nextByte() % 255) * 4
                let s = CGFloat(nextByte() % 8) + 2
                UIColor(red: CGFloat(nextByte()) / 255,
                        green: CGFloat(nextByte()) / 255,
                        blue: CGFloat(nextByte()) / 255,
                        alpha: 1).setFill()
                context.fill(CGRect(x: x, y: y, width: s, height: s))
            }
        }
        let imageData = try XCTUnwrap(noisyImage.jpegData(compressionQuality: 1.0))
        let image = try XCTUnwrap(UIImage(data: imageData))

        let bounds = CGRect(x: 0, y: 0, width: 612, height: 792)
        let pdf = UIGraphicsPDFRenderer(bounds: bounds).pdfData { context in
            for _ in 0..<pages {
                context.beginPage()
                image.draw(in: bounds)
            }
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("heavy-\(UUID().uuidString).pdf")
        try pdf.write(to: url)
        return url
    }

    func testCompressionOnImageHeavyPDFShrinksOutputAndPreservesPages() throws {
        // 6 noisy photo pages at high quality — big enough that even the
        // readability-floor re-encode (≥2x render, q0.55) shrinks meaningfully.
        let heavy = try makeImageHeavyPDF(pages: 6)
        defer { try? FileManager.default.removeItem(at: heavy) }
        let before = try Data(contentsOf: heavy).count

        let result = try PDFTools.compress(from: heavy, preset: .smaller)

        XCTAssertEqual(PDFAssembly.pageCount(of: result.data), 6, "page count never changes")
        XCTAssertLessThan(result.byteCount, before,
                          "image-heavy document must actually shrink (\(result.byteCount) vs \(before))")
        // Original untouched.
        XCTAssertEqual(try Data(contentsOf: heavy).count, before)
    }

    func testCompressionKeepsVectorTextReadable() throws {
        // Text fixture: rasterizing would LOSE — must pass through untouched-ish.
        let result = try PDFTools.compress(from: sourceURL, preset: .smaller)
        XCTAssertEqual(PDFAssembly.pageCount(of: result.data), 4)
        let document = try XCTUnwrap(PDFDocument(data: result.data))
        XCTAssertTrue(document.page(at: 0)?.string?.contains("PAGE-1") ?? false,
                      "vector/text pages keep searchable text")
    }

    // MARK: - Signature

    private func makeSignaturePNG() throws -> Data {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 300, height: 120))
        let image = renderer.image { context in
            UIColor.clear.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 300, height: 120))
            UIColor.black.setStroke()
            let path = UIBezierPath()
            path.move(to: CGPoint(x: 10, y: 90))
            path.addCurve(to: CGPoint(x: 290, y: 30),
                          controlPoint1: CGPoint(x: 100, y: 160),
                          controlPoint2: CGPoint(x: 200, y: 0))
            path.lineWidth = 4
            path.stroke()
        }
        return try XCTUnwrap(image.pngData())
    }

    func testSignaturePlacementRendersOnlyOnTargetPages() throws {
        let signature = try makeSignaturePNG()
        let signed = try PDFTools.placeSignature(pngData: signature,
                                                 on: sourceURL,
                                                 pages: [2],
                                                 normalizedRect: CGRect(x: 0.55, y: 0.85, width: 0.35, height: 0.1))
        let document = try XCTUnwrap(PDFDocument(data: signed))
        XCTAssertEqual(document.pageCount, 4, "placement never adds/removes pages")

        // Page annotations/images differ between page 1 (unsigned) and 2 (signed).
        let page1 = try XCTUnwrap(document.page(at: 0))
        let page2 = try XCTUnwrap(document.page(at: 1))
        let p1Data = page1.dataRepresentation!
        let p2Data = page2.dataRepresentation!
        XCTAssertNotEqual(p1Data.count, p2Data.count,
                          "signed page carries the extra image XObject")
        XCTAssertTrue(document.page(at: 1)?.string?.contains("PAGE-2") ?? false,
                      "original page content remains visible under the signature layer")
    }

    func testSignaturePreservesOriginalFileBytes() throws {
        let before = try originalBytes()
        let signature = try makeSignaturePNG()
        _ = try PDFTools.placeSignature(pngData: signature,
                                        on: sourceURL,
                                        pages: [1],
                                        normalizedRect: CGRect(x: 0.5, y: 0.8, width: 0.4, height: 0.12))
        XCTAssertEqual(try originalBytes(), before, "signing must never modify the original file")
    }
}
