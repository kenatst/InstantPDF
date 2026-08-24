import SwiftUI

/// Settings entry point for Share Extension education.
///
/// A THIN wrapper around the shared `ShareExtensionTutorialView` (standalone
/// mode) — the exact same components the post-purchase activation flow shows
/// as page 1, so the two never diverge. The Favorites recommendation lives in
/// the shared view. The tutorial owns its "Done" button; this wrapper only
/// provides the navigation chrome.
struct ShareExtensionGuideView: View {
    var isPro: Bool = EntitlementCenter.shared.isPro

    var body: some View {
        ShareExtensionTutorialView(activationMode: false)
    }
}
