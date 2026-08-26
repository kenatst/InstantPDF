import Foundation
import UIKit
import ImageIO
import UniformTypeIdentifiers

/// Turns staged image files into PDF pages — one image per page, order
/// preserved, orientation honored, never stretched.
///
/// Memory strategy (inherited from the original renderer and hardened):
/// each image is downsampled through ImageIO directly from its file, drawn,
/// and released inside its own autorelease pool before the next one loads.
final class ImagePDFConverter {

    /// Largest page dimension for Auto-sized image pages.
    static let autoPageMaxDimension: CGFloat = 1100

    func convert(imageURLs: [URL], options: ConversionOptions) throws -> Data {
        guard !imageURLs.isEmpty else { throw ConversionError.noUsableContent }

        // One renderer writes every page directly into the final PDF. The old
        // path produced one in-memory PDF per photo and then loaded every one
        // again through PDFKit to merge them, multiplying work and peak memory
        // for 10–20 camera images.
        let format = UIGraphicsPDFRendererFormat()
        let fallbackBounds = CGRect(origin: .zero, size: PDFPaperSize.a4.pointSize)
        let renderer = UIGraphicsPDFRenderer(bounds: fallbackBounds, format: format)
        var renderingError: ConversionError?
        var renderedPageCount = 0

        let data = renderer.pdfData { context in
            for url in imageURLs where renderingError == nil {
                if Task.isCancelled {
                    renderingError = .cancelled
                    break
                }

                autoreleasepool {
                    guard let image = Self.downsampledImage(
                        at: url,
                        maxPixelDimension: options.imageQuality.maxPixelDimension
                    ) else {
                        renderingError = .unreadableFile(name: url.lastPathComponent)
                        return
                    }

                    let pageSize = Self.pageSize(for: image, options: options)
                    let bounds = CGRect(origin: .zero, size: pageSize)
                    context.beginPage(withBounds: bounds, pageInfo: [:])
                    Self.draw(image, in: bounds, options: options, context: context.cgContext)
                    renderedPageCount += 1
                }
            }
        }

        if let renderingError { throw renderingError }
        guard renderedPageCount == imageURLs.count, !data.isEmpty else {
            throw ConversionError.generationFailed
        }
        return data
    }

    // MARK: - ImageIO downsampling (preserved from the prototype)

    static func downsampledImage(at url: URL, maxPixelDimension: CGFloat) -> UIImage? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions) else { return nil }
        guard CGImageSourceGetCount(source) > 0 else { return nil }

        let thumbnailOptions = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true, // honors EXIF orientation
            kCGImageSourceThumbnailMaxPixelSize: maxPixelDimension,
        ] as CFDictionary

        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions) else { return nil }
        return UIImage(cgImage: cgImage)
    }

    // MARK: - Page layout

    static func singlePagePDF(for image: UIImage, options: ConversionOptions) -> Data {
        let pageSize = Self.pageSize(for: image, options: options)
        let bounds = CGRect(origin: .zero, size: pageSize)
        let format = UIGraphicsPDFRendererFormat()

        let renderer = UIGraphicsPDFRenderer(bounds: bounds, format: format)
        return renderer.pdfData { context in
            context.beginPage()
            Self.draw(image, in: bounds, options: options, context: context.cgContext)
        }
    }

    private static func draw(_ image: UIImage,
                             in bounds: CGRect,
                             options: ConversionOptions,
                             context: CGContext) {
        let margin: CGFloat = 24
        let contentRect = bounds.insetBy(dx: margin, dy: margin)
        let drawRect = AspectLayout.rect(aspectRatio: image.size,
                                         inRect: contentRect,
                                         mode: options.imageLayout)

        if options.imageLayout == .fill {
            context.saveGState()
            context.clip(to: contentRect)
            image.draw(in: drawRect)
            context.restoreGState()
        } else {
            image.draw(in: drawRect)
        }
    }

    /// Auto pages match the image aspect ratio (capped); fixed paper sizes
    /// force their exact dimensions.
    static func pageSize(for image: UIImage, options: ConversionOptions) -> CGSize {
        if options.paperSize.isFixed {
            return options.paperSize.pointSize
        }
        let limit = CGSize(width: autoPageMaxDimension, height: autoPageMaxDimension)
        return AspectLayout.fittedSize(image.size, limitingTo: limit)
    }
}
