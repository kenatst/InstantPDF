import SwiftUI

/// A focused three-page introduction to PDFIT's conversion, sharing, and privacy promises.
struct OnboardingView: View {
    @AppStorage(AppSettingsKeys.hasCompletedOnboarding)
    private var hasCompletedOnboarding = false

    @State private var page: Int
    @State private var hasAppeared = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var onComplete: (() -> Void)?

    init(initialPage: Int = 0, onComplete: (() -> Void)? = nil) {
        _page = State(initialValue: min(max(initialPage, 0), 2))
        self.onComplete = onComplete
    }

    var body: some View {
        ZStack {
            OnboardingBackdrop(page: page)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                topBar

                TabView(selection: $page) {
                    conversionPage.tag(0)
                    sharePage.tag(1)
                    privacyPage.tag(2)
                }
                .tabViewStyle(.page(indexDisplayMode: .never))

                pageControl
                    .padding(.top, 10)
                    .padding(.bottom, 20)

                Button(action: advance) {
                    HStack(spacing: 10) {
                        Text(page < 2 ? LocalizedStringKey("Continue") : LocalizedStringKey("Get Started"))
                        Image(systemName: "arrow.right")
                            .font(.headline.weight(.bold))
                    }
                }
                .primaryOrangeButton()
                .padding(.horizontal, 24)
                .padding(.bottom, 14)
                .accessibilityHint(page < 2 ? Text("Show the next page") : Text("Start using PDFIT"))
            }
            .opacity(hasAppeared ? 1 : 0)
            .offset(y: hasAppeared ? 0 : 8)
        }
        .preferredColorScheme(.dark)
        .onAppear {
            guard !hasAppeared else { return }
            if reduceMotion {
                hasAppeared = true
            } else {
                withAnimation(.easeOut(duration: 0.45)) {
                    hasAppeared = true
                }
            }
        }
    }

    private var topBar: some View {
        HStack {
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(Theme.Colors.orangePrimary)
                    .frame(width: 4, height: 18)

                Text("PDFIT")
                    .font(.system(.headline, design: .rounded, weight: .black))
                    .tracking(1.1)
                    .foregroundStyle(.white)
            }

            Spacer()

            Button("Skip", action: completeOnboarding)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color.white.opacity(0.68))
                .buttonStyle(.plain)
        }
        .padding(.horizontal, 24)
        .padding(.top, 12)
        .padding(.bottom, 2)
    }

    private var pageControl: some View {
        HStack(spacing: 8) {
            ForEach(0..<3, id: \.self) { index in
                Capsule()
                    .fill(page == index ? Theme.Colors.orangePrimary : Color.white.opacity(0.22))
                    .frame(width: page == index ? 24 : 7, height: 7)
                    .animation(reduceMotion ? nil : .spring(response: 0.32, dampingFraction: 0.8), value: page)
            }
        }
        .accessibilityHidden(true)
    }

    private var conversionPage: some View {
        OnboardingPage(
            title: "Anything to PDF",
            subtitle: "Transform photos, links, text, and files into beautiful PDFs in seconds."
        ) {
            OnboardingHero(assetName: "MascotOnboarding1", isActive: page == 0)
        }
    }

    private var sharePage: some View {
        OnboardingPage(
            title: "Share. PDFIT. Done.",
            subtitle: "Use the Share Sheet from your apps. PDFIT turns shared content into a PDF fast."
        ) {
            OnboardingHero(assetName: "MascotOnboarding2", isActive: page == 1)
        }
    }

    private var privacyPage: some View {
        OnboardingPage(
            title: "Private & Local",
            subtitle: "No account. No PDFIT uploads. On-device OCR. Web pages load from their source."
        ) {
            OnboardingHero(assetName: "MascotOnboarding3", isActive: page == 2)
        }
    }

    private func advance() {
        if page < 2 {
            withAnimation(.easeInOut(duration: 0.3)) { page += 1 }
        } else {
            completeOnboarding()
        }
    }

    private func completeOnboarding() {
        hasCompletedOnboarding = true
        UserDefaults.standard.set(true, forKey: AppSettingsKeys.hasCompletedOnboarding)
        AppConfiguration.sharedDefaults.set(true, forKey: AppSettingsKeys.hasCompletedOnboarding)
        onComplete?()
    }
}

// MARK: - Editorial building blocks

private struct OnboardingPage<Artwork: View>: View {
    let title: LocalizedStringKey
    let subtitle: LocalizedStringKey
    @ViewBuilder let artwork: Artwork

    init(title: LocalizedStringKey,
         subtitle: LocalizedStringKey,
         @ViewBuilder artwork: () -> Artwork) {
        self.title = title
        self.subtitle = subtitle
        self.artwork = artwork()
    }

