import Foundation
import UIKit
import CoreText

enum TextDocumentPreset: String, CaseIterable, Identifiable {
    case minimal
    case professional
    case editorial
    case letter

    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .minimal: return String(localized: "Clean", bundle: LanguageManager.bundle)
        case .professional: return String(localized: "Professional", bundle: LanguageManager.bundle)
        case .editorial: return String(localized: "Editorial", bundle: LanguageManager.bundle)
        case .letter: return String(localized: "Letter", bundle: LanguageManager.bundle)
        }
    }
}

enum TextDocumentFontFamily: String, CaseIterable, Identifiable {
    case system
    case serif
    case rounded

    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .system: return String(localized: "Sans", bundle: LanguageManager.bundle)
        case .serif: return String(localized: "Serif", bundle: LanguageManager.bundle)
        case .rounded: return String(localized: "Rounded", bundle: LanguageManager.bundle)
        }
    }

    fileprivate var design: UIFontDescriptor.SystemDesign {
        switch self {
        case .system: return .default
        case .serif: return .serif
        case .rounded: return .rounded
        }
    }
}

enum TextDocumentWeight: String, CaseIterable, Identifiable {
    case regular
    case medium
    case bold

    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .regular: return String(localized: "Regular", bundle: LanguageManager.bundle)
        case .medium: return String(localized: "Medium", bundle: LanguageManager.bundle)
        case .bold: return String(localized: "Bold", bundle: LanguageManager.bundle)
        }
    }

    fileprivate var uiWeight: UIFont.Weight {
        switch self {
        case .regular: return .regular
        case .medium: return .medium
        case .bold: return .bold
        }
    }
}

enum TextDocumentAlignment: String, CaseIterable, Identifiable {
    case left
    case center
    case right
    case justified

    var id: String { rawValue }
    var systemImage: String {
        switch self {
        case .left: return "text.alignleft"
        case .center: return "text.aligncenter"
        case .right: return "text.alignright"
        case .justified: return "text.justify"
        }
    }
    fileprivate var nsAlignment: NSTextAlignment {
        switch self {
        case .left: return .left
        case .center: return .center
        case .right: return .right
        case .justified: return .justified
        }
    }
}

enum TextDocumentMargin: String, CaseIterable, Identifiable {
    case compact
    case normal
    case large

    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .compact: return String(localized: "Compact", bundle: LanguageManager.bundle)
        case .normal: return String(localized: "Standard", bundle: LanguageManager.bundle)
        case .large: return String(localized: "Spacious", bundle: LanguageManager.bundle)
        }
    }
    var points: CGFloat {
        switch self {
        case .compact: return 36
        case .normal: return 54
        case .large: return 72
        }
    }
}

enum TextDocumentTextSize: String, CaseIterable, Identifiable {
    case small
    case medium
    case large

    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .small: return String(localized: "Small", bundle: LanguageManager.bundle)
        case .medium: return String(localized: "Medium", bundle: LanguageManager.bundle)
        case .large: return String(localized: "Large", bundle: LanguageManager.bundle)
        }
    }
}

struct TextDocumentSignature: Equatable {
    var pngData: Data
    var pageNumber: Int = 1
    var normalizedX: CGFloat = 0.5
    var normalizedY: CGFloat = 0.78
    var scale: CGFloat = 1

    var normalizedRect: CGRect {
        let image = UIImage(data: pngData)
        let aspect = max((image?.size.width ?? 1) / max(image?.size.height ?? 1, 1), 0.2)
        let height = min(0.5, 0.10 * scale)
        let width = min(0.94, height * aspect)
        return CGRect(x: max(0, min(1 - width, normalizedX - width / 2)),
                      y: max(0, min(1 - height, normalizedY - height / 2)),
                      width: width,
                      height: height)
    }
}

/// One value drives both the live PDF preview and the final saved bytes.
/// It deliberately stays small: document typography and layout, not a word
/// processor document model.
struct TextDocumentConfiguration: Equatable {
    var title = ""
    var subtitle = ""
    var author = ""
    var body = ""
    var preset: TextDocumentPreset = .minimal
    var fontFamily: TextDocumentFontFamily = .system
    var textSize: TextDocumentTextSize = .medium
    var titleSize: CGFloat = 22
    var bodySize: CGFloat = 12
    var titleWeight: TextDocumentWeight = .medium
    var bodyWeight: TextDocumentWeight = .regular
    var alignment: TextDocumentAlignment = .left
    var lineHeightMultiple: CGFloat = 1.40
    var paragraphSpacing: CGFloat = 9
    var margin: TextDocumentMargin = .normal
    var headerText = ""
    var footerText = ""
    var includePageNumbers = false
    var includeDate = false
    var signature: TextDocumentSignature?

