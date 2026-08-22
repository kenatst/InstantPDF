import Foundation
import PDFKit
import CoreGraphics

/// Final-stage PDF operations: merging chunk documents, slicing tall captures
/// into printable pages, and stamping document metadata.
enum PDFAssembly {

    // MARK: - Merging

    /// Merges independently generated PDF chunks into one document.
    /// Chunks that fail to parse are skipped; if nothing survives, throws.
    static func merge(_ chunks: [Data]) throws -> Data {
        let merged = PDFDocument()
        var insertionIndex = 0

        for chunk in chunks {
            guard let document = PDFDocument(data: chunk), document.pageCount > 0 else {
                continue
            }
            // Safe against zero-page documents: iterate bounds explicitly.
            for pageIndex in 0..<document.pageCount {
                guard let page = document.page(at: pageIndex) else { continue }
                merged.insert(page, at: insertionIndex)
                insertionIndex += 1
            }
        }

        guard insertionIndex > 0 else { throw ConversionError.generationFailed }
        guard let data = merged.dataRepresentation() else { throw ConversionError.generationFailed }
        return data
    }

    /// Applies product metadata to a finished document.
    static func applyingMetadata(to data: Data,
                                 title: String,
                                 sourceURL: URL?) -> Data {
        guard let document = PDFDocument(data: data) else { return data }
        var attributes = document.documentAttributes ?? [:]
        attributes[PDFDocumentAttribute.titleAttribute] = title
        attributes[PDFDocumentAttribute.creatorAttribute] = "PDF It"
        if let urlString = sourceURL?.absoluteString {
            // Subject, not keywords — stays out of Spotlight-hungry fields.
            attributes[PDFDocumentAttribute.subjectAttribute] = "Source: \(urlString)"
        }
        document.documentAttributes = attributes
        guard let data = document.dataRepresentation() else { return data }
        return data
    }

    static func pageCount(of data: Data) -> Int {
        PDFDocument(data: data)?.pageCount ?? 0
    }

    // MARK: - Slicing

    /// Cuts a single tall PDF page into fixed-size pages. Used for web
    /// captures so we never emit absurd 20,000-point-high pages.
    ///
    /// The captured page is scaled uniformly to `pageSize.width` and cut into
    /// vertical strips of `pageSize.height`. Vector content stays vector.
    static func slicingCapture(_ capture: Data, to pageSize: CGSize) throws -> Data {
        guard let provider = CGDataProvider(data: capture as CFData),
              let captured = CGPDFDocument(provider),
              captured.numberOfPages > 0,
              let capturedPage = captured.page(at: 1) else {
            throw ConversionError.generationFailed
        }

        let capturedBox = capturedPage.getBoxRect(.mediaBox)
        guard capturedBox.width > 0, capturedBox.height > 0 else {
            throw ConversionError.generationFailed
        }

        let scale = pageSize.width / capturedBox.width
        let scaledHeight = capturedBox.height * scale
        let pageCount = max(1, Int(ceil(scaledHeight / pageSize.height)))

        let bounds = CGRect(origin: .zero, size: pageSize)
        let format = UIGraphicsPDFRendererFormat()
        let renderer = UIGraphicsPDFRenderer(bounds: bounds, format: format)

        return renderer.pdfData { context in
            for pageIndex in 0..<pageCount {
                context.beginPage()
                guard let cgContext = UIGraphicsGetCurrentContext() else { continue }

                cgContext.saveGState()
                cgContext.clip(to: bounds)
                // Work in bottom-left PDF coordinates for the page draw.
                cgContext.translateBy(x: 0, y: pageSize.height)
                cgContext.scaleBy(x: 1, y: -1)
                cgContext.translateBy(x: 0, y: -CGFloat(pageIndex) * pageSize.height)
                cgContext.scaleBy(x: scale, y: scale)
                cgContext.drawPDFPage(capturedPage)
                cgContext.restoreGState()
            }
        }
    }

    // MARK: - Appending (original pages, untouched)

    /// Copies every page of an existing PDF into a standalone PDF chunk,
    /// preserving the original page boxes. No footers, no watermarks, no
    /// coordinate fiddling — each page is drawn onto an identically sized page.
    static func passthroughChunk(from document: CGPDFDocument) -> Data? {
        let pageCount = document.numberOfPages
        guard pageCount > 0 else { return nil }

        let firstBox = document.page(at: 1)?.getBoxRect(.mediaBox) ?? CGRect(x: 0, y: 0, width: 612, height: 792)
        let format = UIGraphicsPDFRendererFormat()
        let renderer = UIGraphicsPDFRenderer(bounds: firstBox, format: format)

        return renderer.pdfData { context in
            for pageIndex in 1...pageCount {
                guard let page = document.page(at: pageIndex) else { continue }
                let box = page.getBoxRect(.mediaBox)
                context.beginPage(withBounds: box, pageInfo: [:])
                guard let cgContext = UIGraphicsGetCurrentContext() else { continue }

                cgContext.saveGState()
                cgContext.translateBy(x: 0, y: box.height)
                cgContext.scaleBy(x: 1, y: -1)
                cgContext.drawPDFPage(page)
                cgContext.restoreGState()
            }
        }
    }
}