    var body: some View {
        GeometryReader { proxy in
            let compact = proxy.size.height < 560
            let heroHeight = min(
                max(proxy.size.height * (compact ? 0.50 : 0.56), compact ? 224 : 270),
                430
            )

            VStack(spacing: 0) {
                Spacer(minLength: compact ? 8 : 18)

                Text(title)
                    .font(.system(size: compact ? 32 : 38, weight: .bold, design: .rounded))
                    .tracking(-0.8)
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .minimumScaleFactor(0.8)
                    .lineLimit(2)
                    .padding(.horizontal, 24)
                    .accessibilityAddTraits(.isHeader)

                Spacer(minLength: compact ? 8 : 14)

                artwork
                    .frame(height: heroHeight)
                    .padding(.horizontal, 14)

                Spacer(minLength: compact ? 8 : 18)

                Text(subtitle)
                    .font(.system(.body, design: .rounded, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.70))
                    .multilineTextAlignment(.center)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, compact ? 24 : 34)

                Spacer(minLength: compact ? 6 : 14)
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
    }
}

private struct OnboardingBackdrop: View {
    let page: Int

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color(hex: "070809"), Color(hex: "101114"), Color(hex: "08090B")],
                startPoint: .top,
                endPoint: .bottom
            )

            RadialGradient(
                colors: [Theme.Colors.orangeDark.opacity(0.12), .clear],
                center: glowCenter,
                startRadius: 0,
                endRadius: 390
            )
            .animation(.easeInOut(duration: 0.5), value: page)

            LinearGradient(
                colors: [Color.white.opacity(0.025), .clear],
                startPoint: .top,
                endPoint: .center
            )
        }
    }

    private var glowCenter: UnitPoint {
        switch page {
        case 0: UnitPoint(x: 0.18, y: 0.12)
        case 1: UnitPoint(x: 0.82, y: 0.12)
        default: .center
        }
    }
}

private struct OnboardingHero: View {
    let assetName: String
    let isActive: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            RadialGradient(
                colors: [Theme.Colors.orangePrimary.opacity(0.14), .clear],
                center: .center,
                startRadius: 20,
                endRadius: 210
            )
            .scaleEffect(x: 1.18, y: 0.82)
            .accessibilityHidden(true)

            Image(assetName)
                .resizable()
                .scaledToFit()
                .padding(4)
                .scaleEffect(isActive ? 1 : 0.965)
                .opacity(isActive ? 1 : 0.78)
                .shadow(color: .black.opacity(0.34), radius: 22, y: 14)
                .animation(
                    reduceMotion ? nil : .easeOut(duration: 0.42),
                    value: isActive
                )
                .accessibilityHidden(true)
        }
        .frame(maxWidth: 500)
    }
}

private struct OnboardingSourceRail: View {
    private let sources: [(LocalizedStringKey, String)] = [
        ("Scan", "viewfinder"),
        ("Photos", "photo"),
        ("Files", "folder"),
        ("Text", "doc.text"),
        ("Web", "safari")
    ]

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(sources.enumerated()), id: \.offset) { _, source in
                VStack(spacing: 7) {
                    Image(systemName: source.1)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(Theme.Colors.orangeLight)
                    Text(source.0)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Color.white.opacity(0.62))
                }
                .frame(maxWidth: .infinity)
            }
        }
        .padding(.horizontal, 14)
    }
}

private struct OnboardingShareFlow: View {
    var body: some View {
        VStack(spacing: 18) {
            HStack(spacing: 26) {
                source("safari", "Safari")
                source("photo", "Photos")
                source("folder", "Files")
                source("message", "Messages")
            }
            flowArrow
            Label("Share", systemImage: "square.and.arrow.up")
                .font(.headline.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 22)
                .padding(.vertical, 14)
                .background(Color.white.opacity(0.07), in: Capsule())
            flowArrow
            HStack(spacing: 12) {
                Text("PDFIT")
                    .font(.title3.weight(.black))
                    .tracking(1)
                Image(systemName: "arrow.right")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
                Image(systemName: "doc.fill")
                    .font(.title2)
                    .foregroundStyle(Theme.Colors.orangePrimary)
                Text("PDF")
                    .font(.headline.weight(.bold))
            }
            .foregroundStyle(.white)
        }
    }

    private var flowArrow: some View {
        Image(systemName: "arrow.down")
            .font(.caption.weight(.bold))
            .foregroundStyle(Theme.Colors.orangePrimary)
    }

    private func source(_ symbol: String, _ label: LocalizedStringKey) -> some View {
        VStack(spacing: 7) {
            Image(systemName: symbol)
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(.white)
            Text(label)
                .font(.caption2)
                .foregroundStyle(Color.white.opacity(0.58))
        }
    }
}

private struct OnboardingTrustRow: View {
    var body: some View {
        HStack(spacing: 0) {
            trust("person.crop.circle.badge.xmark", "No account")
            trust("icloud.slash", "No PDFIT uploads")
            trust("cpu", "On-device OCR")
        }
    }

    private func trust(_ symbol: String, _ text: LocalizedStringKey) -> some View {
        VStack(spacing: 7) {
            Image(systemName: symbol)
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(Theme.Colors.orangeLight)
            Text(text)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(Color.white.opacity(0.62))
                .multilineTextAlignment(.center)
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity)
    }
}

