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
    @State private var textIn = false
    @State private var finished = false

    private let generator = UINotificationFeedbackGenerator()

    var body: some View {
        ZStack {
            // Dark premium backdrop with a warm gold/amber glow.
            Theme.Colors.darkBackground.ignoresSafeArea()
            RadialGradient(colors: [Theme.Colors.orangePrimary.opacity(raysIn ? 0.35 : 0.0),
                                    .clear],
                           center: .center, startRadius: 10, endRadius: 360)
                .ignoresSafeArea()

            VStack(spacing: 22) {
                Spacer()
                ZStack {
                    // Rising sparkle and document particles around the crown mascot.
                    ForEach(0..<6, id: \.self) { i in
                        Image(systemName: ["doc.fill", "sparkle", "crown.fill"][i % 3])
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(Theme.Colors.orangeLight.opacity(documentsIn ? 0.75 : 0.0))
                            .offset(x: documentsIn ? docOffset(i).x : 0,
                                    y: documentsIn ? docOffset(i).y : 40)
                    }

                    MascotView(type: .crown, size: 160, enableFloatingAnimation: true)
                        .scaleEffect(mascotIn ? 1 : (reduceMotion ? 1 : 0.4))
                        .opacity(mascotIn ? 1 : 0)
                }

                VStack(spacing: 8) {
                    Text("PDFIT Pro unlocked")
                        .font(.system(size: 28, weight: .heavy, design: .rounded))
                        .foregroundStyle(.white)
                    Text("Everything is yours. Private, on-device power.")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.white.opacity(0.8))
                }
                .opacity(textIn ? 1 : 0)
                .offset(y: textIn || reduceMotion ? 0 : 14)

                Spacer()

                Button {
                    onContinue()
                } label: {
                    Text("Continue")
                        .font(.headline.weight(.bold))
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
            generator.notificationOccurred(.success)
            try? await Task.sleep(nanoseconds: 250_000_000)
            withAnimation(.easeOut(duration: 0.45)) { textIn = true }
        }
    }

    private func docOffset(_ i: Int) -> CGPoint {
        let angles: [CGFloat] = [-150, -110, -70, 70, 115, 155]
        let radius: CGFloat = 105
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
                        Text("Use PDFIT from any app")
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
                                       title: "Choose PDFIT",
                                       detail: "If PDFIT isn't visible, scroll to the end of the apps row and tap More.")
                    }

                    Label("Add PDFIT to your Share Sheet favorites", systemImage: "star.fill")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Theme.Colors.orangePrimary)

                    Text("PDFIT receives only the content the source app chooses to share.")
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
        .navigationTitle(activationMode ? Text("") : Text("Use PDFIT from any app"))
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
                VStack(spacing: Theme.Spacing.lg) {
                    VStack(spacing: 14) {
                        ZStack {
                            Circle()
                                .fill(Theme.Colors.orangePrimary.opacity(0.18))
                                .frame(width: 130, height: 130)
                                .blur(radius: 18)

                            MascotView(type: .crown, size: 120, enableFloatingAnimation: true)
                        }
                        .accessibilityHidden(true)

                        VStack(spacing: 6) {
                            HStack(spacing: 6) {
                                Image(systemName: "crown.fill")
                                    .font(.caption.weight(.black))
                                Text("PDFIT PRO")
                                    .font(.caption.weight(.black))
                                    .tracking(2.2)
                            }
                            .foregroundStyle(Theme.Colors.orangePrimary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 4)
                            .background(
                                Capsule()
                                    .fill(Theme.Colors.orangePrimary.opacity(0.14))
                                    .overlay(Capsule().strokeBorder(Theme.Colors.orangePrimary.opacity(0.35), lineWidth: 1))
                            )

                            Text("Your Private PDF Superpowers")
                                .font(.system(size: 24, weight: .heavy, design: .rounded))
                                .multilineTextAlignment(.center)

                            Text("Here is everything unlocked and ready on your iPhone.")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                        }
                    }
                    .padding(.top, 8)

                    VStack(alignment: .leading, spacing: 0) {
                        guideRow(symbol: "square.and.arrow.up",
                                 title: "Share Sheet & Web Conversion",
                                 copy: "Convert directly from Safari, Photos, Files or any app without opening PDFIT. Clean & Reader modes strip ads.")
                        Divider().overlay(Color.white.opacity(0.08))
                            .padding(.leading, 54)
                        guideRow(symbol: "signature",
                                 title: "Sign & Search on Device",
                                 copy: "Sign contracts & forms anywhere on page. On-device OCR extracts selectable text with zero cloud uploads.")
                        Divider().overlay(Color.white.opacity(0.08))
                            .padding(.leading, 54)
                        guideRow(symbol: "arrow.down.doc",
                                 title: "Compress & Batch Scan",
                                 copy: "Shrink heavy PDFs while keeping crisp quality. Continuous batch scanning with automatic document separation.")
                        Divider().overlay(Color.white.opacity(0.08))
                            .padding(.leading, 54)
                        guideRow(symbol: "square.stack.3d.up",
                                 title: "Extract Pages & Unlimited Organization",
                                 copy: "Reorder, rotate, delete and extract pages. Unlimited folders, advanced merge and custom formatting.")
                    }
                    .padding(.horizontal, Theme.Spacing.md)
                    .padding(.vertical, Theme.Spacing.xs)
                    .background(
                        RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                            .fill(Theme.Colors.darkCard)
                            .overlay(
                                RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                                    .strokeBorder(Theme.Colors.darkStroke, lineWidth: 1)
                            )
                    )

                    // Free vs Pro Breakdown
                    VStack(alignment: .leading, spacing: 14) {
                        HStack {
                            Text("Feature Comparison")
                                .font(.subheadline.weight(.bold))
                            Spacer()
                            Text("Free vs Pro")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(Theme.Colors.orangePrimary)
                        }

                        VStack(spacing: 8) {
                            featureCheckRow(name: "Scan & Multipage Scan", free: true, pro: true)
                            featureCheckRow(name: "Photos, Text & Files → PDF", free: true, pro: true)
                            featureCheckRow(name: "Local Library & Smart Naming", free: true, pro: true)
                            featureCheckRow(name: "Share Extension (Any App)", free: false, pro: true)
                            featureCheckRow(name: "Web / Links (Clean & Reader)", free: false, pro: true)
                            featureCheckRow(name: "PDF Signatures", free: false, pro: true)
                            featureCheckRow(name: "Searchable On-Device OCR", free: false, pro: true)
                            featureCheckRow(name: "PDF Compression", free: false, pro: true)
                            featureCheckRow(name: "Extract, Rotate & Reorder Pages", free: false, pro: true)
                            featureCheckRow(name: "Batch Scan (Multi-doc)", free: false, pro: true)
                            featureCheckRow(name: "Unlimited Folders & Merging", free: false, pro: true)
                        }
                    }
                    .padding(Theme.Spacing.md)
                    .background(
                        RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                            .fill(Theme.Colors.darkCardSecondary)
                            .overlay(
                                RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                                    .strokeBorder(Theme.Colors.darkStroke, lineWidth: 1)
                            )
                    )

                    // Privacy Assurance
                    HStack(spacing: 14) {
                        Label("100% On-Device", systemImage: "cpu")
                        Label("No Account", systemImage: "person.crop.circle.badge.xmark")
                        Label("No Cloud Uploads", systemImage: "icloud.slash")
                    }
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Color.white.opacity(0.72))
                    .padding(.vertical, 8)
                }
                .padding(20)
            }

            Button {
                finish()
            } label: {
                Text(activationMode ? LocalizedStringKey("Start using PDFIT") : LocalizedStringKey("Done"))
                    .fontWeight(.bold)
                    .frame(maxWidth: .infinity)
            }
            .primaryOrangeButton()
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(.bar)
        }
        .themeBackground()
        .navigationTitle(activationMode ? Text("") : Text("Explore Pro Features"))
        .navigationBarTitleDisplayMode(.inline)
    }

    private func guideRow(symbol: String,
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
                Text(title).font(.subheadline.weight(.bold))
                Text(copy).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, Theme.Spacing.sm + 2)
    }

    private func featureCheckRow(name: String, free: Bool, pro: Bool) -> some View {
        HStack {
            Text(LocalizedStringKey(name))
                .font(.caption.weight(pro && !free ? .semibold : .regular))
                .foregroundStyle(pro && !free ? .primary : .secondary)
            Spacer()
            HStack(spacing: 24) {
                Image(systemName: free ? "checkmark.circle.fill" : "xmark.circle")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(free ? Color.gray.opacity(0.8) : Color.gray.opacity(0.3))
                    .frame(width: 24)

                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(Theme.Colors.orangePrimary)
                    .frame(width: 24)
            }
        }
        .padding(.vertical, 2)
    }
}
