import Foundation
import CoreGraphics

/// The three product conversion modes.
enum ConversionMode: String, Codable, CaseIterable, Identifiable {
    /// Preserve the source as faithfully as possible.
    case quick
    /// Remove webpage chrome and produce a polished document.
    case clean
    /// Extract the text into an editorial reading layout.
    case reader

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .quick: return String(localized: "Quick")
        case .clean: return String(localized: "Clean")
        case .reader: return String(localized: "Reader")
        }
    }

    var description: String {
        switch self {
        case .quick: return String(localized: "Faithful to the original")
        case .clean: return String(localized: "Webpage without the clutter")
        case .reader: return String(localized: "Just the text, beautifully laid out")
        }
    }
}

/// Paper sizes exposed in the UI. `automatic` lets each converter pick the
/// most natural page (image aspect, original PDF page, full-height web page).
enum PDFPaperSize: String, Codable, CaseIterable, Identifiable {
    case automatic
    case a4
    case letter

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .automatic: return String(localized: "Auto")
        case .a4: return "A4"
        case .letter: return String(localized: "Letter")
        }
    }

    /// Precise point dimensions (72 pt = 1 inch).
    var pointSize: CGSize {
        switch self {
        case .automatic: return CGSize(width: 595.28, height: 841.89) // A4 as neutral fallback
        case .a4: return CGSize(width: 595.28, height: 841.89)        // 210 × 297 mm
        case .letter: return CGSize(width: 612.0, height: 792.0)      // 8.5 × 11 in
        }
    }

    var isFixed: Bool { self != .automatic }
}

/// How an image is placed on the page.
enum ImageLayout: String, Codable, CaseIterable {
    case fit
    case fill
}

/// Image downsampling ceiling. Higher quality costs memory and file size.
enum ImageQuality: String, Codable, CaseIterable, Identifiable {
    case standard
    case balanced
    case high

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .standard: return String(localized: "Smaller files")
        case .balanced: return String(localized: "Balanced")
        case .high: return String(localized: "Highest quality")
        }
    }

    /// Maximum pixel dimension used for ImageIO downsampling.
    var maxPixelDimension: CGFloat {
        switch self {
        case .standard: return 1400
        case .balanced: return 2400
        case .high: return 3600
        }
    }
}

/// Everything the conversion engine needs to know, in one value.
struct ConversionOptions {
    var mode: ConversionMode = .quick
    var paperSize: PDFPaperSize = .automatic
    var imageLayout: ImageLayout = .fit
    var imageQuality: ImageQuality = .balanced
    var includeSourceURL: Bool = false
    var includeCreationDate: Bool = false

    init(mode: ConversionMode = .quick,
         paperSize: PDFPaperSize = .automatic,
         imageLayout: ImageLayout = .fit,
         imageQuality: ImageQuality = .balanced,
         includeSourceURL: Bool = false,
         includeCreationDate: Bool = false) {
        self.mode = mode
        self.paperSize = paperSize
        self.imageLayout = imageLayout
        self.imageQuality = imageQuality
        self.includeSourceURL = includeSourceURL
        self.includeCreationDate = includeCreationDate
    }

    /// User defaults shared with the main app so both entry points
    /// start from the same preferences.
    static func fromSharedDefaults() -> ConversionOptions {
        let defaults = AppConfiguration.sharedDefaults
        var options = ConversionOptions()
        if let raw = defaults.string(forKey: AppSettingsKeys.defaultMode),
           let mode = ConversionMode(rawValue: raw) {
            options.mode = mode
        }
        if let raw = defaults.string(forKey: AppSettingsKeys.defaultPaperSize),
           let size = PDFPaperSize(rawValue: raw) {
            options.paperSize = size
        }
        if let raw = defaults.string(forKey: AppSettingsKeys.imageQuality),
           let quality = ImageQuality(rawValue: raw) {
            options.imageQuality = quality
        }
        options.includeSourceURL = defaults.bool(forKey: AppSettingsKeys.includeSourceURL)
        options.includeCreationDate = defaults.bool(forKey: AppSettingsKeys.includeCreationDate)
        return options
    }
}

/// Keys for the shared defaults suite. Namespaced to avoid collisions.
enum AppSettingsKeys {
    static let defaultMode = "settings.defaultMode"
    static let defaultPaperSize = "settings.defaultPaperSize"
    static let imageQuality = "settings.imageQuality"
    static let includeSourceURL = "settings.includeSourceURL"
    static let includeCreationDate = "settings.includeCreationDate"
    static let hasCompletedOnboarding = "settings.hasCompletedOnboarding"
    /// Set once the post-onboarding Pro offer has been shown (Free stays usable).
    static let hasPresentedInitialProOffer = "settings.hasPresentedInitialProOffer"
}
