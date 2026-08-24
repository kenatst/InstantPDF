import Foundation
import UIKit
import PDFKit
import CoreGraphics

/// Applies optional personalization to a finished PDF:
/// • document title / author metadata
/// • an optional cover page
/// • a subtle diagonal text watermark on every content page
/// • page numbers (drawn per page)
///
/// Page numbers and watermarks are drawn by REDRAWING each page into a new
/// context at its original size — vector content stays vector, and existing
/// PDFs passed through Quick mode are never routed through this layer.
enum PersonalizationApplier {

    /// Sane, subtle watermark defaults.
    static let watermarkOpacity: CGFloat = 0.08
    static let watermarkFontSize: CGFloat = 42

    // MARK: - Entry point

    /// Returns personalized data, or the original data untouched when the
    /// customization carries nothing to apply.
    static func apply(to data: Data,
                      customization: PDFCustomization,
                      options: ConversionOptions,
                      sourceURL: URL?,
                      creationDate: Date = Date()) -> Data {
        guard !customization.isEmpty else { return data }

        var working = data

        if customization.includeCoverPage {
            working = prependCoverPage(to: working,
                                       customization: customization,
                                       options: options,
                                       sourceURL: sourceURL,
                                       date: creationDate) ?? working
        }

        let needsWatermark = customization.trimmedWatermark != nil
        let needsNumbers = customization.includePageNumbers && pageCount(of: working) > 1
        if needsWatermark || needsNumbers {
            working = stamp(working) { index, total, pageBounds, cgContext in
                if needsWatermark, let text = customization.trimmedWatermark {
                    drawWatermark(text, in: pageBounds, cgContext: cgContext)
                }
                if needsNumbers {
                    drawPageNumber(index + 1, total: total, in: pageBounds)
                }
            } ?? working
        }

        return applyingMetadata(to: working,
                                title: customization.trimmedDocumentTitle ?? "",
                                author: customization.trimmedAuthor,
                                sourceURL: sourceURL,
                                keepExistingTitleWhenEmpty: true)
    }

    // MARK: - Cover page

    static func makeCoverPage(customization: PDFCustomization,
                              options: ConversionOptions,
                              sourceURL: URL?,
                              date: Date) -> Data? {
        let pageSize = options.paperSize.isFixed ? options.paperSize.pointSize : PDFPaperSize.a4.pointSize
        let bounds = CGRect(origin: .zero, size: pageSize)

        let title = customization.coverTitle.isEmpty
            ? (customization.trimmedDocumentTitle ?? "")
            : customization.coverTitle
        let subtitle = customization.coverSubtitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty || !subtitle.isEmpty || customization.includeCreationDateFooter || sourceURL != nil else {
            return nil
        }

        let formatter = DateFormatter()
        formatter.dateStyle = .long
        let dateString = formatter.string(from: date)

        let renderer = UIGraphicsPDFRenderer(bounds: bounds, format: UIGraphicsPDFRendererFormat())
        return renderer.pdfData { context in
            context.beginPage()
            let cgContext = UIGraphicsGetCurrentContext()

            // Warm accent rule — the only decoration.
            let ruleY = bounds.height * 0.62
            cgContext?.setFillColor(UIColor(red: 1.0, green: 0.478, blue: 0.102, alpha: 1.0).cgColor)
            cgContext?.fill(CGRect(x: 56, y: ruleY, width: 64, height: 3))

            func draw(_ text: String, font: UIFont, color: UIColor, y: CGFloat, centered: Bool) -> CGFloat {
                let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
                let paragraph = NSMutableParagraphStyle()
                paragraph.lineBreakMode = .byWordWrapping
                var attrs = attributes
                attrs[.paragraphStyle] = paragraph
                let width = bounds.width - 112
                let rect = CGRect(x: 56, y: y, width: width, height: .greatestFiniteMagnitude)
                let drawn = text.boundingRect(with: CGSize(width: width, height: .greatestFiniteMagnitude),
                                              options: [.usesLineFragmentOrigin, .usesFontLeading],
                                              attributes: attrs, context: nil)
                text.draw(in: centered
                          ? CGRect(x: (bounds.width - width) / 2 + rect.minX - 56 + 0, y: y, width: width, height: ceil(drawn.height))
                          : rect,
                          withAttributes: attrs)
                return ceil(drawn.height)
            }

            let ink = UIColor(red: 0.07, green: 0.07, blue: 0.09, alpha: 1)
            let muted = UIColor(red: 0.45, green: 0.45, blue: 0.48, alpha: 1)
            var y = bounds.height * 0.30
            if !title.isEmpty {
                y += draw(title,
                          font: UIFont.systemFont(ofSize: 34, weight: .bold),
                          color: ink,
                          y: y,
                          centered: false) + 14
            }
            if !subtitle.isEmpty {
                y += draw(subtitle,
                          font: UIFont.systemFont(ofSize: 15, weight: .regular),
                          color: muted,
                          y: y,
                          centered: false) + 10
            }
            if customization.includeCreationDateFooter {
                _ = draw(dateString, font: UIFont.systemFont(ofSize: 11, weight: .medium), color: muted, y: y, centered: false)
            }
            if let url = sourceURL {
                _ = draw(url.absoluteString,
                         font: UIFont.systemFont(ofSize: 9, weight: .regular),
                         color: muted,
                         y: bounds.height - 72,
                         centered: false)
            }
        }
    }