private struct OnboardingStage: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 34, style: .continuous)
            .fill(
                LinearGradient(colors: [Color.white.opacity(0.045), Color.black.opacity(0.34)],
                               startPoint: .top,
                               endPoint: .bottom)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 34, style: .continuous)
                    .strokeBorder(
                        LinearGradient(colors: [Theme.Colors.orangeLight.opacity(0.52), .white.opacity(0.055)],
                                       startPoint: .topLeading,
                                       endPoint: .bottomTrailing),
                        lineWidth: 1
                    )
            }
            .shadow(color: Theme.Colors.orangeDark.opacity(0.18), radius: 26, y: 14)
            .padding(.horizontal, 12)
    }
}

private struct SourcePortrait: View {
    let type: MascotView.MascotType
    let label: LocalizedStringKey

    var body: some View {
        VStack(spacing: 2) {
            MascotView(type: type, size: 76, enableFloatingAnimation: false)
            Text(label)
                .font(.caption2.weight(.bold))
                .foregroundStyle(.white.opacity(0.84))
        }
        .padding(.vertical, 6)
        .frame(width: 90)
        .background(.black.opacity(0.22), in: RoundedRectangle(cornerRadius: 17, style: .continuous))
    }
}

private struct ScanMark: View {
    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "viewfinder")
                .font(.caption.weight(.bold))
            Text("Scan Document")
                .font(.caption.weight(.bold))
        }
        .foregroundStyle(Theme.Colors.orangeLight)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.black.opacity(0.52), in: Capsule())
        .overlay(Capsule().strokeBorder(Theme.Colors.orangePrimary.opacity(0.45), lineWidth: 1))
    }
}

private struct ShareSheetConcept: View {
    private let sources: [(LocalizedStringKey, String, Color)] = [
        ("Safari", "safari.fill", .blue),
        ("Photos", "photo.fill", .pink),
        ("Messages", "message.fill", .green),
        ("Notes", "note.text", .yellow),
        ("Files", "folder.fill", .cyan)
    ]

    var body: some View {
        VStack(spacing: 16) {
            Capsule()
                .fill(Color.white.opacity(0.22))
                .frame(width: 42, height: 5)

            HStack(spacing: 0) {
                ForEach(Array(sources.enumerated()), id: \.offset) { _, source in
                    VStack(spacing: 7) {
                        Image(systemName: source.1)
                            .font(.system(size: 19, weight: .semibold))
                            .foregroundStyle(source.2)
                            .frame(width: 43, height: 43)
                            .background(source.2.opacity(0.16), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                        Text(source.0)
                            .font(.system(size: 9, weight: .medium))
                            .lineLimit(1)
                            .foregroundStyle(Color.white.opacity(0.73))
                    }
                    .frame(maxWidth: .infinity)
                }
            }

            Divider().overlay(Color.white.opacity(0.10))

            HStack(spacing: 12) {
                Image(systemName: "doc.richtext.fill")
                    .font(.headline.weight(.bold))
                    .foregroundStyle(.white)
                    .frame(width: 42, height: 42)
                    .background(Theme.Colors.orangeGradient, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                Text("PDFIT")
                    .font(.headline.weight(.black))
                    .kerning(0.7)
                    .foregroundStyle(.white)
                Spacer()
                HStack(spacing: 4) {
                    Text("PDF")
                    Image(systemName: "arrow.right")
                }
                .font(.caption.weight(.black))
                .foregroundStyle(Theme.Colors.orangeLight)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(Theme.Colors.orangePrimary.opacity(0.16), in: Capsule())
            }
            .padding(12)
            .background(Theme.Colors.orangePrimary.opacity(0.09), in: RoundedRectangle(cornerRadius: 17, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 17, style: .continuous).strokeBorder(Theme.Colors.orangePrimary.opacity(0.58), lineWidth: 1))
        }
        .padding(16)
        .padding(.top, 26)
        .background(.black.opacity(0.58), in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 28, style: .continuous).strokeBorder(Color.white.opacity(0.13), lineWidth: 1))
        .shadow(color: .black.opacity(0.42), radius: 22, y: 12)
    }
}

private struct LocalArchiveScene: View {
    var body: some View {
        HStack(spacing: 20) {
            VStack(spacing: 15) {
                archiveGlyph("doc.text.fill")
                archiveGlyph("folder.fill")
            }
            .offset(x: -82, y: 6)
            VStack(spacing: 15) {
                archiveGlyph("magnifyingglass")
                archiveGlyph("text.viewfinder")
            }
            .offset(x: 82, y: 6)
        }
        .opacity(0.72)
    }

    private func archiveGlyph(_ symbol: String) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 22, weight: .medium))
            .foregroundStyle(Theme.Colors.orangeLight.opacity(0.9))
            .frame(width: 50, height: 50)
            .background(.black.opacity(0.34), in: RoundedRectangle(cornerRadius: 15, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 15, style: .continuous).strokeBorder(Theme.Colors.orangePrimary.opacity(0.28), lineWidth: 1))
    }
}
