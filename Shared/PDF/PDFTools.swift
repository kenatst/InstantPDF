import Foundation
import PDFKit
import UIKit

/// PRO page tools: extraction, organization, compression, signature
/// placement. Every operation produces a NEW document — originals are
/// never modified (same contract as Quick passthrough).
enum PDFTools {

    // MARK: - Extract / Organize

    /// Builds a new PDF containing `pageNumbers` (1-based) in the given order.
    /// Original file untouched.
    static func extractPages(from sourceURL: URL, pageNumbers: [Int]) throws -> Data {
        guard let provider = CGDataProvider(data: try Data(contentsOf: sourceURL) as CFData),
              let document = CGPDFDocument(provider) else {
            throw ConversionError.generationFailed
        }
        let total = document.numberOfPages
        let wanted = pageNumbers.filter { $0 >= 1 && $0 <= total }
        guard !wanted.isEmpty else { throw ConversionError.generationFailed }

        var chunks: [Data] = []
        for number in wanted {
            guard let page = document.page(at: number) else { continue }
            let box = page.getBoxRect(.mediaBox)
            let format = UIGraphicsPDFRendererFormat()
            let renderer = UIGraphicsPDFRenderer(bounds: box, format: format)
            let chunk = renderer.pdfData { context in
                context.beginPage(withBounds: box, pageInfo: [:])
                guard let cgContext = UIGraphicsGetCurrentContext() else { return }
                cgContext.saveGState()
                cgContext.translateBy(x: 0, y: box.height)
                cgContext.scaleBy(x: 1, y: -1)
                cgContext.drawPDFPage(page)
                cgContext.restoreGState()
            }
            chunks.append(chunk)
        }
        return try PDFAssembly.merge(chunks)
    }

    /// Reorders/rotates/removes pages: `operations` maps each output page to
    /// a (source 1-based page, quarterTurns). Output = NEW PDF.
    static func organizePages(from sourceURL: URL,
                              operations: [(page: Int, quarterTurns: Int)]) throws -> Data {
        guard let data = try? Data(contentsOf: sourceURL),
              let provider = CGDataProvider(data: data as CFData),
              let document = CGPDFDocument(provider) else {
            throw ConversionError.generationFailed
        }
        let total = document.numberOfPages

        var chunks: [Data] = []
        for op in operations where op.page >= 1 && op.page <= total {
            guard let page = document.page(at: op.page) else { continue }
            var box = page.getBoxRect(.mediaBox)
            let turns = ((op.quarterTurns % 4) + 4) % 4
            if turns % 2 == 1 {
                box = CGRect(origin: box.origin,
                             size: CGSize(width: box.height, height: box.width))
            }
            let format = UIGraphicsPDFRendererFormat()
            let renderer = UIGraphicsPDFRenderer(bounds: box, format: format)
            let chunk = renderer.pdfData { context in
                context.beginPage(withBounds: box, pageInfo: [:])
                guard let cgContext = UIGraphicsGetCurrentContext() else { return }
                cgContext.saveGState()
                cgContext.translateBy(x: box.midX, y: box.midY)
                cgContext.rotate(by: CGFloat(turns) * .pi / 2)
                cgContext.translateBy(x: -(box.height) / 2, y: -(box.width) / 2)
                // After rotation we draw into an unrotated coordinate frame of
                // the ORIGINAL page box; translate compensates the pivot.
                cgContext.scaleBy(x: 1, y: -1)
                if turns == 1 || turns == 3 {
                    cgContext.translateBy(x: 0, y: -(box.width))
                } else {
                    cgContext.translateBy(x: 0, y: -(box.height))
                }
                cgContext.drawPDFPage(page)
                cgContext.restoreGState()
            }
            chunks.append(chunk)
        }
        return try PDFAssembly.merge(chunks)
    }

    // MARK: - Compression

    enum CompressionPreset: String, CaseIterable, Identifiable {
        case smaller
        case balanced
        case bestQuality

        var id: String { rawValue }

        var displayNameKey: String {
            switch self {
            case .smaller: return "Smaller"
            case .balanced: return "Balanced"
            case .bestQuality: return "Best Quality"
            }
        }

        /// JPEG quality for rasterized image pages.
        var jpegQuality: CGFloat {
            switch self {
            case .smaller: return 0.35
            case .balanced: return 0.6
            case .bestQuality: return 0.85
            }
        }

        /// Long-edge cap in pixels for rasterized pages.
        var maxPixelEdge: CGFloat {
            switch self {
            case .smaller: return 1000
            case .balanced: return 1600
            case .bestQuality: return 2400
            }
        }
    }

