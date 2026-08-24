import SwiftUI
import StoreKit
import UIKit

/// The post-purchase experience. Conceptually separate from the paywall:
/// the paywall sells Pro; this flow teaches what was just bought.
///
/// Sequence: CELEBRATION → PAGE 1 (Share Extension tutorial) →
/// PAGE 2 (Everything you unlocked) → DONE.
///
/// Trigger rules (enforced by callers, see `ProActivationFlow.shouldCelebrate`):
/// only a VERIFIED successful purchase or an appropriate restore starts it —
/// never failed/pending/cancelled purchases, never `isPro == true` at launch,
/// never the DEBUG force-Pro toggle.
struct ProActivationFlow: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Called with the user's original intent (e.g. .signature) so the host
    /// can resume exactly the action that led to the purchase.
    var onFinish: ((ProIntent?) -> Void)? = nil

    enum Page { case celebration, shareTutorial, features }
    @State private var page: Page = .celebration

    var body: some View {
        NavigationStack {
            Group {
                switch page {
                case .celebration:
                    ProCelebrationView {
                        page = .shareTutorial
                    }
                case .shareTutorial:
                    ShareExtensionTutorialView(activationMode: true) {
                        page = .features
                    } onSkip: {
                        finish()
                    }
                case .features:
                    ProFeaturesGuideView(activationMode: true) {
                        finish()
                    }
                }
            }
            .toolbar(page == .celebration ? .hidden : .visible, for: .navigationBar)
            .toolbar {
                if page != .celebration {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Skip") { finish() }
                            .font(.footnote.weight(.semibold))
                    }
                }
            }
        }
        .interactiveDismissDisabled(true)
    }

    private func finish() {
        ProActivationState.hasCompletedGuide = true
        onFinish?(PendingProIntent.current)
        PendingProIntent.clear()
        dismiss()
    }
}

// MARK: - Celebration (~2s, native, Reduce Motion aware)

struct ProCelebrationView: View {
    var onContinue: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var mascotIn = false
    @State private var documentsIn = false
    @State private var raysIn = false
    @State private var badgeIn = false
    @State private var textIn = false
    @State private var finished = false

    private let generator = UINotificationFeedbackGenerator()

    var body: some View {
        ZStack {
            // Dark premium backdrop with a restrained warm glow.
            Theme.Colors.darkBackground.ignoresSafeArea()
            RadialGradient(colors: [Theme.Colors.orangePrimary.opacity(raysIn ? 0.28 : 0.0),
                                    .clear],
                           center: .center, startRadius: 10, endRadius: 320)
                .ignoresSafeArea()

            VStack(spacing: 22) {
                Spacer()
                ZStack {
                    // Rising document symbols around the mascot.
                    ForEach(0..<6, id: \.self) { i in
                        Image(systemName: ["doc.fill", "doc.text.fill", "photo.fill"][i % 3])
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(.white.opacity(documentsIn ? 0.5 : 0.0))
                            .offset(x: documentsIn ? docOffset(i).x : 0,
                                    y: documentsIn ? docOffset(i).y : 40)
                    }

                    MascotView(type: .hero, size: 146, enableFloatingAnimation: false)
                        .scaleEffect(mascotIn ? 1 : (reduceMotion ? 1 : 0.4))
                        .opacity(mascotIn ? 1 : 0)

                    // PRO badge, crown-like placement.
                    Image(systemName: "crown.fill")
                        .font(.system(size: 17, weight: .bold))
                        .foregroundStyle(Theme.Colors.orangePrimary)
                        .padding(11)
                        .background(Circle().fill(Color.white))
                        .overlay(Circle().strokeBorder(Theme.Colors.orangePrimary.opacity(0.35), lineWidth: 1.5))
                        .shadow(color: Theme.Colors.orangePrimary.opacity(0.45), radius: 12)
                        .offset(x: 52, y: -54)
                        .scaleEffect(badgeIn ? 1 : (reduceMotion ? 1 : 0.01))
                        .opacity(badgeIn ? 1 : 0)
                }

                VStack(spacing: 8) {
                    Text("PDF It Pro unlocked")
                        .font(.system(size: 27, weight: .heavy, design: .rounded))
                        .foregroundStyle(.white)
                    Text("Everything is yours.")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.white.opacity(0.75))
                }
                .opacity(textIn ? 1 : 0)
                .offset(y: textIn || reduceMotion ? 0 : 14)

                Spacer()

                Button {
                    onContinue()
                } label: {
                    Text("Continue")
                        .font(.headline)
                        .foregroundStyle(Color(hex: "7A2E00"))
                        .frame(maxWidth: .infinity)
                        .frame(height: 56)
                        .background(Color.white, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                }
                .padding(.horizontal, 24)
                .opacity(textIn ? 1 : 0)
                .disabled(!textIn)
            }
            .padding(.vertical, 28)
        }
        .task {
            guard !reduceMotion else {
                // Reduce Motion: simple staged fades, no springs/particles.
                mascotIn = true
                try? await Task.sleep(nanoseconds: 250_000_000)
                textIn = true
                generator.notificationOccurred(.success)
                return
            }
            withAnimation(.spring(response: 0.45, dampingFraction: 0.7)) { mascotIn = true }
            try? await Task.sleep(nanoseconds: 200_000_000)
            withAnimation(.easeOut(duration: 0.5)) { documentsIn = true }
            try? await Task.sleep(nanoseconds: 200_000_000)
            withAnimation(.easeOut(duration: 0.6)) { raysIn = true }
            try? await Task.sleep(nanoseconds: 250_000_000)
            withAnimation(.spring(response: 0.4, dampingFraction: 0.65)) { badgeIn = true }
            generator.notificationOccurred(.success)
            try? await Task.sleep(nanoseconds: 200_000_000)
            withAnimation(.easeOut(duration: 0.45)) { textIn = true }
        }
    }

