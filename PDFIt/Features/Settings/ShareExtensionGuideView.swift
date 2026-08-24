import SwiftUI

/// Settings entry point for Share Extension education.
///
/// This is a THIN wrapper around the shared
/// `ShareExtensionTutorialView` (standalone mode) — the exact same components
/// the post-purchase activation flow shows as page 1, guaranteeing the two
/// never diverge. The Favorites recommendation lives in the shared view.
struct ShareExtensionGuideView: View {
    @Environment(\.dismiss) private var dismiss
    var isPro: Bool = EntitlementCenter.shared.isPro

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ShareExtensionTutorialView(activationMode: false,
                                           onDone: { dismiss() })

                if !isPro {
                    // Truthful Free note; the paywall itself is contextual
                    // elsewhere — this screen teaches regardless of tier.
                    Text("Share Extension conversion is part of PDF It Pro.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 10)
                }
            }
        }
    }
}
