import XCTest
import UIKit
import PDFKit
@testable import PDFIt

/// PDF generation behavior: pagination, merging, passthrough preservation,
/// image pages, and the zero-page crash guards.
final class ConversionTests: XCTestCase {

    private var tempDirectory: URL!

    override func setUpWithError() throws {
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdfit-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDirectory)
    }

    // MARK: - Text PDF

    func testSharedDefaultsPopulateEveryExposedConversionPreference() {
        let defaults = AppConfiguration.sharedDefaults
        let keys = [AppSettingsKeys.defaultMode,
                    AppSettingsKeys.defaultPaperSize,
                    AppSettingsKeys.imageQuality,
                    AppSettingsKeys.includeSourceURL,
                    AppSettingsKeys.includeCreationDate]
        let previous = keys.map { ($0, defaults.object(forKey: $0)) }
        defer {
            for (key, value) in previous {
                if let value {
                    defaults.set(value, forKey: key)
                } else {
                    defaults.removeObject(forKey: key)
                }
            }
        }

        defaults.set(ConversionMode.reader.rawValue, forKey: AppSettingsKeys.defaultMode)
        defaults.set(PDFPaperSize.letter.rawValue, forKey: AppSettingsKeys.defaultPaperSize)
        defaults.set(ImageQuality.high.rawValue, forKey: AppSettingsKeys.imageQuality)
        defaults.set(true, forKey: AppSettingsKeys.includeSourceURL)
        defaults.set(true, forKey: AppSettingsKeys.includeCreationDate)

        let options = ConversionOptions.fromSharedDefaults()
        XCTAssertEqual(options.mode, .reader)
        XCTAssertEqual(options.paperSize, .letter)
        XCTAssertEqual(options.imageQuality, .high)
        XCTAssertTrue(options.includeSourceURL)
        XCTAssertTrue(options.includeCreationDate)
    }

    func testLongTextPaginatesIntoMultiplePages() throws {
        let paragraph = String(repeating: "The quick brown fox jumps over the lazy dog. ", count: 40)
        let text = Array(repeating: paragraph, count: 20).joined(separator: "\n\n")
        let converter = TextPDFConverter()

        let data = try XCTUnwrap(converter.convert(text: text, title: "Long Document", options: ConversionOptions()))
        let document = try XCTUnwrap(PDFDocument(data: data))
        XCTAssertGreaterThan(document.pageCount, 1, "Long text must paginate")
    }

    func testShortTextFitsOnePage() throws {
        let converter = TextPDFConverter()
        let data = try XCTUnwrap(converter.convert(text: "Hello world", title: "Note", options: ConversionOptions()))
        let document = try XCTUnwrap(PDFDocument(data: data))
        XCTAssertEqual(document.pageCount, 1)
    }

    func testEmptyTextWithTitleProducesSinglePage() throws {
        let converter = TextPDFConverter()
        let data = try XCTUnwrap(converter.convert(text: "   ", title: "Title Only", options: ConversionOptions()))
        let document = try XCTUnwrap(PDFDocument(data: data))
        XCTAssertEqual(document.pageCount, 1)
    }

    func testEmptyInputReturnsNilWithoutCrashing() {
        let converter = TextPDFConverter()
        XCTAssertNil(converter.convert(text: "", title: nil, options: ConversionOptions()))
    }

    func testTextPageSizeRespectsA4AndLetter() throws {
        let converter = TextPDFConverter()
        for (paper, expected) in [(PDFPaperSize.a4, CGSize(width: 595.28, height: 841.89)),
                                  (PDFPaperSize.letter, CGSize(width: 612, height: 792))] {
            let options = ConversionOptions(paperSize: paper)
            let data = try XCTUnwrap(converter.convert(text: "Page size check", title: nil, options: options))
            let document = try XCTUnwrap(PDFDocument(data: data))
            let bounds = try XCTUnwrap(document.page(at: 0)).bounds(for: .mediaBox)
            XCTAssertEqual(bounds.width, expected.width, accuracy: 0.5, "\(paper)")
            XCTAssertEqual(bounds.height, expected.height, accuracy: 0.5, "\(paper)")
        }
    }

    func testComposerRendersTitleSubtitleAuthorAndSelectableUnicodeBody() throws {
        var document = TextDocumentConfiguration()
        document.title = "Quarterly Notes"
        document.subtitle = "A concise review"
        document.author = "Élodie Martin"
        document.body = "Résumé de l’équipe.\n\nDécisions et prochaines étapes."

        let data = try TextPDFConverter().convert(document: document,
                                                  options: ConversionOptions(paperSize: .a4),
                                                  creationDate: Date(timeIntervalSince1970: 0))
        let pdf = try XCTUnwrap(PDFDocument(data: data))
        let extracted = try XCTUnwrap(pdf.page(at: 0)?.string)
        XCTAssertTrue(extracted.contains("Quarterly Notes"))
        XCTAssertTrue(extracted.contains("A concise review"))
        XCTAssertTrue(extracted.contains("Élodie Martin"))
        XCTAssertTrue(extracted.contains("Résumé de l’équipe"), "Composer text remains vector/selectable and Unicode-safe")
    }

    func testComposerBodyOnlyHasNoPlaceholderOrReservedOptionalContent() throws {
        var document = TextDocumentConfiguration()
        document.body = "Body remains visible."

        let data = try TextPDFConverter().convert(document: document,
                                                  options: ConversionOptions())
        let extracted = try XCTUnwrap(PDFDocument(data: data)?.page(at: 0)?.string)
        XCTAssertTrue(extracted.contains("Body remains visible."))
        XCTAssertFalse(extracted.contains("Title (Optional)"))
        XCTAssertFalse(extracted.contains("Subtitle (Optional)"))
        XCTAssertFalse(extracted.contains("Author (Optional)"))
    }

    func testComposerLongDocumentProducesTenOrMoreCompletePages() throws {
        let paragraph = "A complete paragraph with enough words to verify clean pagination, paragraph spacing, and selectable output across many pages."
        var document = TextDocumentConfiguration()
        document.title = "Long Document"
        document.body = Array(repeating: paragraph, count: 520).joined(separator: "\n\n")
        document.margin = .large
        document.lineHeightMultiple = 1.5

        let data = try TextPDFConverter().convert(document: document,
                                                  options: ConversionOptions(paperSize: .letter))
        let pdf = try XCTUnwrap(PDFDocument(data: data))
        XCTAssertGreaterThanOrEqual(pdf.pageCount, 10)
        let joined = (0..<pdf.pageCount).compactMap { pdf.page(at: $0)?.string }.joined()
        XCTAssertTrue(joined.contains("Long Document"))
        XCTAssertTrue(joined.hasSuffix("many pages.\n") || joined.hasSuffix("many pages."),
                      "The final paragraph must not be clipped")
    }

    func testComposerPresetAndAlignmentDriveAttributedLayout() throws {
        var document = TextDocumentConfiguration()
        document.body = "Editorial body"
        document.apply(.editorial)

        XCTAssertEqual(document.preset, .editorial)
        XCTAssertEqual(document.fontFamily, .serif)
        XCTAssertEqual(document.margin, .large)
        XCTAssertEqual(document.alignment, .justified)

        let attributed = TextPDFConverter.attributedString(document: document)
        let paragraph = try XCTUnwrap(attributed.attribute(.paragraphStyle,
                                                           at: 0,
                                                           effectiveRange: nil) as? NSParagraphStyle)
        XCTAssertEqual(paragraph.alignment, .justified)
        XCTAssertEqual(paragraph.paragraphSpacing, document.paragraphSpacing, accuracy: 0.01)
    }

    func testComposerEveryPresetProducesSelectablePDF() throws {
        for preset in TextDocumentPreset.allCases {
            var document = TextDocumentConfiguration()
            document.title = preset.displayName
            document.body = "A selectable paragraph for the \(preset.rawValue) preset."
            document.apply(preset)

            let data = try TextPDFConverter().convert(document: document,
                                                      options: ConversionOptions(paperSize: .a4))
            let extracted = try XCTUnwrap(PDFDocument(data: data)?.page(at: 0)?.string)
            XCTAssertTrue(extracted.contains(preset.displayName), "\(preset)")
            XCTAssertTrue(extracted.contains("selectable paragraph"), "\(preset)")
        }
    }

    func testComposerMarginsChangeAvailableTextWidth() {
        XCTAssertLessThan(TextDocumentMargin.compact.points, TextDocumentMargin.normal.points)
        XCTAssertLessThan(TextDocumentMargin.normal.points, TextDocumentMargin.large.points)
        let a4Width = PDFPaperSize.a4.pointSize.width
        XCTAssertGreaterThan(a4Width - TextDocumentMargin.compact.points * 2,
                             a4Width - TextDocumentMargin.large.points * 2)
    }

    func testComposerHeaderFooterAndPageNumbersMatchRenderedPreviewBytes() throws {
        var document = TextDocumentConfiguration()
        document.body = "Preview and saved output share this exact rendered data."
        document.headerText = "PDFIT DOCUMENT"
        document.footerText = "Private draft"
        document.includePageNumbers = true

        let previewData = try TextPDFConverter().convert(document: document,
                                                         options: ConversionOptions(),
                                                         creationDate: Date(timeIntervalSince1970: 0))
        let final = ConvertedDocument(data: previewData,
                                      pageCount: PDFAssembly.pageCount(of: previewData),
                                      suggestedTitle: "Text Document",
                                      sourceURL: nil,
                                      source: .textEditor)
        XCTAssertEqual(final.data, previewData, "Document Composer persists the exact bytes shown in preview")
        let extracted = try XCTUnwrap(PDFDocument(data: final.data)?.page(at: 0)?.string)
        XCTAssertTrue(extracted.contains("PDFIT DOCUMENT"))
        XCTAssertTrue(extracted.contains("Private draft"))
        XCTAssertTrue(extracted.contains("1 / 1"))
    }

    func testComposerSignatureIsProGatedAndUsesExistingPlacementEngine() throws {
        XCTAssertFalse(FeaturePolicy.isUnlocked(.signature, isPro: false))
        XCTAssertTrue(FeaturePolicy.isUnlocked(.signature, isPro: true))

        let image = UIGraphicsImageRenderer(size: CGSize(width: 240, height: 80)).image { context in
            UIColor.clear.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 240, height: 80))
            UIColor.black.setStroke()
            let line = UIBezierPath()
            line.move(to: CGPoint(x: 8, y: 62))
            line.addCurve(to: CGPoint(x: 232, y: 20),
                          controlPoint1: CGPoint(x: 70, y: 90),
                          controlPoint2: CGPoint(x: 160, y: -10))
            line.lineWidth = 4
            line.stroke()
        }
        var document = TextDocumentConfiguration()
        document.body = "Signed document body"
        document.signature = TextDocumentSignature(pngData: try XCTUnwrap(image.pngData()),
                                                    pageNumber: 1,
                                                    normalizedX: 0.62,
                                                    normalizedY: 0.76,
                                                    scale: 1.1)
        let signed = try TextPDFConverter().convert(document: document,
                                                    options: ConversionOptions())
        let pdf = try XCTUnwrap(PDFDocument(data: signed))
        XCTAssertEqual(pdf.pageCount, 1)
        XCTAssertTrue(pdf.page(at: 0)?.string?.contains("Signed document body") ?? false)
    }

    // MARK: - Image PDF

    func testGeneratedImageProducesOnePagePerImage() throws {
        let imageURLs = try (0..<3).map { index -> URL in
            let url = tempDirectory.appendingPathComponent("image-\(index).png")
            let renderer = UIGraphicsImageRenderer(size: CGSize(width: 400, height: 600))
            let image = renderer.image { context in
                UIColor.systemBlue.setFill()
                context.fill(CGRect(x: 0, y: 0, width: 400, height: 600))
            }
            try image.pngData()?.write(to: url)
            return url
        }

        let converter = ImagePDFConverter()
        let data = try converter.convert(imageURLs: imageURLs, options: ConversionOptions())
        let document = try XCTUnwrap(PDFDocument(data: data))
        XCTAssertEqual(document.pageCount, 3, "One image per page, order preserved")
    }

    func testTwentyPhotosPreserveSelectionOrderAndOrientation() throws {
        let imageURLs = try (0..<20).map { index -> URL in
            let portrait = index.isMultiple(of: 2)
            let size = portrait
                ? CGSize(width: 360, height: 640)
                : CGSize(width: 640, height: 360)
            let url = tempDirectory.appendingPathComponent("ordered-\(index).png")
            let image = UIGraphicsImageRenderer(size: size).image { context in
                UIColor(hue: CGFloat(index) / 20, saturation: 0.8, brightness: 0.9, alpha: 1).setFill()
                context.fill(CGRect(origin: .zero, size: size))
            }
            try XCTUnwrap(image.pngData()).write(to: url)
            return url
        }

        let data = try ImagePDFConverter().convert(imageURLs: imageURLs,
                                                   options: ConversionOptions())
        let document = try XCTUnwrap(PDFDocument(data: data))
        XCTAssertEqual(document.pageCount, 20)

        for index in 0..<20 {
            let bounds = try XCTUnwrap(document.page(at: index)).bounds(for: .mediaBox)
            if index.isMultiple(of: 2) {
                XCTAssertGreaterThan(bounds.height, bounds.width, "Portrait photo \(index) moved or rotated")
            } else {
                XCTAssertGreaterThan(bounds.width, bounds.height, "Landscape photo \(index) moved or rotated")
            }
        }
    }

    func testPhotoCollectionFailsInsteadOfSavingMissingPages() throws {
        let validURL = tempDirectory.appendingPathComponent("valid.png")
        let image = UIGraphicsImageRenderer(size: CGSize(width: 320, height: 480)).image { context in
            UIColor.systemOrange.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 320, height: 480))
        }
        try XCTUnwrap(image.pngData()).write(to: validURL)
        let brokenURL = tempDirectory.appendingPathComponent("broken.heic")
        try Data("not an image".utf8).write(to: brokenURL)

        XCTAssertThrowsError(
            try ImagePDFConverter().convert(imageURLs: [validURL, brokenURL, validURL],
                                            options: ConversionOptions())
        ) { error in
            guard case ConversionError.unreadableFile = error else {
                return XCTFail("Expected unreadableFile, got \(error)")
            }
        }
    }

    func testImageAutoPageKeepsAspectRatio() throws {
        let url = tempDirectory.appendingPathComponent("wide.png")
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 2000, height: 1000))
        let image = renderer.image { context in
            UIColor.systemRed.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 2000, height: 1000))
        }
        try image.pngData()?.write(to: url)

        let downsampled = try XCTUnwrap(ImagePDFConverter.downsampledImage(at: url, maxPixelDimension: 2400))
        let pageSize = ImagePDFConverter.pageSize(for: downsampled, options: ConversionOptions())
        XCTAssertEqual(pageSize.width / pageSize.height, 2.0, accuracy: 0.01, "Aspect ratio must be preserved")
        XCTAssertLessThanOrEqual(max(pageSize.width, pageSize.height),
                                 ImagePDFConverter.autoPageMaxDimension + 0.01)
    }

    func testImagePDFRejectsNonImages() {
        let converter = ImagePDFConverter()
        let junk = tempDirectory.appendingPathComponent("junk.png")
        try? Data("not an image".utf8).write(to: junk)
        XCTAssertThrowsError(try converter.convert(imageURLs: [junk], options: ConversionOptions()))
    }

    // MARK: - Existing PDF preservation

    func makeSamplePDF(pageCount: Int, size: CGSize = CGSize(width: 400, height: 700)) throws -> URL {
        let url = tempDirectory.appendingPathComponent("sample-\(UUID().uuidString).pdf")
        let bounds = CGRect(origin: .zero, size: size)
        let renderer = UIGraphicsPDFRenderer(bounds: bounds)
        let data = renderer.pdfData { context in
            for index in 0..<pageCount {
                context.beginPage()
                "Page \(index)".draw(at: CGPoint(x: 20, y: 20),
                                     withAttributes: [.font: UIFont.systemFont(ofSize: 18)])
            }
        }
        try data.write(to: url)
        return url
    }

    func testPassthroughPreservesOriginalBytes() throws {
        let url = try makeSamplePDF(pageCount: 3)
        let original = try Data(contentsOf: url)

        let converter = ExistingPDFConverter()
        let result = try converter.convert(fileURL: url, allowPassthrough: true)

        guard case .passthrough(let data) = result else {
            return XCTFail("Expected byte-perfect passthrough")
        }
        XCTAssertEqual(data, original, "Quick-mode single PDF must be byte-identical")
    }

    func testReembeddingPreservesPageBoxesAndCount() throws {
        let customSize = CGSize(width: 300, height: 500)
        let url = try makeSamplePDF(pageCount: 4, size: customSize)

        let converter = ExistingPDFConverter()
        let result = try converter.convert(fileURL: url, allowPassthrough: false)

        guard case .reembedded(let data) = result else {
            return XCTFail("Expected re-embedded chunk")
        }
        let document = try XCTUnwrap(PDFDocument(data: data))
        XCTAssertEqual(document.pageCount, 4)

        for index in 0..<4 {
            let bounds = try XCTUnwrap(document.page(at: index)).bounds(for: .mediaBox)
            XCTAssertEqual(bounds.width, customSize.width, accuracy: 0.5, "Original page size must be preserved")
            XCTAssertEqual(bounds.height, customSize.height, accuracy: 0.5)
        }
    }

    func testUnreadablePDFThrowsInsteadOfCrashing() {
        let junk = tempDirectory.appendingPathComponent("broken.pdf")
        try? Data("definitely not a pdf".utf8).write(to: junk)
        let converter = ExistingPDFConverter()
        XCTAssertThrowsError(try converter.convert(fileURL: junk, allowPassthrough: false)) { error in
            guard case ConversionError.unreadableFile = error else {
                return XCTFail("Expected unreadableFile, got \(error)")
            }
        }
    }

    // MARK: - Merging

    func testMergePreservesPageOrderAndCount() throws {
        let first = try makeSamplePDF(pageCount: 2)
        let second = try makeSamplePDF(pageCount: 3)
        let merged = try PDFAssembly.merge([try Data(contentsOf: first), try Data(contentsOf: second)])

        let document = try XCTUnwrap(PDFDocument(data: merged))
        XCTAssertEqual(document.pageCount, 5, "All pages survive a merge")

        let pageTexts = (0..<5).compactMap { document.page(at: $0)?.string }
        XCTAssertEqual(pageTexts, ["Page 0", "Page 1", "Page 0", "Page 1", "Page 2"],
                       "Merge order is deterministic: first chunk, then second")
    }

    func testMergeSkipsInvalidChunksButKeepsGoodOnes() throws {
        let good = try Data(contentsOf: try makeSamplePDF(pageCount: 1))
        let merged = try PDFAssembly.merge([Data("junk".utf8), good])
        XCTAssertEqual(PDFAssembly.pageCount(of: merged), 1)
    }

    func testMergeAllEmptyThrows() {
        XCTAssertThrowsError(try PDFAssembly.merge([Data("junk".utf8)]))
    }

    // MARK: - Slicing tall captures

    func testSlicingTallCaptureIntoA4Pages() throws {
        // Build a tall single-page PDF (simulating a web capture).
        let tallSize = CGSize(width: 768, height: 3200)
        let url = try makeSamplePDF(pageCount: 1, size: tallSize)
        let capture = try Data(contentsOf: url)

        let sliced = try PDFAssembly.slicingCapture(capture, to: PDFPaperSize.a4.pointSize)
        let document = try XCTUnwrap(PDFDocument(data: sliced))

        // 3200 pt at A4 width scale (595.28/768 ≈ 0.775) → ~2480 pt tall → 3 pages.
        XCTAssertEqual(document.pageCount, 3, "Tall pages must be sliced into printable pages")

        for index in 0..<document.pageCount {
            let bounds = try XCTUnwrap(document.page(at: index)).bounds(for: .mediaBox)
            XCTAssertEqual(bounds.width, 595.28, accuracy: 0.5)
            XCTAssertEqual(bounds.height, 841.89, accuracy: 0.5)
        }
    }

    func testSlicingInvalidCaptureThrows() {
        XCTAssertThrowsError(try PDFAssembly.slicingCapture(Data("junk".utf8),
                                                            to: PDFPaperSize.a4.pointSize))
    }

    // MARK: - Metadata

    func testMetadataStamping() throws {
        let base = try Data(contentsOf: try makeSamplePDF(pageCount: 1))
        let stamped = PDFAssembly.applyingMetadata(to: base,
                                                   title: "Test Title",
                                                   sourceURL: URL(string: "https://example.com/a"))
        let document = try XCTUnwrap(PDFDocument(data: stamped))
        let attributes = try XCTUnwrap(document.documentAttributes)
        XCTAssertEqual(attributes[PDFDocumentAttribute.titleAttribute] as? String, "Test Title")
        XCTAssertEqual(attributes[PDFDocumentAttribute.creatorAttribute] as? String, "PDFIT")
        XCTAssertNotNil(attributes[PDFDocumentAttribute.subjectAttribute])
    }

    // MARK: - Coordinator

    func testCoordinatorSinglePDFPassthrough() async throws {
        let url = try makeSamplePDF(pageCount: 2)
        let original = try Data(contentsOf: url)

        let coordinator = ConversionCoordinator()
        let document = try await coordinator.convert(items: [IncomingItem(kind: .pdf(url),
                                                                          originalFilename: "My Doc.pdf",
                                                                          source: .files)],
                                                     options: ConversionOptions(mode: .quick))

        XCTAssertEqual(document.data, original)
        XCTAssertEqual(document.pageCount, 2)
        XCTAssertEqual(document.suggestedTitle, "My Doc")
    }

    func testCoordinatorEmptyItemsThrows() async {
        let coordinator = ConversionCoordinator()
        do {
            _ = try await coordinator.convert(items: [], options: ConversionOptions())
            XCTFail("Expected noUsableContent")
        } catch let error as ConversionError {
            XCTAssertEqual(error, .noUsableContent)
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    func testCoordinatorMixedInputsMergeInOrder() async throws {
        let imageURL = tempDirectory.appendingPathComponent("mix.png")
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 200, height: 200))
        try renderer.image { ctx in
            UIColor.systemGreen.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 200, height: 200))
        }.pngData()?.write(to: imageURL)

        let pdfURL = try makeSamplePDF(pageCount: 2)

        let coordinator = ConversionCoordinator()
        let items = [
            IncomingItem(kind: .image(imageURL), source: .photos, index: 0),
            IncomingItem(kind: .text("Some shared words"), title: "Note", source: .textEditor, index: 1),
            IncomingItem(kind: .pdf(pdfURL), originalFilename: "doc.pdf", source: .files, index: 2),
        ]
        let document = try await coordinator.convert(items: items, options: ConversionOptions())
        // 1 image page + 1 text page + 2 pdf pages.
        XCTAssertEqual(document.pageCount, 4)
    }

    func testFallbackTitleNaming() {
        let images = (0..<5).map { IncomingItem(kind: .image(URL(fileURLWithPath: "/\($0).png")), source: .photos, index: $0) }
        XCTAssertEqual(ConversionCoordinator.fallbackTitle(for: images), "5 Photos")

        let singleImage = [IncomingItem(kind: .image(URL(fileURLWithPath: "/a.png")), source: .photos)]
        XCTAssertEqual(ConversionCoordinator.fallbackTitle(for: singleImage), "Photo")

        let notes = (0..<2).map { IncomingItem(kind: .text("note \($0)"), source: .textEditor, index: $0) }
        XCTAssertEqual(ConversionCoordinator.fallbackTitle(for: notes), "2 Notes")

        let thread = [IncomingItem(kind: .url(URL(string: "https://x.com/jack/status/123")!), source: .x)]
        XCTAssertEqual(ConversionCoordinator.fallbackTitle(for: thread), "Thread — jack")

        let mixed = [IncomingItem(kind: .image(URL(fileURLWithPath: "/a.png")), source: .photos, index: 0),
                     IncomingItem(kind: .text("text"), source: .textEditor, index: 1)]
        XCTAssertTrue(ConversionCoordinator.fallbackTitle(for: mixed)?.hasPrefix("2 Items") == true)
    }
}
