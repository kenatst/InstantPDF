import SwiftUI
import StoreKit

/// Contextual paywall. Shown ONLY on user intent (tapping a Pro feature) —
/// never at launch. Prices come from StoreKit, never hardcoded.
struct PaywallView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    /// The feature that triggered the paywall — used for the headline.
    var feature: ProFeature = .webConversion

    @ObservedObject private var entitlements = EntitlementCenter.shared
    @State private var busyProductID: String?
    @State private var message: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    MascotView(type: .success, size: 96, enableFloatingAnimation: false)

                    VStack(spacing: 6) {
                        Text("PDF It Pro")
                            .font(.system(size: 26, weight: .heavy, design: .rounded))
                        Text(LocalizedStringKey(headline))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }

                    if entitlements.isPro {
                        alreadyPro
                    } else {
                        productCards
                        restoreButton
                    }

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
    private var productCards: some View {
        if entitlements.products.isEmpty {
            VStack(spacing: 10) {
                ProgressView()
                Text("Loading plans…")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 24)
        } else {
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
        Task {
            let outcome = await entitlements.purchase(product)
            busyProductID = nil
            switch outcome {
            case .success:
                dismiss()
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
