import Foundation
import PDFKit

/// The result of a successful conversion.
struct ConvertedDocument: Equatable {
    let data: Data
    let pageCount: Int
    let suggestedTitle: String
    let sourceURL: URL?
    let source: ContentSource

    var displayName: String { suggestedTitle }
}

/// Real stages surfaced to the UI — only operations that actually happen
/// are ever reported. No fake progress percentages.
enum ConversionStage: Equatable {
    case analyzing
    case loadingWebPage(String?)
    case creatingPDF
    case optimizingImages
}

/// Single entry point for every conversion, shared verbatim by the Share
/// Extension and the main app. Decides which converter handles each item,
/// merges the chunks in order, and produces a named, metadata-stamped PDF.
final class ConversionCoordinator {

    var onStageChange: ((ConversionStage) -> Void)?

    private let textConverter = TextPDFConverter()
    private let imageConverter = ImagePDFConverter()
    private let existingPDFConverter = ExistingPDFConverter()

    func convert(items: [IncomingItem], options: ConversionOptions) async throws -> ConvertedDocument {
        guard !items.isEmpty else { throw ConversionError.noUsableContent }
        onStageChange?(.analyzing)
        try Task.checkCancellation()

        // Quick mode with a single existing PDF: byte-perfect passthrough.
        if items.count == 1,
           case .pdf(let url) = items[0].kind,
           options.mode == .quick {
            let result = try existingPDFConverter.convert(fileURL: url, allowPassthrough: true)
            let data: Data
            switch result {
            case .passthrough(let original): data = original
            case .reembedded(let chunk): data = chunk
            }
            let title = items[0].originalFilename?
                .replacingOccurrences(of: ".pdf", with: "", options: .caseInsensitive)
                .trimmingCharacters(in: .whitespaces)
            return ConvertedDocument(data: data,
                                     pageCount: PDFAssembly.pageCount(of: data),
                                     suggestedTitle: title?.isEmpty == false ? title! : "Document",
                                     sourceURL: nil,
                                     source: .files)
        }

        var chunks: [Data] = []
        var titleCandidate: String?
        var primarySourceURL: URL?

        // The first web item defines the document's source URL (for footers,
        // metadata subject lines). The document's source *type* is inferred
        // below from the whole collection — never just the first item.
        for item in items {
            if primarySourceURL == nil {
                switch item.kind {
                case .url(let url):
                    primarySourceURL = url
                case .html(_, let url):
                    primarySourceURL = url
                default:
                    break
                }
            }
        }

        func sinkTitle(_ title: String?) {
            if titleCandidate == nil, let title, !title.isEmpty {
                titleCandidate = title
            }
        }

        for item in items {
            try Task.checkCancellation()

            switch item.kind {
            case .image(let url):
                onStageChange?(.optimizingImages)
                let chunk = try imageConverter.convert(imageURLs: [url], options: options)
                chunks.append(chunk)

            case .text(let text):
                onStageChange?(.creatingPDF)
                if let chunk = textConverter.convert(text: text,
                                                     title: item.title,
                                                     options: options,
                                                     sourceURL: item.sourceURL) {
                    chunks.append(chunk)
                }

            case .pdf(let url):
                onStageChange?(.creatingPDF)
                let result = try existingPDFConverter.convert(fileURL: url, allowPassthrough: false)
                switch result {
                case .passthrough(let original): chunks.append(original)
                case .reembedded(let chunk): chunks.append(chunk)
                }

            case .file(let url):
                onStageChange?(.creatingPDF)
                let notice = "File attached: \(url.lastPathComponent)"
                if let chunk = textConverter.convert(text: notice,
                                                     title: url.deletingPathExtension().lastPathComponent,
                                                     options: options) {
                    chunks.append(chunk)
                }

            case .url(let url):
                chunks.append(try await convertWeb(url: url, html: nil, options: options, titleSink: sinkTitle))

            case .html(let html, let baseURL):
                chunks.append(try await convertWeb(url: baseURL, html: html, options: options, titleSink: sinkTitle))
            }
        }

        onStageChange?(.creatingPDF)
        let merged = try PDFAssembly.merge(chunks)
        let fallbackTitle = Self.fallbackTitle(for: items)
        let title = (titleCandidate ?? fallbackTitle) ?? "PDF"
        let primarySource = Self.inferredSource(for: items)

        let stamped = PDFAssembly.applyingMetadata(to: merged, title: title, sourceURL: primarySourceURL)
        return ConvertedDocument(data: stamped,
                                 pageCount: PDFAssembly.pageCount(of: stamped),
                                 suggestedTitle: title,
                                 sourceURL: primarySourceURL,
                                 source: primarySource)
    }

