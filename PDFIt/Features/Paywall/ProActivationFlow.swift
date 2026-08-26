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
    @State private var textIn = false

    private let generator = UINotificationFeedbackGenerator()

    var body: some View {
        ZStack {
            Theme.Colors.darkBackground.ignoresSafeArea()

            VStack(spacing: 22) {
                Spacer()
                MascotView(type: .crown, size: 190, enableFloatingAnimation: false)
                    .scaleEffect(mascotIn ? 1 : (reduceMotion ? 1 : 0.82))
                    .opacity(mascotIn ? 1 : 0)

                VStack(spacing: 8) {
                    Text("PDFIT PRO")
                        .font(.system(size: 12, weight: .black, design: .rounded))
                        .tracking(2.4)
                        .foregroundStyle(Theme.Colors.orangePrimary)
                    Text("Every Pro feature is unlocked on this device.")
                        .font(.system(size: 29, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                    Text("No uploads. No account. Everything stays on your device.")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.white.opacity(0.62))
                        .multilineTextAlignment(.center)
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
            generator.notificationOccurred(.success)
            try? await Task.sleep(nanoseconds: 220_000_000)
            withAnimation(.easeOut(duration: 0.45)) { textIn = true }
        }
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
                VStack(alignment: .leading, spacing: 28) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Use PDFIT from any app")
                            .font(.system(size: 32, weight: .bold, design: .rounded))
                        Text("Turn shared content into a PDF without leaving the app.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }

                    shareWorkflow

                    VStack(spacing: 0) {
                        instructionRow(number: "1", title: "Open content", detail: "Use the Share Sheet from compatible apps.")
                        Divider().padding(.leading, 48)
                        instructionRow(number: "2", title: "Tap Share", detail: "Use the system Share button.")
                        Divider().padding(.leading, 48)
                        instructionRow(number: "3", title: "Choose PDFIT", detail: "PDFIT receives only the content the source app chooses to share.")
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Add PDFIT to your Share Sheet favorites")
                            .font(.footnote.weight(.bold))
                        Text("If PDFIT isn't visible, scroll to the end of the apps row and tap More.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    .padding(16)
                    .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
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

    private var shareWorkflow: some View {
        VStack(spacing: 12) {
            HStack(spacing: 22) {
                workflowSource("safari", label: "Safari")
                workflowSource("photo", label: "Photos")
                workflowSource("folder", label: "Files")
                workflowSource("message", label: "Messages")
            }
            Image(systemName: "arrow.down")
                .font(.footnote.weight(.bold))
                .foregroundStyle(.secondary)
            HStack(spacing: 12) {
                Image(systemName: "square.and.arrow.up")
                    .font(.title3.weight(.semibold))
                Image(systemName: "arrow.right")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
                Text("PDFIT")
                    .font(.headline.weight(.black))
                    .tracking(0.8)
                Image(systemName: "arrow.right")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
                Image(systemName: "doc.fill")
                    .font(.title3)
                    .foregroundStyle(Theme.Colors.orangePrimary)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
            .background(Color.secondary.opacity(0.08), in: Capsule())
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .accessibilityElement(children: .combine)
    }

    private func workflowSource(_ symbol: String, label: LocalizedStringKey) -> some View {
        VStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.system(size: 18, weight: .semibold))
                .frame(width: 42, height: 42)
                .background(Color.secondary.opacity(0.09), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
    }

    private func instructionRow(number: String,
                                title: LocalizedStringKey,
                                detail: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Text(number)
                .font(.caption.weight(.bold))
                .foregroundStyle(Theme.Colors.orangePrimary)
                .frame(width: 30, height: 30)
                .background(Theme.Colors.orangePrimary.opacity(0.12), in: Circle())
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
                        MascotView(type: .crown, size: 148, enableFloatingAnimation: false)
                        .accessibilityHidden(true)

                        VStack(spacing: 6) {
                            Text("PDFIT PRO")
                                .font(.caption.weight(.black))
                                .tracking(2.2)
                            .foregroundStyle(Theme.Colors.orangePrimary)

                            Text("What PDFIT PRO unlocks")
                                .font(.system(size: 24, weight: .bold, design: .rounded))
                                .multilineTextAlignment(.center)

                            Text("A focused set of tools for creating and working with PDFs.")
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
                                 copy: "Sign contracts & forms anywhere on page. On-device OCR extracts selectable text with no PDFIT uploads.")
                        Divider().overlay(Color.white.opacity(0.08))
                            .padding(.leading, 54)
                        guideRow(symbol: "arrow.down.doc",
                                 title: "Compress & Batch Scan",
                                 copy: "Shrink heavy PDFs while keeping crisp quality. Continuous batch scanning to group and save multiple documents.")
                        Divider().overlay(Color.white.opacity(0.08))
                            .padding(.leading, 54)
                        guideRow(symbol: "square.stack.3d.up",
                                 title: "Extract Pages & Unlimited Organization",
                                 copy: "Extract selected pages into a new PDF. Unlimited folders, advanced merge and custom formatting.")
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
                            featureCheckRow(name: "Extract Pages into New PDF", free: false, pro: true)
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

                    // Privacy Proof Strip (Exact, truthful claims)
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
