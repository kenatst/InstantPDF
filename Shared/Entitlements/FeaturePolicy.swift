import Foundation

/// Centralized Free/Pro feature policy. ONE authoritative definition —
/// screens never scatter ad-hoc `if isPro` logic; they ask the policy.
///
/// Free tier capabilities (scan, files/import, library, rename/delete/share,
/// language, appearance) are NOT modeled here: they are always available.
/// This enum covers exclusively the Pro-gated surface.
enum ProFeature: String, CaseIterable {
    case linkConversion
    case webConversion
    case shareExtension
    case cleanMode
    case readerMode
    case ocr
    case compression
    case signature
    case extractPages
    case organizePages
    case advancedBatch
    case unlimitedFolders
    case unlimitedMerge
    case advancedCustomization
}

/// Sensible initial Free allowances. Enforced at the call sites that create
/// folders / run merges — never scattered magic numbers.
enum FreeLimits {
    /// Maximum number of folders a Free user may create.
    static let maxFreeFolders = 3
    /// Maximum number of PDFs a Free user may merge in one operation.
    static let maxFreeMergeCount = 3
}

/// Minimal read-only view of entitlement state, so feature code and tests
/// can inject fakes without touching StoreKit.
@MainActor
protocol EntitlementReading {
    var isPro: Bool { get }
}

enum FeaturePolicy {

    /// Pro unlocks every listed feature; Free unlocks none of them.
    /// Pure and deterministic — fully unit-testable.
    static func isUnlocked(_ feature: ProFeature, isPro: Bool) -> Bool {
        isPro
    }

    /// Convenience overload taking any entitlement source.
    @MainActor
    static func isUnlocked(_ feature: ProFeature, entitlement: EntitlementReading) -> Bool {
        isUnlocked(feature, isPro: entitlement.isPro)
    }

    /// Folder creation allowance for the current entitlement state.
    static func folderLimit(isPro: Bool) -> Int? {
        isPro ? nil : FreeLimits.maxFreeFolders
    }

    /// Merge size allowance for the current entitlement state.
    static func mergeLimit(isPro: Bool) -> Int? {
        isPro ? nil : FreeLimits.maxFreeMergeCount
    }
}
