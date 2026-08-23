import SwiftUI

/// Dedicated education page: how to use PDF It from the iOS Share Sheet.
/// A real product screen — visible in full for Free users (with Pro CTA at
/// the bottom), replaced by a short "Ready to use" note for Pro.
struct ShareExtensionGuideView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    var isPro: Bool = EntitlementCenter.shared.isPro
    var onUnlock: (() -> Void)? = nil

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header
                step(number: 1,
                     title: "Open the content you want",
                     body: "Works from Safari, X, Photos, Notes, Files — and any app that offers Share. PDF It only receives what the app shares with it.")
                step(number: 2,
                     title: "Tap Share",
                     body: "Look for the share icon.", symbol: "square.and.arrow.up")
                step(number: 3,
                     title: "Choose PDF It",
                     body: "If PDF It isn't listed, tap More → Edit to add it to your Share Sheet.")
                step(number: 4,
                     title: "Choose conversion mode",
                     body: "Quick keeps everything. Clean and Reader produce polished documents. Available with Pro.")
                step(number: 5,
                     title: "Create the PDF",
                     body: "Your PDF is saved to the PDF It Library, ready to share or print.")

                footerCTA
            }
            .padding(20)
        }
        .themeBackground()
        .navigationTitle("Use PDF It from any app")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { dismiss() }
            }
        }
    }

    private var header: some View {
        VStack(spacing: 8) {
            MascotView(type: .hero, size: 88, enableFloatingAnimation: false)
            Text("Turn shared content into a PDF without leaving the app you're using.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
    }

    private func step(number: Int, title: String, body: String, symbol: String? = nil) -> some View {
        HStack(alignment: .top, spacing: 14) {
            ZStack {
                Circle()
                    .fill(Theme.Colors.orangePrimary.opacity(0.15))
                    .frame(width: 40, height: 40)
                if let symbol {
                    Image(systemName: symbol)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Theme.Colors.orangePrimary)
                } else {
                    Text("\(number)")
                        .font(.headline.weight(.bold))
                        .foregroundStyle(Theme.Colors.orangePrimary)
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(LocalizedStringKey(title))
                    .font(.subheadline.weight(.bold))
                Text(LocalizedStringKey(body))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(colorScheme == .dark ? Theme.Colors.darkCard : Color.white)
                .shadow(color: .black.opacity(colorScheme == .dark ? 0.2 : 0.04), radius: 6, y: 2)
        )
    }

    @ViewBuilder
    private var footerCTA: some View {
        if isPro {
            VStack(spacing: 6) {
                Label("Ready to use", systemImage: "checkmark.seal.fill")
                    .font(.headline.weight(.bold))
                    .foregroundStyle(Theme.Colors.orangePrimary)
                Text("Open any supported app, tap Share, then choose PDF It.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 8)
        } else {
            VStack(spacing: 10) {
                Button {
                    onUnlock?()
                } label: {
                    Text("Unlock Share Extension")
                        .fontWeight(.semibold)
                }
                .primaryOrangeButton()
                Text("Share Extension conversion is part of PDF It Pro.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
