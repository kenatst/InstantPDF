import Foundation
import CoreGraphics
import PDFKit

/// Handles PDFs the user already has. The cardinal rule: an existing PDF is
/// never silently modified — no footers, no watermarks, no re-imposed page
/// sizes. In Quick mode with a single PDF the original bytes are returned
/// untouched (byte-perfect passthrough).
final class ExistingPDFConverter {

    enum Result {
        /// Original document data, passed through without modification.
        case passthrough(Data)
        /// Pages re-embedded into a fresh document (merge scenario).
        /// Visual content, page boxes and orientation are preserved.
        case reembedded(Data)
    }

    /// - Parameter allowPassthrough: true when this is the only item and the
    ///   mode does not alter documents, enabling byte-perfect passthrough.
    func convert(fileURL: URL, allowPassthrough: Bool) throws -> Result {
        guard let document = CGPDFDocument(fileURL as CFURL), document.numberOfPages > 0 else {
            throw ConversionError.unreadableFile(name: fileURL.lastPathComponent)
        }

        if allowPassthrough, let original = try? Data(contentsOf: fileURL) {
            return .passthrough(original)
        }
        guard let chunk = PDFAssembly.passthroughChunk(from: document) else {
            throw ConversionError.unreadableFile(name: fileURL.lastPathComponent)
        }
        return .reembedded(chunk)
    }

    /// Page count of an existing PDF, 0 when unreadable.
    static func pageCount(of fileURL: URL) -> Int {
        guard let document = CGPDFDocument(fileURL as CFURL) else { return 0 }
        return document.numberOfPages
    }
}