    private static func prependCoverPage(to data: Data,
                                         customization: PDFCustomization,
                                         options: ConversionOptions,
                                         sourceURL: URL?,
                                         date: Date) -> Data? {
        guard let cover = makeCoverPage(customization: customization,
                                        options: options,
                                        sourceURL: sourceURL,
                                        date: date) else { return data }
        return (try? PDFAssembly.merge([cover, data])) ?? data
    }

    // MARK: - Stamping pass

    /// Redraws every page through `stamp`, preserving original page boxes.
    private static func stamp(_ data: Data,
                              stamp: (Int, Int, CGRect, CGContext) -> Void) -> Data? {
        guard let provider = CGDataProvider(data: data as CFData),
              let document = CGPDFDocument(provider),
              document.numberOfPages > 0 else { return nil }

        let format = UIGraphicsPDFRendererFormat()
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 612, height: 792), format: format)
        let total = document.numberOfPages

        let out = renderer.pdfData { context in
            for pageIndex in 1...total {
                guard let page = document.page(at: pageIndex) else { continue }
                let box = page.getBoxRect(.mediaBox)
                context.beginPage(withBounds: box, pageInfo: [:])
                guard let cgContext = UIGraphicsGetCurrentContext() else { continue }
                cgContext.saveGState()
                cgContext.translateBy(x: 0, y: box.height)
                cgContext.scaleBy(x: 1, y: -1)
                cgContext.drawPDFPage(page)
                cgContext.restoreGState()
                stamp(pageIndex - 1, total, box, cgContext)
            }
        }
        return out
    }

    // MARK: - Drawing helpers (internal for tests)

    static func drawWatermark(_ text: String, in pageBounds: CGRect, cgContext: CGContext) {
        cgContext.saveGState()
        let attributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: watermarkFontSize, weight: .bold),
            .foregroundColor: UIColor.black.withAlphaComponent(watermarkOpacity),
        ]
        let size = (text as NSString).size(withAttributes: attributes)
        cgContext.translateBy(x: pageBounds.midX, y: pageBounds.midY)
        cgContext.rotate(by: -.pi / 7)
        (text as NSString).draw(at: CGPoint(x: -size.width / 2, y: -size.height / 2),
                                withAttributes: attributes)
        cgContext.restoreGState()
    }

    static func drawPageNumber(_ number: Int, total: Int, in pageBounds: CGRect) {
        let text = "\(number) / \(total)"
        let attributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 9, weight: .medium),
            .foregroundColor: UIColor.tertiaryLabel,
        ]
        let size = (text as NSString).size(withAttributes: attributes)
        (text as NSString).draw(at: CGPoint(x: (pageBounds.width - size.width) / 2,
                                            y: pageBounds.height - 34),
                                withAttributes: attributes)
    }

    static func pageCount(of data: Data) -> Int {
        CGPDFDocument(CGDataProvider(data: data as CFData)!)?.numberOfPages ?? 0
    }

    // MARK: - Metadata

    /// Metadata stamping with optional author; empty titles leave any
    /// existing title intact.
    static func applyingMetadata(to data: Data,
                                 title: String,
                                 author: String?,
                                 sourceURL: URL?,
                                 keepExistingTitleWhenEmpty: Bool) -> Data {
        guard let document = PDFDocument(data: data) else { return data }
        var attributes = document.documentAttributes ?? [:]
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedTitle.isEmpty || !keepExistingTitleWhenEmpty {
            if !trimmedTitle.isEmpty {
                attributes[PDFDocumentAttribute.titleAttribute] = trimmedTitle
            }
        }
        if let author, !author.isEmpty {
            attributes[PDFDocumentAttribute.authorAttribute] = author
        }
        attributes[PDFDocumentAttribute.creatorAttribute] = "PDFIT"
        if let urlString = sourceURL?.absoluteString {
            attributes[PDFDocumentAttribute.subjectAttribute] = "Source: \(urlString)"
        }
        document.documentAttributes = attributes
        return document.dataRepresentation() ?? data
    }
}
