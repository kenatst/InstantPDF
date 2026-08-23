import Foundation
import Vision
import PDFKit
import UIKit

/// Local OCR pipeline — Apple Vision only, entirely on device. No network,
/// no external recognition API, ever.
///
/// Two outputs:
/// 1. Searchable PDF: the scan stays pixel-identical; an invisible but
///    selectable text layer is positioned over the recognized words so
///    search/select/copy work in any PDF reader.
/// 2. Extracted text: plain string for copy/share/text-PDF flows.
enum OCRRouter {

    // MARK: - Recognition

    struct RecognizedWord {
        let text: String
        /// Normalized bounding box (0–1, top-left origin).
        let box: CGRect
        let confidence: Float
    }

    struct PageRecognition {
        let words: [RecognizedWord]
        var fullText: String { words.map(\.text).joined(separator: " ") }
        var meanConfidence: Float {
            guard !words.isEmpty else { return 0 }
            return words.map(\.confidence).reduce(0, +) / Float(words.count)
        }
    }

    /// Recognizes text on one page image. Runs VNRecognizeTextRequest with
    /// accurate level; language correction off (documents, not chat).
    static func recognize(imageData: Data) async throws -> PageRecognition {
        try Task.checkCancellation()
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                autoreleasepool {
                    guard let image = UIImage(data: imageData)?.cgImage else {
                        continuation.resume(returning: PageRecognition(words: []))
                        return
                    }
                    let request = VNRecognizeTextRequest { request, error in
                        if error != nil {
                            continuation.resume(returning: PageRecognition(words: []))
                            return
                        }
                        guard let observations = request.results as? [VNRecognizedTextObservation] else {
                            continuation.resume(returning: PageRecognition(words: []))
                            return
                        }
                        var words: [RecognizedWord] = []
                        for observation in observations {
                            guard let candidate = observation.topCandidates(1).first else { continue }
                            // Vision boxes are bottom-left origin; convert to top-left.
                            let b = observation.boundingBox
                            let box = CGRect(x: b.origin.x,
                                             y: 1 - b.origin.y - b.height,
                                             width: b.width,
                                             height: b.height)
                            words.append(RecognizedWord(text: candidate.string,
                                                        box: box,
                                                        confidence: candidate.confidence))
                        }
                        continuation.resume(returning: PageRecognition(words: words))
                    }
                    request.recognitionLevel = .accurate
                    request.usesLanguageCorrection = false
                    request.recognitionLanguages = ["en-US", "fr-FR", "es-ES", "de-DE", "it-IT"]

                    let handler = VNImageRequestHandler(cgImage: image, options: [:])
                    do {
                        try handler.perform([request])
                    } catch {
                        continuation.resume(returning: PageRecognition(words: []))
                    }
                }
            }
        }
    }

    // MARK: - Searchable PDF

    /// Minimum mean confidence below which we keep the scan un-searchable
    /// rather than embedding garbage text.
    static let minimumUsefulConfidence: Float = 0.35

    /// Produces a searchable PDF: each page keeps its original pixels plus a
    /// transparent, correctly-positioned text layer (mode `.invisible` —
    /// selectable and searchable everywhere, never visible).
    /// Low-confidence pages stay visual-only by design.
    static func makeSearchablePDF(from sourceURL: URL) async throws -> Data {
        guard let document = PDFDocument(url: sourceURL), document.pageCount > 0 else {
            throw ConversionError.generationFailed
        }

        var outputChunks: [Data] = []
        for pageIndex in 0..<document.pageCount {
            try Task.checkCancellation()
            guard let page = document.page(at: pageIndex),
                  let rendered = renderPage(page) else { continue }

            let recognition = try await recognize(imageData: rendered)
            let bounds = page.bounds(for: .mediaBox)

            let format = UIGraphicsPDFRendererFormat()
            let renderer = UIGraphicsPDFRenderer(bounds: bounds, format: format)
            let chunk = renderer.pdfData { context in
                context.beginPage(withBounds: bounds, pageInfo: [:])
                guard let cgContext = UIGraphicsGetCurrentContext() else { return }

                // Original pixels first (CGPDFPage from the PDFKit page ref).
                guard let cgPage: CGPDFPage = page.pageRef else { return }
                cgContext.saveGState()
                cgContext.translateBy(x: 0, y: bounds.height)
                cgContext.scaleBy(x: 1, y: -1)
                cgContext.drawPDFPage(cgPage)
                cgContext.restoreGState()

                // Invisible text layer at word positions.
                if recognition.meanConfidence >= minimumUsefulConfidence {
                    for word in recognition.words where word.confidence >= 0.3 {
                        drawInvisibleText(word.text,
                                          in: CGRect(x: word.box.minX * bounds.width,
                                                     y: word.box.minY * bounds.height,
                                                     width: word.box.width * bounds.width,
                                                     height: word.box.height * bounds.height),
                                          pageBounds: bounds)
                    }
                }
            }
            outputChunks.append(chunk)
        }
        return try PDFAssembly.merge(outputChunks)
    }

    /// Renders a PDFKit page to JPEG bytes for the recognizer.
    private static func renderPage(_ page: PDFPage) -> Data? {
        let bounds = page.bounds(for: .mediaBox)
        let scale: CGFloat = 2
        let size = CGSize(width: bounds.width * scale, height: bounds.height * scale)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            UIColor.white.setFill()
            UIBezierPath(rect: CGRect(origin: .zero, size: size)).fill()
            let thumbnail = page.thumbnail(of: size, for: .mediaBox)
            thumbnail.draw(in: CGRect(origin: .zero, size: size))
        }
        return image.jpegData(compressionQuality: 0.85)
    }

    /// Invisible-but-selectable text: font color fully transparent.
    /// Core Graphics honors this for search/selection layers.
    private static func drawInvisibleText(_ text: String, in rect: CGRect, pageBounds: CGRect) {
        guard !text.isEmpty, rect.height > 2 else { return }
        let fontSize = min(max(rect.height * 0.82, 4), 72)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: fontSize),
            .foregroundColor: UIColor.clear,
        ]
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byClipping
        var attrs = attributes
        attrs[.paragraphStyle] = paragraph
        (text as NSString).draw(in: rect, withAttributes: attrs)
    }

    // MARK: - Smart local naming (deterministic, no LLM)

    /// Suggests a filename from OCR text / existing title / source host.
    /// Suggestions ONLY — callers must show it editable before saving.
    /// Low confidence falls back to `Scan — <date>` / `Document — <date>`.
    static func suggestedName(ocrText: String?,
                              fallbackTitle: String?,
                              sourceHost: String? = nil,
                              date: Date = Date(),
                              locale: Locale = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.dateStyle = .medium
        let dateSuffix = formatter.string(from: date)

        if let ocrText, !ocrText.isEmpty {
            if let candidate = meaningfulName(from: ocrText) {
                return FilenameGenerator.sanitize("\(candidate) — \(dateSuffix)")
            }
        }
        if let fallbackTitle {
            let trimmed = fallbackTitle.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.count >= 3,
               !trimmed.lowercased().hasPrefix("scan"),
               !trimmed.lowercased().hasPrefix("document"),
               !trimmed.lowercased().hasPrefix("pdf") {
                return FilenameGenerator.sanitize(trimmed)
            }
        }
        if let sourceHost, !sourceHost.isEmpty {
            return FilenameGenerator.sanitize("\(sourceHost) — \(dateSuffix)")
        }
        return FilenameGenerator.sanitize("Scan — \(dateSuffix)")
    }

    /// Pulls a meaningful 2–5 word name from OCR prose: prefers a line that
    /// contains a known document keyword (facture, invoice, letter…), else
    /// the first line with enough letters. Deterministic heuristics only.
    static func meaningfulName(from text: String) -> String? {
        let keywords = ["facture", "invoice", "receipt", "reçu", "recu",
                        "contrat", "contract", "letter", "lettre", "brief",
                        "rapport", "report", "attestation", "bulletin"]
        let lines = text
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.rangeOfCharacter(from: .letters) != nil && $0.count >= 4 }

        guard !lines.isEmpty else { return nil }

        // 1) Keyword line within the first 8 lines.
        for line in lines.prefix(8) {
            let lower = line.lowercased()
            if keywords.contains(where: { lower.contains($0) }) {
                return cappedWords(line, maxWords: 5)
            }
        }
        // 2) First substantive line.
        return cappedWords(lines[0], maxWords: 4)
    }

    private static func cappedWords(_ line: String, maxWords: Int) -> String {
        let words = line.split(separator: " ").prefix(maxWords).joined(separator: " ")
        let cleaned = String(words).trimmingCharacters(in: .whitespaces)
        guard cleaned.rangeOfCharacter(from: .alphanumerics) != nil else { return "" }
        return cleaned.count > 48 ? String(cleaned.prefix(48)) : cleaned
    }
}