    // MARK: - Source inference

    /// The document's content source, inferred from the whole collection:
    /// a single item keeps its own source; a homogeneous collection shares
    /// its common source (5 photos → .photos); anything else is honestly
    /// mixed. Never mislabels a collection by its first element.
    static func inferredSource(for items: [IncomingItem]) -> ContentSource {
        guard !items.isEmpty else { return .unknown }
        if items.count == 1 { return items[0].source }
        let common = items[0].source
        if items.allSatisfy({ $0.source == common }) { return common }
        return .mixed
    }

    // MARK: - Web routing

    /// Fallback ladder for web content: Clean/Reader → Quick capture → throw.
    /// If the page is unreachable the Quick attempt surfaces the real error.
    private func convertWeb(url: URL?,
                            html: String?,
                            options: ConversionOptions,
                            titleSink: @escaping (String?) -> Void) async throws -> Data {
        onStageChange?(.loadingWebPage(url?.host))
        let webConverter = await WebPDFConverter()

        if options.mode == .clean || options.mode == .reader, let url {
            if let rendered = try? await webConverter.renderArticle(url: url,
                                                                    mode: options.mode,
                                                                    options: options) {
                titleSink(rendered.article.title)
                return rendered.data
            }
            // Extraction failed or lacked confidence — fall through to Quick.
            try Task.checkCancellation()
        }

        do {
            let capture: WebPDFConverter.Capture
            if let html {
                capture = try await webConverter.captureHTML(html, baseURL: url, options: options)
            } else if let url {
                capture = try await webConverter.captureWebPage(url: url, options: options)
            } else {
                throw ConversionError.invalidURL
            }
            titleSink(capture.title)
            return capture.data
        } catch let error as ConversionError {
            throw error
        } catch {
            throw ConversionError.generationFailed
        }
    }

    // MARK: - Titles

    /// Names for collections the web title can't describe.
    static func fallbackTitle(for items: [IncomingItem], date: Date = Date()) -> String? {
        let imageCount = items.filter(\.isImage).count
        let textCount = items.filter {
            if case .text = $0.kind { return true }
            return false
        }.count
        let pdfCount = items.filter {
            if case .pdf = $0.kind { return true }
            return false
        }.count

        let formatter = DateFormatter()
        formatter.dateFormat = "d MMM yyyy"
        let dateSuffix = formatter.string(from: date)

        // X status links get their canonical "Thread — username" name.
        if items.count == 1, case .url(let url) = items[0].kind,
           let threadTitle = FilenameGenerator.threadTitle(for: url) {
            return threadTitle
        }

        if items.count == imageCount, imageCount > 0 {
            return imageCount == 1 ? "Photo" : "\(imageCount) Photos"
        }
        if items.count == textCount, textCount > 0 {
            // A single shared note deserves its first meaningful line as a
            // title, not a generic label. Multi-item collections stay dated.
            if textCount == 1, case .text(let text) = items[0].kind {
                return Self.firstLineTitle(from: text) ?? "Note"
            }
            if let named = items.compactMap(\.title).first(where: { !$0.isEmpty }) {
                return named
            }
            return "\(textCount) Notes"
        }
        if items.count == 1, pdfCount == 1 {
            return items[0].originalFilename?
                .replacingOccurrences(of: ".pdf", with: "", options: .caseInsensitive)
        }
        return "\(items.count) Items — \(dateSuffix)"
    }

    /// First meaningful line of shared text, collapsed and capped — nil when
    /// there is nothing worth showing (whitespace, punctuation-only).
    static func firstLineTitle(from text: String) -> String? {
        let firstLine = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: .newlines)
            .first { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? ""
        let words = firstLine.split(separator: " ").prefix(8).joined(separator: " ")
        let candidate = String(words).trimmingCharacters(in: .whitespaces)
        guard candidate.rangeOfCharacter(from: .alphanumerics) != nil else { return nil }
        return candidate.count > 60 ? String(candidate.prefix(60)) : candidate
    }
}
