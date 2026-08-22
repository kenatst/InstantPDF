import Foundation

/// Central place for every bundle-level identifier used by the app,
/// the Share Extension and the shared storage layer.
enum AppConfiguration {
    /// Main application bundle identifier.
    static let appBundleID = "com.kenatst.pdfit"

    /// Share Extension bundle identifier (must be prefixed by the app bundle id).
    static let shareExtensionBundleID = "com.kenatst.pdfit.share"

    /// App Group shared by the main app and the Share Extension.
    static let appGroupIdentifier = "group.com.kenatst.pdfit"

    /// UserDefaults suite shared across both processes.
    static var sharedDefaults: UserDefaults {
        UserDefaults(suiteName: appGroupIdentifier) ?? .standard
    }
}
