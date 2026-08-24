import SwiftUI
import StoreKit

/// Contextual paywall. Shown on explicit Pro intent and ONCE after
/// onboarding (with "Continue with Free"). Prices come from StoreKit, never
/// hardcoded; when no products are configured the state is explicit —
/// never an endless spinner.
struct PaywallView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    /// The feature that triggered the paywall — used for the headline.
    var feature: ProFeature = .webConversion
    /// Post-onboarding presentation gets an explicit "Continue with Free".
    var showsContinueFree = false
    /// Called ONLY on a verified successful purchase (never on cancel,
    /// failure or pending). The host decides what happens next — typically
    /// the Pro activation flow, then resuming the original intent.
    var onVerifiedPurchase: ((ProFeature) -> Void)? = nil
    /// Demo Mode is entitlement-only: no purchase celebration or analytics.
    /// Contextual hosts use this callback to resume the exact requested action.
    var onDemoMode: ((ProIntent) -> Void)? = nil

    @ObservedObject private var entitlements = EntitlementCenter.shared
    @State private var busyProductID: String?
    @State private var message: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: Theme.Spacing.lg) {
                    heroBlock
                    featureShowcase
                    privacyStrip

                    if entitlements.isPro {
                        alreadyPro
                    } else {
                        productSection
                        demoModeButton
                        restoreButton
                    }

                    continueFreeButton

                    if let message {
                        Text(message)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }

                    legalFootnote
                }
                .padding(.horizontal, Theme.Spacing.lg)
                .padding(.vertical, Theme.Spacing.xl)
            }
            .background(Theme.Colors.darkBackground.ignoresSafeArea())
            .navigationTitle("PDFIT Pro")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .task {
                entitlements.start()
            }
        }
        .tint(Theme.Colors.orangePrimary)
        .presentationDetents([.large])
        .preferredColorScheme(.dark)
    }

    // MARK: - Hero

    // MARK: - Hero: outcome-first promise (not a feature list)

    private var heroBlock: some View {
        VStack(spacing: 14) {
            ZStack {
                Circle().stroke(Theme.Colors.orangePrimary.opacity(0.4), lineWidth: 1)
                    .frame(width: 96, height: 96)
                MascotView(type: .hero, size: 92, enableFloatingAnimation: false)
            }
            .accessibilityHidden(true)

            VStack(spacing: 7) {
                Text("PDFIT PRO")
                    .font(.caption.weight(.black))
                    .tracking(2.2)
                    .foregroundStyle(Theme.Colors.orangePrimary)
                Text("Turn anything into a PDF from any app.")
                    .font(.system(size: 27, weight: .heavy, design: .rounded))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
            }
        }
    }

    // MARK: - Outcome blocks: sell results, map to features second

    private var featureShowcase: some View {
        VStack(alignment: .leading, spacing: 0) {
            outcomeRow(symbol: "sparkles",
                       title: "Sign documents without uploading them anywhere.",
                       copy: "Draw once — place your signature on the exact spot. Everything stays on this iPhone.")
            Divider().overlay(Color.white.opacity(0.10))
                .padding(.leading, 54)
            outcomeRow(symbol: "doc.text.magnifyingglass",
                       title: "Make scans searchable on your iPhone.",
                       copy: "On-device OCR turns pictures of paper into selectable text. No cloud round-trip.")
            Divider().overlay(Color.white.opacity(0.10))
                .padding(.leading, 54)
            outcomeRow(symbol: "arrow.down.doc",
                       title: "Compress and organize files in seconds.",
                       copy: "Smaller files that stay readable, plus page-level tools for reorder, extract and rotate.")
        }
        .padding(.horizontal, Theme.Spacing.md)
        .padding(.vertical, Theme.Spacing.xs)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
            .fill(Theme.Colors.darkCard)
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                .strokeBorder(Color.white.opacity(0.09), lineWidth: 1)))
    }

    /// Privacy proof strip — precise claims only.
    private var privacyStrip: some View {
        HStack(spacing: 14) {
            Label {
                Text("No account") 
            } icon: {
                Image(systemName: "person.crop.circle.badge.xmark")
            }
            .font(.caption2.weight(.semibold))
            .foregroundStyle(Color.white.opacity(0.72))

            Label {
                Text("No PDFIT uploads")
            } icon: {
                Image(systemName: "icloud.slash")
            }
            .font(.caption2.weight(.semibold))
            .foregroundStyle(Color.white.opacity(0.72))

            Label {
                Text("On-device OCR")
            } icon: {
                Image(systemName: "cpu")
            }
            .font(.caption2.weight(.semibold))
            .foregroundStyle(Color.white.opacity(0.72))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Theme.Spacing.sm)
    }

    private func outcomeRow(symbol: String,
                            title: LocalizedStringKey,
                            copy: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: Theme.Spacing.sm) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(Theme.Colors.orangePrimary)
                .frame(width: 36, height: 36)
                .background(
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .fill(Theme.Colors.orangePrimary.opacity(0.13))
                )
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(.white)
                Text(copy)
                    .font(.caption)
                    .foregroundStyle(Color.white.opacity(0.58))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, Theme.Spacing.sm + 2)
    }

    private var headline: LocalizedStringKey {
        switch feature {
        case .webConversion, .linkConversion:
            return "Turn any webpage or link into a clean PDF."
        case .shareExtension:
            return "Convert content directly from any app."
        case .cleanMode, .readerMode:
            return "Readable, polished webpage documents."
        case .ocr:
            return "Make scans searchable with on-device OCR."
        case .compression:
            return "Shrink heavy PDFs without losing quality."
        case .signature:
            return "Sign documents by hand, locally."
        case .extractPages, .organizePages:
            return "Reorder, rotate and extract pages."
        case .advancedBatch:
            return "Scan several documents in one pass."
        case .unlimitedFolders, .unlimitedMerge:
            return "Organize without limits."
        case .advancedCustomization:
            return "Covers, page numbers, footers and more."
        }
    }

    // MARK: - Products

    @ViewBuilder
    private var productSection: some View {
        if entitlements.products.isEmpty {
            productUnavailableState
        } else {
            VStack(spacing: 6) {
                // Feature-specific headline above pricing.
                Text(headline)
                    .font(.subheadline.weight(.semibold))
                    .multilineTextAlignment(.center)
                    .padding(.bottom, 6)

                VStack(spacing: 12) {
                    if let annual = entitlements.annualProduct {
                        productRow(annual, badge: "Best Value")
                    }
                    if let monthly = entitlements.monthlyProduct {
                        productRow(monthly, badge: nil)
                    }
                    if let lifetime = entitlements.lifetimeProduct {
                        productRow(lifetime, badge: nil)
                    }
                }
            }
        }
    }

    /// Explicit terminal state when App Store Connect has no products yet.
    /// DEBUG additionally offers the developer force-Pro toggle path hint;
    /// RELEASE shows only the localized generic message + Retry + Continue.
    private var productUnavailableState: some View {
        VStack(spacing: 12) {
            if entitlements.status == .loading {
                ProgressView()
                Text("Loading plans…")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                Image(systemName: "wifi.exclamationmark")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                Text("Purchases are temporarily unavailable.")
                    .font(.subheadline.weight(.semibold))
                    .multilineTextAlignment(.center)
                Button("Retry") {
                    entitlements.refreshProducts()
                }
                .font(.footnote.weight(.bold))
                .foregroundStyle(Theme.Colors.orangePrimary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20)
    }

    private var demoModeButton: some View {
        Button {
            let intent = ProDemoMode.activate(feature, entitlementCenter: entitlements)
            dismiss()
            onDemoMode?(intent)
        } label: {
            HStack(spacing: Theme.Spacing.xs) {
                Image(systemName: "sparkles")
                Text("Try Pro — Demo Mode")
                    .fontWeight(.bold)
            }
            .frame(maxWidth: .infinity)
        }
        .secondaryDarkButton()
        .accessibilityIdentifier("paywall_demo_mode")
    }

    private func productRow(_ product: Product, badge: String?) -> some View {
        Button {
            purchase(product)
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(product.displayName)
                            .font(.subheadline.weight(.bold))
                        if let badge {
                            Text(badge)
                                .font(.system(size: 9, weight: .black, design: .rounded))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(Theme.Colors.orangePrimary))
                        }
                    }
                    Text(product.description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                if busyProductID == product.id {
                    ProgressView()
                } else {
                    Text(product.displayPrice)
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(Theme.Colors.orangePrimary)
                }
            }
            .contentShape(Rectangle())
            .padding(Theme.Spacing.md)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                    .fill(colorScheme == .dark ? Theme.Colors.darkCard : Theme.Colors.surface)
                    .overlay(
                        RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                            .strokeBorder(Theme.Colors.orangePrimary.opacity(0.3), lineWidth: 1.5)
                    )
                    .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.18 : 0.05), radius: 10, y: 5)
            )
        }
        .buttonStyle(.plain)
        .disabled(busyProductID != nil)
    }

    private func purchase(_ product: Product) {
        busyProductID = product.id
        message = nil
        // Preserve WHY the user opened this paywall across purchase +
        // activation; cleared when the activation flow finishes.
        PendingProIntent.stage(feature)
        Task {
            let outcome = await entitlements.purchase(product)
            busyProductID = nil
            switch outcome {
            case .success:
                // VERIFIED transition only. Cancelled/pending/failed never
                // reach this path and never trigger celebration.
                dismiss()
                onVerifiedPurchase?(feature)
            case .userCancelled:
                break
            case .pending:
                message = String(localized: "Purchase pending approval.", bundle: LanguageManager.bundle)
            case .failed(let reason):
                message = reason
            }
        }
    }

    private var restoreButton: some View {
        Button("Restore Purchases") {
            Task {
                await entitlements.restore()
                message = entitlements.isPro
                    ? String(localized: "Purchases restored.", bundle: LanguageManager.bundle)
                    : nil
            }
        }
        .font(.footnote.weight(.semibold))
        .foregroundStyle(Theme.Colors.orangePrimary)
    }

    /// Post-onboarding escape hatch: Free remains a real tier. Hidden once
    /// the user is Pro (the "already Pro" block replaces it).
    @ViewBuilder
    private var continueFreeButton: some View {
        if showsContinueFree && !entitlements.isPro {
            Button("Continue with Free") { dismiss() }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.top, 2)
        }
    }

    @ViewBuilder
    private var alreadyPro: some View {
        VStack(spacing: 8) {
            Label("You're all set", systemImage: "checkmark.seal.fill")
                .font(.headline.weight(.bold))
                .foregroundStyle(Theme.Colors.orangePrimary)
            Text("Every Pro feature is unlocked on this device.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
    }

    private var legalFootnote: some View {
        VStack(spacing: 4) {
            Text("Subscriptions auto-renew until cancelled in your App Store settings. Lifetime is a one-time purchase.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
            HStack(spacing: 14) {
                Link("Terms", destination: ExternalLinks.termsOfUse)
                Link("Privacy", destination: ExternalLinks.privacyPolicy)
            }
            .font(.caption2.weight(.semibold))
        }
        .padding(.top, 6)
    }
}

extension ProFeature: Identifiable {
    public var id: String { rawValue }
}
