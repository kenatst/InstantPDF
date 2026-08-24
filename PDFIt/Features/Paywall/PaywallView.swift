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

    @ObservedObject private var entitlements = EntitlementCenter.shared
    @State private var busyProductID: String?
    @State private var message: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    heroBlock
                    featureShowcase

                    if entitlements.isPro {
                        alreadyPro
                    } else {
                        productSection
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
                .padding(20)
            }
            .themeBackground()
            .navigationTitle("PDF It Pro")
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
        .presentationDetents([.medium, .large])
    }

    // MARK: - Hero

    private var heroBlock: some View {
        VStack(spacing: 8) {
            MascotView(type: .success, size: 96, enableFloatingAnimation: false)

            VStack(spacing: 6) {
                Text("PDF It Pro")
                    .font(.system(size: 26, weight: .heavy, design: .rounded))
                Text("Your complete private PDF toolkit.")
                    .font(.subheadline.weight(.semibold))
                Text("Scan, convert, organize and edit PDFs — privately on your device.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
    }

    // MARK: - Feature showcase (visual benefit cards)

    private var featureShowcase: some View {
        VStack(spacing: 10) {
            showcaseRow(icon: "square.and.arrow.up",
                        titleKey: "SHARE FROM ANY APP",
                        copyKey: "Turn shared content into a PDF without leaving the app.")
            showcaseRow(icon: "safari",
                        titleKey: "WEB → PDF",
                        copyKey: "Capture webpages with Quick, Clean and Reader modes.")
            showcaseRow(icon: "text.viewfinder",
                        titleKey: "SEARCHABLE SCANS",
                        copyKey: "Use on-device OCR to search and copy text.")
            showcaseRow(icon: "slider.horizontal.3",
                        titleKey: "PDF TOOLS",
                        copyKey: "Compress, sign and extract pages in a tap.")
            showcaseRow(icon: "square.stack.3d.up",
                        titleKey: "BATCH & ORGANIZE",
                        copyKey: "Scan several documents at once. Unlimited folders and merge.")
        }
    }

    private func showcaseRow(icon: String, titleKey: String, copyKey: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.Colors.orangePrimary)
                .frame(width: 34, height: 34)
                .background(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(Theme.Colors.orangePrimary.opacity(0.14))
                )
            VStack(alignment: .leading, spacing: 2) {
                Text(LocalizedStringKey(titleKey))
                    .font(.caption.weight(.bold))
                    .kerning(0.4)
                Text(LocalizedStringKey(copyKey))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(colorScheme == .dark ? Theme.Colors.darkCard : Color.white)
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
                )
        )
    }

    private var headline: String {
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
                Text(LocalizedStringKey(headline))
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
#if DEBUG
                Text("StoreKit products aren't configured yet. Use Settings → Developer → Force PDF It Pro to test Pro during development.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
#endif
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
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(colorScheme == .dark ? Theme.Colors.darkCard : Color.white)
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .strokeBorder(Theme.Colors.orangePrimary.opacity(0.3), lineWidth: 1.5)
                    )
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
                message = String(localized: "Purchase pending approval.")
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
                    ? String(localized: "Purchases restored.")
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