    private func docOffset(_ i: Int) -> CGPoint {
        let angles: [CGFloat] = [-150, -110, -70, 70, 115, 155]
        let radius: CGFloat = 96
        let rad = angles[i] * .pi / 180
        return CGPoint(x: cos(rad) * radius, y: sin(rad) * radius * 0.72)
    }
}

// MARK: - Page 1 · Share Extension tutorial (shared with Settings)

/// One source of truth for Share Extension education. In activation mode it
/// shows "Next" and chains into the feature guide; standalone (Settings) it
/// shows "Done". Both variants carry the Favorites recommendation.
struct ShareExtensionTutorialView: View {
    /// Activation mode: primary CTA is "Next"; standalone shows "Done" and
    /// owns its dismiss so the button always works in every host context.
    var activationMode = false
    var onNext: () -> Void = {}
    var onSkip: () -> Void = {}
    var onDone: () -> Void = {}
    @Environment(\.dismiss) private var dismiss

    private func handleDone() {
        if activationMode {
            onNext()
        } else {
            onDone()
            dismiss()
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    VStack(alignment: .leading, spacing: 10) {
                        Image(systemName: "square.and.arrow.up")
                            .font(.system(size: 28, weight: .semibold))
                            .foregroundStyle(Theme.Colors.orangePrimary)
                        Text("Use PDF It from any app")
                            .font(.largeTitle.weight(.bold))
                        Text("How to turn shared content into PDFs from Safari, X, Photos and more.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }

                    VStack(spacing: 0) {
                        instructionRow(symbol: "doc.text.magnifyingglass",
                                       title: "Open content",
                                       detail: "Safari, X, Photos, Notes, Files — anything that offers Share.")
                        Divider().padding(.leading, 44)
                        instructionRow(symbol: "square.and.arrow.up",
                                       title: "Tap Share",
                                       detail: "Use the system Share button.")
                        Divider().padding(.leading, 44)
                        instructionRow(symbol: "doc.text.fill",
                                       title: "Choose PDF It",
                                       detail: "If PDF It isn't visible, scroll to the end of the apps row and tap More.")
                    }

                    Label("Add PDF It to your Share Sheet favorites", systemImage: "star.fill")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Theme.Colors.orangePrimary)

                    Text("PDF It receives only the content the source app chooses to share.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(24)
            }

            VStack(spacing: 6) {
                Button(action: handleDone) {
                    Text(activationMode ? LocalizedStringKey("Next") : LocalizedStringKey("Done"))
                        .fontWeight(.bold)
                        .frame(maxWidth: .infinity)
                }
                .primaryOrangeButton()
                if activationMode {
                    Button("Skip", action: onSkip)
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(minHeight: 40)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(.bar)
        }
        .themeBackground()
        .navigationTitle(Text(activationMode ? LocalizedStringKey("") : LocalizedStringKey("Use PDF It from any app")))
        .navigationBarTitleDisplayMode(.inline)
    }

    private func instructionRow(symbol: String,
                                title: LocalizedStringKey,
                                detail: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Theme.Colors.orangePrimary)
                .frame(width: 30)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.body.weight(.semibold))
                Text(detail).font(.footnote).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 14)
    }

}

// MARK: - Page 2 · Everything you unlocked (shared with Settings)

/// Shown post-purchase and revisitable from Settings. Lists ONLY features
/// actually implemented in this codebase — no vaporware rows.
/// Standalone (Settings) mode owns its dismiss so "Done"/"Terminer" always
/// closes the screen — the CTA is wired to a real action in every context.
struct ProFeaturesGuideView: View {
    var activationMode = false
    var onFinish: () -> Void = {}

    @Environment(\.dismiss) private var dismiss

    private func finish() {
        if activationMode {
            onFinish()
        } else {
            dismiss()
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    VStack(alignment: .leading, spacing: 8) {
                        Image(systemName: "crown.fill")
                            .font(.system(size: 26, weight: .semibold))
                            .foregroundStyle(Theme.Colors.orangePrimary)
                        Text("PDFIT Pro")
                            .font(.largeTitle.weight(.bold))
                        Text("Your complete private PDF toolkit.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }

                    VStack(spacing: 0) {
                        guideRow(symbol: "square.and.arrow.up", title: "Share from any app", copy: "Create PDFs from the Share Sheet.")
                        Divider().padding(.leading, 44)
                        guideRow(symbol: "signature", title: "Complete PDF tools", copy: "Compress, sign and extract pages.")
                        Divider().padding(.leading, 44)
                        guideRow(symbol: "square.stack.3d.up", title: "Batch and organize", copy: "Scan, merge and use unlimited folders.")
                        Divider().padding(.leading, 44)
                        guideRow(symbol: "lock.shield.fill", title: "Local Processing Only", copy: "On-device processing. No account. Nothing uploaded to PDF It.")
                    }
                }
                .padding(24)
            }

            Button {
                finish()
            } label: {
                Text(activationMode ? LocalizedStringKey("Start using PDF It") : LocalizedStringKey("Done"))
                    .fontWeight(.bold)
                    .frame(maxWidth: .infinity)
            }
            .primaryOrangeButton()
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(.bar)
        }
        .themeBackground()
        .navigationTitle(Text(activationMode ? LocalizedStringKey("") : LocalizedStringKey("Explore Pro Features")))
        .navigationBarTitleDisplayMode(.inline)
    }

    private func guideRow(symbol: String,
                          title: LocalizedStringKey,
                          copy: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Theme.Colors.orangePrimary)
                .frame(width: 30)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.body.weight(.semibold))
                Text(copy).font(.footnote).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 14)
    }
}
