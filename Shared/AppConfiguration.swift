import Foundation
import os

/// Central place for every bundle-level identifier used by the app,
/// the Share Extension and the shared storage layer.
enum AppConfiguration {
    /// Main application bundle identifier.
    static let appBundleID = "com.kenatst.pdfit"

    /// Share Extension bundle identifier (must be prefixed by the app bundle id).
    static let shareExtensionBundleID = "com.kenatst.pdfit.share"

    /// App Group shared by the main app and the Share Extension.
    static let appGroupIdentifier = "group.com.kenatst.pdfit"

    private static let log = Logger(subsystem: appBundleID, category: "configuration")

    /// True only when BOTH the shared defaults suite and the App Group
    /// container are actually reachable. Data storage checks this and
    /// surfaces a real error instead of quietly writing somewhere the other
    /// process can never read.
    static var isAppGroupAvailable: Bool {
        guard UserDefaults(suiteName: appGroupIdentifier) != nil else { return false }
        return FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier) != nil
    }

    /// UserDefaults suite shared across both processes.
    ///
    /// Settings degrade gracefully to local defaults if the group is missing
    /// (the app still works, preferences just don't sync with the extension)
    /// — but never silently in a DEBUG build, where the misconfiguration is
    /// surfaced loudly so it cannot ship unnoticed.
    static var sharedDefaults: UserDefaults {
        guard let suite = UserDefaults(suiteName: appGroupIdentifier) else {
            assertionFailure("PDF It: App Group '\(appGroupIdentifier)' is unavailable. Falling back to local defaults — settings will NOT be shared with the extension.")
            log.fault("App Group \(self.appGroupIdentifier, privacy: .public) unavailable; using local defaults.")
            return .standard
        }
        return suite
    }

    /// The real App Group container URL, or nil when the entitlement/group
    /// is misconfigured. Callers that store USER DATA must treat nil as a
    /// hard error (`StorageError.containerUnavailable`) rather than falling
    /// back to a private directory that would silently break sharing.
    static var appGroupContainerURL: URL? {
        let url = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier)
        if url == nil {
            assertionFailure("PDF It: App Group container '\(appGroupIdentifier)' is unavailable. Library data cannot be shared between the app and the extension.")
            log.fault("App Group container unavailable; Library persistence disabled.")
        }
        return url
    }
}

/// Centralized external URLs used for support and legal UI.
enum ExternalLinks {
    /// Public Privacy Policy URL.
    static let privacyPolicyURLString = "https://kenatst.github.io/InstantPDF/privacy"

    /// Public Terms of Use URL.
    static let termsOfUseURLString = "https://kenatst.github.io/InstantPDF/terms"

    /// Public Support & feedback URL.
    static let supportURLString = "https://github.com/kenatst/InstantPDF/issues"

    /// Validated Privacy Policy URL.
    static var privacyPolicy: URL {
        guard let url = URL(string: privacyPolicyURLString), url.scheme == "https", url.host != nil else {
            fatalError("PDF It: Invalid Privacy Policy URL configuration: '\(privacyPolicyURLString)'")
        }
        return url
    }

    /// Validated Terms of Use URL.
    static var termsOfUse: URL {
        guard let url = URL(string: termsOfUseURLString), url.scheme == "https", url.host != nil else {
            fatalError("PDF It: Invalid Terms of Use URL configuration: '\(termsOfUseURLString)'")
        }
        return url
    }

    /// Validated Support URL.
    static var support: URL {
        guard let url = URL(string: supportURLString), url.scheme == "https", url.host != nil else {
            fatalError("PDF It: Invalid Support URL configuration: '\(supportURLString)'")
        }
        return url
    }
}
