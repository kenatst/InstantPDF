import Foundation
import UIKit
import CoreText

/// Paginated Core Text renderer — the typography engine for shared text,
/// notes and reader-mode documents.
///
/// Two passes: first lay the whole string into CTFrames (so total page count
/// is known), then draw pages with page numbers and optional source footers.
/// No product watermark is ever drawn.
final class TextPDFConverter {

    struct Style {
        var margin: CGFloat = 56
        var bottomMargin: CGFloat = 64
        var titleFont = UIFont.systemFont(ofSize: 22, weight: .bold)
        var bodyFont = UIFont.systemFont(ofSize: 12.5, weight: .regular)
        var textColor = UIColor(red: 0.11, green: 0.11, blue: 0.12, alpha: 1)
        var titleSpacing: CGFloat = 18
        var paragraphSpacing: CGFloat = 10
        var lineHeightMultiple: CGFloat = 1.42

        static let `default` = Style()
    }

    let style: Style

    init(style: Style = .default) {
        self.style = style
    }

    /// Renders plain text with an optional title into a paginated PDF.
    /// An empty body with a title still produces one page; fully empty input
    /// returns nil so the caller can skip the item.
    func convert(text: String,
                 title: String?,
                 options: ConversionOptions,
                 sourceURL: URL? = nil) -> Data? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || title != nil else { return nil }
        return convert(attributed: Self.attributedString(text: trimmed, title: title, style: style),
                       options: options,
                       sourceURL: sourceURL,
                       fallbackTitle: title)
    }

    /// Renders pre-built attributed content (rich text from RTF, etc.).
    func convert(attributed content: NSAttributedString,
                 options: ConversionOptions,
                 sourceURL: URL? = nil) -> Data? {
        guard content.length > 0 else { return nil }
        return convert(attributed: content,
                       options: options,
                       sourceURL: sourceURL,
                       fallbackTitle: nil)
    }

    // MARK: - Internals

    private func convert(attributed content: NSAttributedString,
                         options: ConversionOptions,
                         sourceURL: URL?,
                         fallbackTitle: String?) -> Data? {
        let pageSize = options.paperSize.isFixed ? options.paperSize.pointSize : PDFPaperSize.a4.pointSize
        let bounds = CGRect(origin: .zero, size: pageSize)

        let textColumn = CGRect(x: style.margin,
                                y: style.margin,
                                width: pageSize.width - style.margin * 2,
                                height: pageSize.height - style.margin - style.bottomMargin)

        let frames = Self.paginate(content, in: textColumn, pageSize: pageSize)
        guard !frames.isEmpty else { return nil }

        let showPageNumbers = frames.count > 1
        let footerLines = Self.footerLines(sourceURL: sourceURL, options: options)

        let format = UIGraphicsPDFRendererFormat()
        let renderer = UIGraphicsPDFRenderer(bounds: bounds, format: format)

        return renderer.pdfData { context in
            for (index, frame) in frames.enumerated() {
                context.beginPage()
                guard let cgContext = UIGraphicsGetCurrentContext() else { continue }

                // Core Text expects bottom-left coordinates; our frames were
                // laid out that way. Flip the UIKit context back for drawing.
                cgContext.saveGState()
                cgContext.translateBy(x: 0, y: pageSize.height)
                cgContext.scaleBy(x: 1, y: -1)
                CTFrameDraw(frame, cgContext)
                cgContext.restoreGState()

                if showPageNumbers {
                    Self.drawPageNumber(index + 1, total: frames.count,
                                        in: bounds, margin: style.margin)
                }
                if !footerLines.isEmpty {
                    Self.drawFooterLines(footerLines, in: bounds, margin: style.margin)
                }
            }
        }
    }

    // MARK: - Pagination

    /// Lays content into frames sized to the text column. Guarded against
    /// zero-progress pages (empty frame ⇒ break, never loop forever).
    static func paginate(_ content: NSAttributedString, in column: CGRect, pageSize: CGSize) -> [CTFrame] {
        let framesetter = CTFramesetterCreateWithAttributedString(content as CFAttributedString)
        var frames: [CTFrame] = []
        var location = 0
        let total = content.length

        // Path in Core Text (bottom-left) coordinates.
        let path = CGPath(rect: CGRect(x: column.minX,
                                       y: pageSize.height - column.maxY,
                                       width: column.width,
                                       height: column.height),
                          transform: nil)

        while location < total {
            let range = CFRange(location: location, length: 0)
            let frame = CTFramesetterCreateFrame(framesetter, range, path, nil)
            let visible = CTFrameGetVisibleStringRange(frame)

            if visible.length == 0 {
                if frames.isEmpty { frames.append(frame) } // single empty page for whitespace-only content
                break
            }
            frames.append(frame)
            location += visible.length
        }

        if frames.isEmpty && total == 0 {
            // Whitespace-only document still yields one (blank) page.
            let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: 0), path, nil)
            frames.append(frame)
        }
        return frames
    }

    // MARK: - Typography

    static func attributedString(text: String, title: String?, style: Style) -> NSAttributedString {
        let combined = NSMutableAttributedString()

        if let title, !title.isEmpty {
            combined.append(NSAttributedString(string: title, attributes: [
                .font: style.titleFont,
                .foregroundColor: style.textColor,
                .kern: -0.4,
            ]))
            combined.append(NSAttributedString(string: "\n\n", attributes: [
                .font: style.bodyFont,
                .foregroundColor: style.textColor,
            ]))
        }

        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = style.bodyFont.pointSize * (style.lineHeightMultiple - 1.0)
        paragraph.paragraphSpacing = style.paragraphSpacing
        paragraph.lineBreakMode = .byWordWrapping

        combined.append(NSAttributedString(string: text, attributes: [
            .font: style.bodyFont,
            .foregroundColor: style.textColor,
            .paragraphStyle: paragraph,
        ]))
        return combined
    }

    // MARK: - Footers

    static func footerLines(sourceURL: URL?, options: ConversionOptions) -> [String] {
        var lines: [String] = []
        if options.includeSourceURL, let sourceURL {
            lines.append("Source: \(sourceURL.absoluteString)")
        }
        if options.includeCreationDate {
            let formatter = DateFormatter()
            formatter.dateStyle = .long
            lines.append(formatter.string(from: Date()))
        }
        return lines
    }

    private static func drawPageNumber(_ page: Int, total: Int, in bounds: CGRect, margin: CGFloat) {
        let text = "\(page) / \(total)"
        let attributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 9, weight: .medium),
            .foregroundColor: UIColor.tertiaryLabel,
        ]
        let size = text.size(withAttributes: attributes)
        text.draw(at: CGPoint(x: (bounds.width - size.width) / 2,
                              y: bounds.height - margin + 18),
                  withAttributes: attributes)
    }

    private static func drawFooterLines(_ lines: [String], in bounds: CGRect, margin: CGFloat) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 8.5, weight: .regular),
            .foregroundColor: UIColor.tertiaryLabel,
        ]
        var y = bounds.height - margin + 34
        for line in lines.reversed() {
            line.draw(at: CGPoint(x: margin, y: y), withAttributes: attributes)
            y += 12
        }
    }
}
