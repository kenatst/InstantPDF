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
        onFinish?(PendingProIntent.current)
        PendingProIntent.clear()
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

                    MascotView(type: .success, size: 132, enableFloatingAnimation: false)
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
    /// Activation mode: primary CTA is "Next"; standalone shows "Done".
    var activationMode = false
    var onNext: () -> Void = {}
    var onSkip: () -> Void = {}
    var onDone: () -> Void = {}

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                stepRow(number: "1",
                        titleKey: "Open content",
                        copyKey: "Safari, X, Photos, Notes, Files — anything that offers Share.",
                        symbol: "doc.text.magnifyingglass")
                stepRow(number: "2",
                        titleKey: "Tap Share",
                        copyKey: "Use the system Share button.",
                        symbol: "square.and.arrow.up")
                stepRow(number: "3",
                        titleKey: "Choose PDF It",
                        copyKey: "If PDF It isn't visible, scroll to the end of the apps row and tap More.",
                        symbol: "square.on.square.intersection.filled")

                favoritesCard

                stepRow(number: "4",
                        titleKey: "Choose a mode",
                        copyKey: "Quick keeps everything. Clean and Reader produce polished article PDFs.",
                        symbol: "wand.and.stars")
                stepRow(number: "5",
                        titleKey: "Create PDF",
                        copyKey: "The result lands in your PDF It Library.",
                        symbol: "checkmark.circle.fill")

                Text("PDF It receives only the content the source app chooses to share.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)

                Button(action: activationMode ? onNext : onDone) {
                    Text(activationMode ? "Next" : "Done")
                        .fontWeight(.bold)
                        .frame(maxWidth: .infinity)
                        .frame(height: 56)
                }
                .primaryOrangeButton()
                .padding(.top, 6)

                if activationMode {
                    Button("Skip", action: onSkip)
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .frame(minHeight: 44)
                }
            }
            .padding(20)
        }
        .themeBackground()
        .navigationTitle(activationMode ? "" : "Use PDF It from any app")
        .navigationBarTitleDisplayMode(.inline)
    }

    /// ★ Recommended — teach favoriting without promising one exact iOS menu.
    private var favoritesCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label {
                Text("Add PDF It to your Share Sheet favorites")
                    .font(.subheadline.weight(.bold))
            } icon: {
                Image(systemName: "star.fill")
                    .foregroundStyle(Theme.Colors.orangePrimary)
            }
            Text("To keep PDF It easy to reach, add it to your Share Sheet favorites. Depending on your iOS version, open More → Edit and add PDF It to Favorites.")
                .font(.footnote)
                .foregroundStyle(.secondary)

            HStack(spacing: 6) {
                Image(systemName: "star.fill")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(Theme.Colors.orangePrimary)
                Text("Recommended")
                    .font(.caption2.weight(.black))
                    .kerning(0.5)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(Capsule().fill(Theme.Colors.orangePrimary.opacity(0.14)))
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.white)
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(Theme.Colors.orangePrimary.opacity(0.4), lineWidth: 1.5)
                )
                .shadow(color: Theme.Colors.orangePrimary.opacity(0.12), radius: 8, y: 3)
        )
    }

    private func stepRow(number: String, titleKey: String, copyKey: String, symbol: String) -> some View {
        HStack(alignment: .top, spacing: 13) {
            Text(number)
                .font(.subheadline.weight(.black).monospacedDigit())
                .foregroundStyle(Theme.Colors.orangePrimary)
                .frame(width: 30, height: 30)
                .background(
                    Circle().fill(Theme.Colors.orangePrimary.opacity(0.13))
                )
            VStack(alignment: .leading, spacing: 3) {
                Text(LocalizedStringKey(titleKey))
                    .font(.subheadline.weight(.bold))
                Text(LocalizedStringKey(copyKey))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Image(systemName: symbol)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Theme.Colors.orangePrimary)
        }
        .padding(13)
        .frame(maxWidth: .infinity, minHeight: 44)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.primary.opacity(0.04))
        )
    }
}

// MARK: - Page 2 · Everything you unlocked (shared with Settings)

/// Shown post-purchase and revisitable from Settings. Lists ONLY features
/// actually implemented in this codebase — no vaporware rows.
struct ProFeaturesGuideView: View {
    var activationMode = false
    var onFinish: () -> Void = {}

    struct Feature: Identifiable {
        let id = UUID()
        let symbol: String
        let titleKey: LocalizedStringKey
        let copyKey: LocalizedStringKey
    }

    private let features: [Feature] = [
        Feature(symbol: "square.and.arrow.up",
                titleKey: "SHARE FROM ANY APP",
                copyKey: "The Share Extension turns shared content into PDFs."),
        Feature(symbol: "safari",
                titleKey: "WEB → PDF",
                copyKey: "Quick, Clean and Reader webpage modes."),
        Feature(symbol: "text.viewfinder",
                titleKey: "SEARCHABLE SCANS",
                copyKey: "On-device OCR makes scans searchable and selectable."),
        Feature(symbol: "arrow.down.doc",
                titleKey: "COMPRESS",
                copyKey: "Shrink image-heavy PDFs honestly — never bigger copies."),
        Feature(symbol: "signature",
                titleKey: "SIGN",
                copyKey: "Draw once; reuse your saved signature."),
        Feature(symbol: "doc.badge.plus",
                titleKey: "EXTRACT",
                copyKey: "Selected pages become their own PDF."),
        Feature(symbol: "arrow.up.arrow.down.square",
                titleKey: "ORGANIZE",
                copyKey: "Reorder and rotate pages into a new document."),
        Feature(symbol: "square.stack.3d.up",
                titleKey: "BATCH SCAN",
                copyKey: "Scan several documents in one pass."),
        Feature(symbol: "slider.horizontal.3",
                titleKey: "CUSTOMIZE",
                copyKey: "Cover page, metadata, page numbers, watermark, margins."),
        Feature(symbol: "folder",
                titleKey: "UNLIMITED ORGANIZATION",
                copyKey: "Unlimited folders and merging."),
        Feature(symbol: "lock.shield.fill",
                titleKey: "PRIVACY",
                copyKey: "On-device processing. No account. Nothing uploaded to PDF It."),
    ]

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                MascotView(type: .success, size: 84, enableFloatingAnimation: false)
                    .padding(.bottom, 2)
                Text("Meet your full PDF toolkit")
                    .font(.title3.weight(.heavy))
                    .multilineTextAlignment(.center)

                ForEach(features) { feature in
                    HStack(spacing: 12) {
                        Image(systemName: feature.symbol)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(Theme.Colors.orangePrimary)
                            .frame(width: 34, height: 34)
                            .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .fill(Theme.Colors.orangePrimary.opacity(0.14)))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(feature.titleKey)
                                .font(.caption.weight(.bold))
                                .kerning(0.4)
                            Text(feature.copyKey)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Color.primary.opacity(0.04)))
                }

                Button {
                    onFinish()
                } label: {
                    Text(activationMode ? "Start using PDF It" : "Done")
                        .fontWeight(.bold)
                        .frame(maxWidth: .infinity)
                        .frame(height: 56)
                }
                .primaryOrangeButton()
                .padding(.top, 8)
            }
            .padding(20)
        }
        .themeBackground()
        .navigationTitle(activationMode ? "" : "Explore Pro Features")
        .navigationBarTitleDisplayMode(.inline)
    }
}