    var isRenderable: Bool {
        !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var customization: PDFCustomization {
        var value = PDFCustomization()
        value.documentTitle = title
        value.authorText = author
        value.includePageNumbers = includePageNumbers
        value.includeCreationDateFooter = includeDate
        return value
    }

    mutating func apply(_ preset: TextDocumentPreset) {
        self.preset = preset
        switch preset {
        case .minimal:
            textSize = .medium
            fontFamily = .system
            titleSize = 22
            bodySize = 12
            titleWeight = .medium
            bodyWeight = .regular
            margin = .normal
            lineHeightMultiple = 1.40
            paragraphSpacing = 9
            alignment = .left
        case .professional:
            textSize = .medium
            fontFamily = .system
            titleSize = 24
            bodySize = 12
            titleWeight = .bold
            bodyWeight = .regular
            margin = .normal
            lineHeightMultiple = 1.42
            paragraphSpacing = 10
            alignment = .left
        case .editorial:
            textSize = .large
            fontFamily = .serif
            titleSize = 30
            bodySize = 12.5
            titleWeight = .bold
            bodyWeight = .regular
            margin = .large
            lineHeightMultiple = 1.52
            paragraphSpacing = 14
            alignment = .justified
        case .letter:
            textSize = .medium
            fontFamily = .serif
            titleSize = 18
            bodySize = 12
            titleWeight = .medium
            bodyWeight = .regular
            margin = .large
            lineHeightMultiple = 1.48
            paragraphSpacing = 12
            alignment = .left
        }
    }

    mutating func apply(_ size: TextDocumentTextSize) {
        textSize = size
        switch size {
        case .small:
            bodySize = 10.5
            titleSize = preset == .editorial ? 26 : (preset == .letter ? 17 : 20)
        case .medium:
            bodySize = preset == .editorial ? 12.5 : 12
            titleSize = preset == .editorial ? 30 : (preset == .letter ? 18 : preset == .professional ? 24 : 22)
        case .large:
            bodySize = 14
            titleSize = preset == .editorial ? 33 : (preset == .letter ? 21 : preset == .professional ? 27 : 23)
        }
    }
}

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

