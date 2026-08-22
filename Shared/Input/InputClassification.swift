import Foundation
import UniformTypeIdentifiers

/// Pure classification helpers — no I/O, fully unit-testable.
enum InputClassification {

    /// Hard ceiling per attachment. Share Extensions are memory constrained;
    /// 100 MB keeps us far away from the jetsam line.
    static let maxFileSizeBytes: Int = 100 * 1024 * 1024

    enum FileClass {
        case pdf
        case image
        case other
    }

    /// Classifies a file URL by extension and UTType conformance.
    /// Image conformance is verified through UTType so mismatched
    /// extensions (e.g. a PNG named .jpg) still land in the right lane.
    static func classify(fileURL url: URL) -> FileClass {
        let ext = url.pathExtension.lowercased()

        if ext == "pdf" { return .pdf }
        if let type = UTType(filenameExtension: ext), type.conforms(to: .pdf) { return .pdf }
        if let type = UTType(filenameExtension: ext), type.conforms(to: .image) { return .image }
        // A few extensions UTType does not resolve by name.
        if ["heic", "heif", "avif"].contains(ext) { return .image }
        return .other
    }

    /// True when the type is something we refuse outright (video/audio).
    static func isUnsupported(_ typeIdentifier: String) -> Bool {
        guard let type = UTType(typeIdentifier) else { return false }
        return type.conforms(to: .movie)
            || type.conforms(to: .video)
            || type.conforms(to: .audio)
            || type.conforms(to: .audiovisualContent)
    }

    /// The UTType identifiers we can consume, in priority order.
    /// Used when probing NSItemProvider registrations.
    static var supportedTypeIdentifiers: [String] {
        [
            UTType.fileURL.identifier,
            UTType.pdf.identifier,
            UTType.url.identifier,
            UTType.image.identifier,
            UTType.plainText.identifier,
            UTType.utf8PlainText.identifier,
            UTType.html.identifier,
            UTType.rtf.identifier,
        ]
    }
}
