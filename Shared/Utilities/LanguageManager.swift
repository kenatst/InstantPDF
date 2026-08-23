import Foundation

/// In-app language override shared by the main app and the Share Extension.
///
/// The chosen locale code lives in the App Group defaults so both processes
/// render the same language. No Bundle swizzling: localization resolves
/// through an explicit bundle lookup, and UI reads it via `L10n.tr` /
/// `String(localized:bundle:)`. `nil` = System Default (follows iOS).
enum AppLanguage: String, CaseIterable, Identifiable {
    case english = "en"
    case french = "fr"
    case spanish = "es"
    case german = "de"
    case italian = "it"

    var id: String { rawValue }

    /// Endonym shown in the picker — never translated.
    var displayName: String {
        switch self {
        case .english: return "English"
        case .french: return "Français"
        case .spanish: return "Español"
        case .german: return "Deutsch"
        case .italian: return "Italiano"
        }
    }
}

enum LanguageManager {

    static let storedLanguageKey = "settings.appLanguageOverride"

    private static var cachedBundle: Bundle?

    /// The persisted override, nil = follow the system.
    static var current: AppLanguage? {
        get {
            guard let raw = AppConfiguration.sharedDefaults.string(forKey: storedLanguageKey) else {
                return nil
            }
            return AppLanguage(rawValue: raw)
        }
        set {
            let defaults = AppConfiguration.sharedDefaults
            if let newValue {
                defaults.set(newValue.rawValue, forKey: storedLanguageKey)
            } else {
                defaults.removeObject(forKey: storedLanguageKey)
            }
            cachedBundle = nil
            NotificationCenter.default.post(name: .pdfItLanguageChanged, object: nil)
        }
    }

    /// The resolved language: explicit override or the system's first
    /// supported localization (falls back to English).
    static var resolved: AppLanguage {
        if let override = current { return override }
        let preferred = Locale.preferredLanguages
        for identifier in preferred {
            let code = String(identifier.prefix(2)).lowercased()
            if let match = AppLanguage(rawValue: code) { return match }
        }
        return .english
    }

    /// The bundle to load localized strings from. Both targets compile
    /// Shared/Resources/Localizable.xcstrings into their own bundle, so
    /// resolving inside our own bundle is enough — no cross-bundle or
    /// swizzling hacks. For the system default this resolves through the
    /// process's own bundle; for an explicit override it pins the matching
    /// .lproj directory.
    static var bundle: Bundle {
        if let cachedBundle { return cachedBundle }
        let language = resolved
        let base = ShareFlowEnvironment.isExtension ? Bundle(for: ExtensionBundleMarker.self) : Bundle.main
        let bundle: Bundle
        if let path = base.path(forResource: language.rawValue, ofType: "lproj"),
           let override = Bundle(path: path) {
            bundle = override
        } else {
            bundle = base
        }
        cachedBundle = bundle
        return bundle
    }

    static func resetCache() {
        cachedBundle = nil
    }

    /// Localized string lookup honoring the selected language.
    static func string(_ key: String) -> String {
        NSLocalizedString(key, bundle: bundle, comment: "")
    }
}

extension Notification.Name {
    static let pdfItLanguageChanged = Notification.Name("com.kenatst.pdfit.languageChanged")
}

/// Type whose only purpose is giving the extension a concrete class for
/// `Bundle(for:)` without touching UIKit.
private final class ExtensionBundleMarker {}
