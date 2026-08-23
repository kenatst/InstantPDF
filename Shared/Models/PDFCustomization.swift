import Foundation

/// Optional pre-creation personalization ("Customize PDF"). Deliberately
/// compact — a title/author stamp, an optional cover page, page numbers,
/// footers, margins, paper, image quality, and one subtle text watermark
/// (OFF by default). No editing, annotation or canvas features.
struct PDFCustomization: Codable, Equatable {
    var documentTitle: String = ""
    var authorText: String = ""
    var includeCoverPage: Bool = false
    var coverTitle: String = ""
    var coverSubtitle: String = ""
    var includePageNumbers: Bool = false
    var includeSourceURLFooter: Bool = false
    var includeCreationDateFooter: Bool = false
    /// Extra margin in points added around content (0–48).
    var extraMargin: CGFloat = 0
    /// Watermark is OFF until the user types something.
    var watermarkText: String = ""

    var isEmpty: Bool {
        self == PDFCustomization()
    }

    var trimmedDocumentTitle: String? {
        let t = documentTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
    var trimmedAuthor: String? {
        let t = authorText.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
    var trimmedWatermark: String? {
        let t = watermarkText.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
}