    /// Document Composer renderer. The same output is displayed by the live
    /// preview and persisted by ImportFlowModel, eliminating preview drift.
    func convert(document: TextDocumentConfiguration,
                 options: ConversionOptions,
                 creationDate: Date = Date()) throws -> Data {
        guard document.isRenderable else { throw ConversionError.noUsableContent }

        let pageSize = options.paperSize.isFixed ? options.paperSize.pointSize : PDFPaperSize.a4.pointSize
        let bounds = CGRect(origin: .zero, size: pageSize)
        let margin = document.margin.points
        let headerReserve: CGFloat = document.headerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0 : 22
        let hasFooter = !document.footerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
            document.includePageNumbers || document.includeDate
        let footerReserve: CGFloat = hasFooter ? 30 : 0
        let column = CGRect(x: margin,
                            y: margin + headerReserve,
                            width: max(1, pageSize.width - margin * 2),
                            height: max(1, pageSize.height - margin * 2 - headerReserve - footerReserve))
        let attributed = Self.attributedString(document: document)
        let frames = Self.paginate(attributed, in: column, pageSize: pageSize)
        guard !frames.isEmpty else { throw ConversionError.generationFailed }

        let format = UIGraphicsPDFRendererFormat()
        let renderer = UIGraphicsPDFRenderer(bounds: bounds, format: format)
        var data = renderer.pdfData { context in
            for (index, frame) in frames.enumerated() {
                context.beginPage()
                guard let cgContext = UIGraphicsGetCurrentContext() else { continue }
                cgContext.saveGState()
                cgContext.translateBy(x: 0, y: pageSize.height)
                cgContext.scaleBy(x: 1, y: -1)
                CTFrameDraw(frame, cgContext)
                cgContext.restoreGState()
                Self.drawComposerMarginalia(document: document,
                                             page: index + 1,
                                             total: frames.count,
                                             bounds: bounds,
                                             margin: margin,
                                             date: creationDate)
            }
        }

        data = PersonalizationApplier.applyingMetadata(to: data,
                                                        title: document.customization.trimmedDocumentTitle ?? "",
                                                        author: document.customization.trimmedAuthor,
                                                        sourceURL: nil,
                                                        keepExistingTitleWhenEmpty: true)
        if let signature = document.signature {
            data = try PDFTools.placeSignature(pngData: signature.pngData,
                                               on: data,
                                               pages: [min(max(1, signature.pageNumber), frames.count)],
                                               normalizedRect: signature.normalizedRect)
        }
        return data
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

    static func attributedString(document: TextDocumentConfiguration) -> NSAttributedString {
        let output = NSMutableAttributedString()
        let ink = UIColor(red: 0.08, green: 0.085, blue: 0.10, alpha: 1)
        let secondary = UIColor(red: 0.35, green: 0.36, blue: 0.39, alpha: 1)

        func font(size: CGFloat, weight: TextDocumentWeight) -> UIFont {
            let base = UIFont.systemFont(ofSize: size, weight: weight.uiWeight)
            guard let descriptor = base.fontDescriptor.withDesign(document.fontFamily.design) else { return base }
            return UIFont(descriptor: descriptor, size: size)
        }

        func append(_ text: String,
                    font: UIFont,
                    color: UIColor,
                    alignment: NSTextAlignment,
                    paragraphSpacing: CGFloat,
                    lineHeight: CGFloat = 1) {
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = alignment
            paragraph.lineBreakMode = .byWordWrapping
            paragraph.lineHeightMultiple = lineHeight
            paragraph.paragraphSpacing = paragraphSpacing
            output.append(NSAttributedString(string: text + "\n", attributes: [
                .font: font,
                .foregroundColor: color,
                .paragraphStyle: paragraph,
            ]))
        }

        let headingAlignment: NSTextAlignment = document.alignment == .justified
            ? .left
            : document.alignment.nsAlignment

        append(document.title.trimmingCharacters(in: .whitespacesAndNewlines),
               font: font(size: document.titleSize, weight: document.titleWeight),
               color: ink,
               alignment: headingAlignment,
               paragraphSpacing: max(8, document.paragraphSpacing + 4),
               lineHeight: 1.08)
        append(document.subtitle.trimmingCharacters(in: .whitespacesAndNewlines),
               font: font(size: max(document.bodySize + 1, 12), weight: .regular),
               color: secondary,
               alignment: headingAlignment,
               paragraphSpacing: max(8, document.paragraphSpacing))
        append(document.author.trimmingCharacters(in: .whitespacesAndNewlines),
               font: font(size: max(9.5, document.bodySize - 1.5), weight: .medium),
               color: secondary,
               alignment: headingAlignment,
               paragraphSpacing: max(12, document.paragraphSpacing + 4))

        let body = document.body.trimmingCharacters(in: .whitespacesAndNewlines)
        append(body,
               font: font(size: document.bodySize, weight: document.bodyWeight),
               color: ink,
               alignment: document.alignment.nsAlignment,
               paragraphSpacing: document.paragraphSpacing,
               lineHeight: document.lineHeightMultiple)
        return output
    }

    private static func drawComposerMarginalia(document: TextDocumentConfiguration,
                                                page: Int,
                                                total: Int,
                                                bounds: CGRect,
                                                margin: CGFloat,
                                                date: Date) {
        let header = document.headerText.trimmingCharacters(in: .whitespacesAndNewlines)
        let footer = document.footerText.trimmingCharacters(in: .whitespacesAndNewlines)
        let muted = UIColor(red: 0.42, green: 0.43, blue: 0.46, alpha: 1)
        let font = UIFont.systemFont(ofSize: 8.5, weight: .medium)

        if !header.isEmpty {
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = .left
            header.draw(in: CGRect(x: margin,
                                   y: max(12, margin - 27),
                                   width: bounds.width - margin * 2,
                                   height: 14),
                        withAttributes: [.font: font,
                                         .foregroundColor: muted,
                                         .paragraphStyle: paragraph])
            UIColor(white: 0.82, alpha: 1).setFill()
            UIRectFill(CGRect(x: margin, y: margin - 8, width: bounds.width - margin * 2, height: 0.5))
        }

        let footerY = bounds.height - max(24, margin - 20)
        if !footer.isEmpty {
            footer.draw(in: CGRect(x: margin, y: footerY, width: (bounds.width - margin * 2) * 0.36, height: 14),
                        withAttributes: [.font: font, .foregroundColor: muted])
        }
        if document.includePageNumbers {
            let pageText = "\(page) / \(total)"
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = .center
            pageText.draw(in: CGRect(x: bounds.width * 0.40,
                                     y: footerY,
                                     width: bounds.width * 0.20,
                                     height: 14),
                          withAttributes: [.font: font,
                                           .foregroundColor: muted,
                                           .paragraphStyle: paragraph])
        }
        if document.includeDate {
            let value = DateFormatter.localizedString(from: date, dateStyle: .medium, timeStyle: .none)
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = .right
            value.draw(in: CGRect(x: bounds.width * 0.62,
                                  y: footerY,
                                  width: bounds.width - bounds.width * 0.62 - margin,
                                  height: 14),
                       withAttributes: [.font: font,
                                        .foregroundColor: muted,
                                        .paragraphStyle: paragraph])
        }
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
