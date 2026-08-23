import XCTest
import UIKit
import PDFKit
@testable import PDFIt

/// OCR pipeline + smart naming regressions. All local — no network.
final class OCRRouterTests: XCTestCase {

    private func makeTextImage(lines: [String]) -> Data {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 600, height: 300))
        let image = renderer.image { ctx in
            UIColor.white.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 600, height: 300))
            for (index, line) in lines.enumerated() {
                line.draw(at: CGPoint(x: 40, y: 40 + CGFloat(index) * 44),
                          withAttributes: [.font: UIFont.systemFont(ofSize: 30, weight: .semibold),
                                           .foregroundColor: UIColor.black])
            }
        }
        return image.jpegData(compressionQuality: 0.92)!
    }

    // MARK: - Recognition

    func testRecognitionExtractsPrintedTextLocally() async throws {
        let data = makeTextImage(lines: ["FACTURE ORANGE", "12/08/2026", "Montant: 49,99 EUR"])
        let result = try await OCRRouter.recognize(imageData: data)
        let text = result.fullText.uppercased()
        XCTAssertTrue(text.contains("FACTURE") || text.contains("ORANGE"),
                      "printed words must be recognized; got: \(text)")
        XCTAssertGreaterThan(result.meanConfidence, 0.3)
    }

    func testRecognitionOnBlankImageYieldsLowConfidence() async throws {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 400, height: 400))
        let blank = renderer.image { ctx in
            UIColor.white.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 400, height: 400))
        }
        let data = blank.jpegData(compressionQuality: 0.9)!
        let result = try await OCRRouter.recognize(imageData: data)
        XCTAssertLessThan(result.meanConfidence, OCRRouter.minimumUsefulConfidence + 0.3,
                          "blank page must not produce confident garbage")
    }

    private func context_fill2(_ context: UIGraphicsImageRendererContext) {
        context.fill(CGRect(x: 0, y: 0, width: 400, height: 400))
    }

    // MARK: - Searchable PDF

    func testSearchablePDFKeepsPageCountAndBecomesTextSearchable() async throws {
        // Build a 2-page "scan" from text images.
        let pageData = makeTextImage(lines: ["CONTRAT DE BAIL", "Page de test OCR"])
        let image = try XCTUnwrap(UIImage(data: pageData))
        let bounds = CGRect(origin: .zero, size: CGSize(width: 612, height: 792))
        let scanPDF = UIGraphicsPDFRenderer(bounds: bounds).pdfData { context in
            for _ in 0..<2 {
                context.beginPage()
                image.draw(in: bounds)
            }
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ocr-\(UUID()).pdf")
        try scanPDF.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        // Before OCR: no selectable text.
        let before = try XCTUnwrap(PDFDocument(url: url))
        XCTAssertEqual(before.pageCount, 2)
        let rawTextBefore = ((before.page(at: 0)?.string) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertTrue(rawTextBefore.isEmpty || rawTextBefore.count < 5,
                      "image-only page has no text layer before OCR")

        let searchable = try await OCRRouter.makeSearchablePDF(from: url)
        let after = try XCTUnwrap(PDFDocument(data: searchable))
        XCTAssertEqual(after.pageCount, 2, "page count never changes")

        let recognized = after.page(at: 0)?.string ?? ""
        XCTAssertTrue(recognized.uppercased().contains("CONTRAT") || recognized.uppercased().contains("BAIL"),
                      "recognized text layer must be present and selectable; got: \(recognized.prefix(120))")
    }

    // MARK: - Smart naming

    @MainActor
    func testSmartNamingUsesOCRKeywordLine() {
        let name = OCRRouter.suggestedName(
            ocrText: """
            EDF
            FACTURE ORANGE MOBILE
            12/08/2026
            Montant: 19,99
            """,
            fallbackTitle: nil, date: Date(timeIntervalSince1970: 1_755_000_000))
        XCTAssertTrue(name.lowercased().contains("facture"),
                      "keyword line drives the suggestion; got \(name)")
    }

    @MainActor
    func testSmartNamingFallsBackToScanWhenOCRUnhelpful() {
        let name = OCRRouter.suggestedName(ocrText: "", fallbackTitle: nil)
        XCTAssertTrue(name.lowercased().hasPrefix("scan"), "low confidence → safe fallback: \(name)")
    }

    @MainActor
    func testSmartNamingUsesWebpageTitle() {
        let name = OCRRouter.suggestedName(ocrText: nil,
                                           fallbackTitle: "How to Brew Tea — Guide",
                                           sourceHost: nil)
        XCTAssertTrue(name.contains("How to Brew Tea"))
    }

    @MainActor
    func testSmartNamingSanitizesIllegalCharacters() {
        let name = OCRRouter.suggestedName(ocrText: "Facture: EDF/orange\n2026", fallbackTitle: nil)
        XCTAssertFalse(name.contains("/"), "path separators must be sanitized: \(name)")
    }

    @MainActor
    func testMeaningfulNameCapsLengthAndWords() {
        let long = String(repeating: "MotTrèsLong ", count: 20)
        let candidate = OCRRouter.meaningfulName(from: long)
        XCTAssertNotNil(candidate)
        XCTAssertLessThanOrEqual(candidate!.count, 48)
    }

    // MARK: - Feature policy for OCR gate

    @MainActor
    func testOCRGatedBehindPro() {
        final class FakeEntitlements: EntitlementReading {
            let isPro: Bool
            init(isPro: Bool) { self.isPro = isPro }
        }
        XCTAssertTrue(FeaturePolicy.isUnlocked(.ocr, entitlement: FakeEntitlements(isPro: true)))
        XCTAssertFalse(FeaturePolicy.isUnlocked(.ocr, entitlement: FakeEntitlements(isPro: false)))
    }
}