    /// Compresses by re-encoding IMAGE-HEAVY pages at reduced quality/resolution.
    ///
    /// Strategy per page:
    /// • Render the page once at capped resolution (background-safe size).
    /// • If the rasterized JPEG is SMALLER than the original page stream's
    ///   proportional share, use it; otherwise keep the original page
    ///   untouched (vector/text pages survive losslessly — never blindly
    ///   rasterized away).
    /// Returns new data + resulting byte count. Original file untouched.
    static func compress(from sourceURL: URL, preset: CompressionPreset) throws -> (data: Data, byteCount: Int) {
        guard let data = try? Data(contentsOf: sourceURL),
              let provider = CGDataProvider(data: data as CFData),
              let document = CGPDFDocument(provider), document.numberOfPages > 0 else {
            throw ConversionError.generationFailed
        }
        let total = document.numberOfPages
        let originalSize = data.count
        // Proportional budget: what one page "costs" on average.
        let averagePageSize = originalSize / total

        var chunks: [Data] = []
        for pageIndex in 1...total {
            guard let page = document.page(at: pageIndex) else { continue }
            let box = page.getBoxRect(.mediaBox)

            // Rasterize at capped long edge.
            let scale = min(1, preset.maxPixelEdge / max(box.width, box.height))
            let pixelSize = CGSize(width: box.width * scale * 2, height: box.height * scale * 2) // 2x for readability
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            let raster = UIGraphicsImageRenderer(size: pixelSize, format: format).image { _ in
                UIColor.white.setFill()
                UIBezierPath(rect: CGRect(origin: .zero, size: pixelSize)).fill()
                let cgContext = UIGraphicsGetCurrentContext()
                cgContext?.saveGState()
                cgContext?.translateBy(x: 0, y: pixelSize.height)
                cgContext?.scaleBy(x: 1, y: -1)
                cgContext?.scaleBy(x: pixelSize.width / box.width, y: pixelSize.height / box.height)
                cgContext?.drawPDFPage(page)
                cgContext?.restoreGState()
            }
            let jpeg = raster.jpegData(compressionQuality: preset.jpegQuality) ?? Data()

            // Keep raster ONLY when it actually shrinks this page meaningfully.
            if Double(jpeg.count) < Double(averagePageSize) * 0.9 {
                let pageSize = CGSize(width: box.width, height: box.height)
                let pdfFormat = UIGraphicsPDFRendererFormat()
                let renderer = UIGraphicsPDFRenderer(bounds: CGRect(origin: .zero, size: pageSize),
                                                     format: pdfFormat)
                let chunk = renderer.pdfData { context in
                    context.beginPage(withBounds: CGRect(origin: .zero, size: pageSize), pageInfo: [:])
                    if let image = UIImage(data: jpeg)?.cgImage {
                        UIGraphicsGetCurrentContext()?.draw(image, in: CGRect(origin: .zero, size: pageSize))
                    }
                }
                chunks.append(chunk)
            } else {
                // Vector/text page or already-optimal: pass through untouched.
                let pdfFormat = UIGraphicsPDFRendererFormat()
                let renderer = UIGraphicsPDFRenderer(bounds: box, format: pdfFormat)
                let chunk = renderer.pdfData { context in
                    context.beginPage(withBounds: box, pageInfo: [:])
                    guard let cgContext = UIGraphicsGetCurrentContext() else { return }
                    cgContext.saveGState()
                    cgContext.translateBy(x: 0, y: box.height)
                    cgContext.scaleBy(x: 1, y: -1)
                    cgContext.drawPDFPage(page)
                    cgContext.restoreGState()
                }
                chunks.append(chunk)
            }
        }

        let merged = try PDFAssembly.merge(chunks)
        return (merged, merged.count)
    }

    // MARK: - Signature placement

    /// Stamps a transparent signature PNG onto chosen pages (1-based) at a
    /// normalized rect (0–1 relative to page bounds). Produces a NEW PDF;
    /// the original is untouched. Signature bytes stay local.
    static func placeSignature(pngData: Data,
                               on sourceURL: URL,
                               pages: [Int],
                               normalizedRect: CGRect) throws -> Data {
        guard let signature = UIImage(data: pngData)?.cgImage else {
            throw ConversionError.generationFailed
        }
        guard let data = try? Data(contentsOf: sourceURL),
              let provider = CGDataProvider(data: data as CFData),
              let document = CGPDFDocument(provider), document.numberOfPages > 0 else {
            throw ConversionError.generationFailed
        }

        let targets = Set(pages)
        var chunks: [Data] = []
        for pageIndex in 1...document.numberOfPages {
            guard let page = document.page(at: pageIndex) else { continue }
            let box = page.getBoxRect(.mediaBox)
            let format = UIGraphicsPDFRendererFormat()
            let renderer = UIGraphicsPDFRenderer(bounds: box, format: format)
            let chunk = renderer.pdfData { context in
                context.beginPage(withBounds: box, pageInfo: [:])
                guard let cgContext = UIGraphicsGetCurrentContext() else { return }
                cgContext.saveGState()
                cgContext.translateBy(x: 0, y: box.height)
                cgContext.scaleBy(x: 1, y: -1)
                cgContext.drawPDFPage(page)
                cgContext.restoreGState()

                if targets.contains(pageIndex) {
                    let rect = CGRect(x: normalizedRect.origin.x * box.width,
                                      y: (1 - normalizedRect.origin.y - normalizedRect.height) * box.height,
                                      width: normalizedRect.width * box.width,
                                      height: normalizedRect.height * box.height)
                    cgContext.draw(signature, in: rect)
                }
            }
            chunks.append(chunk)
        }
        return try PDFAssembly.merge(chunks)
    }
}
