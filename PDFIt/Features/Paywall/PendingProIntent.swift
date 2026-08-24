import Foundation

/// The user's original reason for tapping a locked feature. Persisted (app
/// group defaults) while the purchase + activation flow runs, so the exact
/// action can resume after celebration/tutorial/guide complete.
///
/// FREE user taps Sign → paywall(pending: .signature) → buys → activation
/// flow → DONE → host resumes Sign. Never destroyed by the walkthrough.
///
/// The pending intent IS a ProFeature — the same enum drives gating, so the
/// resumption mapping stays total and testable.
typealias ProIntent = ProFeature

enum PendingProIntent {
    nonisolated static let key = "pro.pendingIntent"

    static func stage(_ feature: ProFeature) {
        AppConfiguration.sharedDefaults.set(feature.rawValue, forKey: key)
    }

    /// The staged intent, if any. Reading does not clear it — the activation
    /// flow's completion clears it exactly once.
    static var current: ProFeature? {
        guard let raw = AppConfiguration.sharedDefaults.string(forKey: key),
              let feature = ProFeature(rawValue: raw) else { return nil }
        return feature
    }

    static func clear() {
        AppConfiguration.sharedDefaults.removeObject(forKey: key)
    }
}

/// Activates the local Pro demo, returns the exact staged intent so the
/// presenting feature can resume immediately, and clears the transient intent
/// without recording a purchase or activation.
@MainActor
enum ProDemoMode {
    static func activate(_ feature: ProFeature,
                         entitlementCenter: EntitlementCenter) -> ProIntent {
        PendingProIntent.stage(feature)
        entitlementCenter.setDemoMode(true)
        let intent = PendingProIntent.current ?? feature
        PendingProIntent.clear()
        return intent
    }
}

/// Source compatibility for internal test targets written before Demo Mode
/// was made available in release builds.
typealias DebugProDemoMode = ProDemoMode

/// One-time activation-walkthrough bookkeeping.
///
/// `hasCompletedProActivationGuide` persists per installation so existing Pro
/// users are never interrupted again; `isEligible` gates WHO may see the
/// flow at all. Startup entitlement discovery is NOT a trigger — callers pass
/// an explicit acquisition event instead.
@MainActor
enum ProActivationState {
    nonisolated static let completedKey = "pro.hasCompletedActivationGuide"

    static var hasCompletedGuide: Bool {
        get { AppConfiguration.sharedDefaults.bool(forKey: completedKey) }
        set { AppConfiguration.sharedDefaults.set(newValue, forKey: completedKey) }
    }

    /// True when a verified purchase/restore just happened and this install
    /// has never seen the walkthrough.
    static var isEligibleForActivationFlow: Bool {
        !hasCompletedGuide
    }

    /// DEBUG ONLY: replay support for visual QA.
    static func resetWelcomeState() {
        #if DEBUG
        hasCompletedGuide = false
        #endif
    }
}
