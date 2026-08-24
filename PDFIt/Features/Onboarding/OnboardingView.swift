import SwiftUI

/// A short, editorial onboarding that introduces the product's three core promises.
/// The scenes are native SwiftUI compositions rather than fake screenshots, so they
/// remain legible at every Dynamic Type size and in every supported language.
struct OnboardingView: View {
    @AppStorage(AppSettingsKeys.hasCompletedOnboarding)
    private var hasCompletedOnboarding = false

    @State private var page: Int
    @State private var hasAppeared = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var onComplete: (() -> Void)?

    init(initialPage: Int = 0, onComplete: (() -> Void)? = nil) {
        _page = State(initialValue: initialPage)
        self.onComplete = onComplete
    }

    var body: some View {
        NavigationStack {
            ZStack {
                OnboardingBackdrop(page: page)
                    .ignoresSafeArea()

                VStack(spacing: 0) {
                    TabView(selection: $page) {
                        conversionPage.tag(0)
                        sharePage.tag(1)
                        privacyPage.tag(2)
                    }
                    .tabViewStyle(.page(indexDisplayMode: .never))
                    .animation(.easeInOut(duration: 0.35), value: page)

                    pageControl
                        .padding(.top, 6)
                        .padding(.bottom, 18)

                    Button(action: advance) {
                        HStack(spacing: 10) {
                            Text(page < 2 ? LocalizedStringKey("Continue") : LocalizedStringKey("Get Started"))
                            Image(systemName: page < 2 ? "arrow.right" : "arrow.right.circle.fill")
                                .font(.headline.weight(.bold))
                        }
                    }
                    .primaryOrangeButton()
                    .padding(.horizontal, 24)
                    .padding(.bottom, 18)
                    .accessibilityHint(page < 2 ? Text("Show the next page") : Text("Start using PDFIT"))
                }
                .opacity(hasAppeared ? 1 : 0)
                .offset(y: hasAppeared ? 0 : 10)
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Skip", action: completeOnboarding)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color.white.opacity(0.72))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Color.white.opacity(0.07), in: Capsule())
                }
            }
            .preferredColorScheme(.dark)
            .onAppear {
                guard !hasAppeared else { return }
                if reduceMotion {
                    hasAppeared = true
                } else {
                    withAnimation(.easeOut(duration: 0.5)) { hasAppeared = true }
                }
            }
        }
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
        .accessibilityElement(children: .ignore)
    }

    // MARK: - 1. Any source, one destination

    private var conversionPage: some View {
        OnboardingPage(title: "Anything to PDF",
                       subtitle: "Turn photos, links, text, and files into beautiful PDFs instantly.") {
            ZStack {
                OnboardingStage()

                MascotView(type: .hero, size: 194, enableFloatingAnimation: !reduceMotion)
                    .offset(y: 18)

                SourcePortrait(type: .photos, label: "Photos")
                    .offset(x: -104, y: -78)
                SourcePortrait(type: .link, label: "Link")
                    .offset(x: 104, y: -64)
                SourcePortrait(type: .text, label: "Text")
                    .offset(x: -104, y: 84)
                SourcePortrait(type: .files, label: "Files")
                    .offset(x: 102, y: 92)

                ScanMark()
                    .offset(y: 135)
            }
            .frame(maxWidth: 390)
            .frame(height: 370)
        }
    }

    // MARK: - 2. Share extension, made understandable at a glance

    private var sharePage: some View {
        OnboardingPage(title: "Share. PDFIT. Done.",
                       subtitle: "Use the share sheet. We'll handle the rest.") {
            ZStack(alignment: .top) {
                OnboardingStage()

                MascotView(type: .hero, size: 108, enableFloatingAnimation: false)
                    .offset(y: -72)
                    .zIndex(2)

                ShareSheetConcept()
                    .padding(.horizontal, 22)
                    .padding(.top, 50)
            }
            .frame(maxWidth: 390)
            .frame(height: 370)
        }
    }

    // MARK: - 3. Truthful, local privacy story

    private var privacyPage: some View {
        OnboardingPage(title: "Private & Local",
                       subtitle: "On-device processing. No account. Nothing uploaded to PDFIT.") {
            VStack(spacing: 0) {
                ZStack {
                    OnboardingStage()

                    LocalArchiveScene()

                    MascotView(type: .library, size: 228, enableFloatingAnimation: !reduceMotion)
                        .offset(y: 8)

                    Image(systemName: "lock.fill")
                        .font(.system(size: 19, weight: .bold))
                        .foregroundStyle(Theme.Colors.orangeLight)
                        .padding(14)
                        .background(.black.opacity(0.52), in: Circle())
                        .overlay(Circle().strokeBorder(Theme.Colors.orangePrimary.opacity(0.58), lineWidth: 1))
                        .offset(y: -132)
                }
                .frame(maxWidth: 390)
                .frame(height: 310)

                Text("PDF It processes and stores documents locally. Your documents are not uploaded to PDF It. When you convert a webpage, PDF It loads the page directly from its source website.")
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(Color.white.opacity(0.68))
                    .multilineTextAlignment(.center)
                    .lineSpacing(2)
                    .padding(.horizontal, 18)
                    .padding(.top, 2)
            }
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
        VStack(spacing: 0) {
            VStack(spacing: 11) {
                Text(title)
                    .font(.system(size: 34, weight: .black, design: .rounded))
                    .tracking(-0.7)
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .accessibilityAddTraits(.isHeader)

                Text(subtitle)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Color.white.opacity(0.69))
                    .multilineTextAlignment(.center)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 22)
            .padding(.horizontal, 24)

            Spacer(minLength: 12)
            artwork
            Spacer(minLength: 8)
        }
    }
}

private struct OnboardingBackdrop: View {
    let page: Int

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(hex: "050505"), Color(hex: "0B0806"), Color(hex: "060606")],
                           startPoint: .top,
                           endPoint: .bottom)
            RadialGradient(colors: [Theme.Colors.orangePrimary.opacity(page == 1 ? 0.18 : 0.11), .clear],
                           center: .bottom,
                           startRadius: 8,
                           endRadius: 420)
            LinearGradient(colors: [.white.opacity(0.035), .clear], startPoint: .top, endPoint: .center)
        }
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
