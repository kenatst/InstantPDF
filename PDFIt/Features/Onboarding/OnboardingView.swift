import SwiftUI

/// Three cinematic screens showcasing PDF It's speed, simplicity, and privacy.
struct OnboardingView: View {
    @AppStorage(AppSettingsKeys.hasCompletedOnboarding, store: AppConfiguration.sharedDefaults)
    private var hasCompletedOnboarding = false

    @State private var page: Int

    init(initialPage: Int = 0) {
        _page = State(initialValue: initialPage)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.Colors.darkBackground.ignoresSafeArea()

                VStack(spacing: 0) {
                    TabView(selection: $page) {
                        page1.tag(0)
                        page2.tag(1)
                        page3.tag(2)
                    }
                    .tabViewStyle(.page(indexDisplayMode: .never))

                    // Custom Page Indicators
                    HStack(spacing: 8) {
                        ForEach(0..<3) { index in
                            Capsule()
                                .fill(page == index ? Theme.Colors.orangePrimary : Color.white.opacity(0.2))
                                .frame(width: page == index ? 22 : 7, height: 7)
                                .animation(.spring(response: 0.3, dampingFraction: 0.7), value: page)
                        }
                    }
                    .padding(.bottom, 24)

                    // Bottom Action Button
                    Button {
                        withAnimation(.easeInOut(duration: 0.25)) {
                            if page < 2 {
                                page += 1
                            } else {
                                hasCompletedOnboarding = true
                            }
                        }
                    } label: {
                        Text(page < 2 ? "Continue" : "Get Started")
                    }
                    .primaryOrangeButton()
                    .padding(.horizontal, 24)
                    .padding(.bottom, 20)
                    .accessibilityHint(page < 2 ? "Show the next page" : "Start using PDF It")
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Skip") {
                        hasCompletedOnboarding = true
                    }
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Color.white.opacity(0.6))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Color.white.opacity(0.08), in: Capsule())
                }
            }
            .preferredColorScheme(.dark)
        }
    }

    private var page1: some View {
        OnboardingPage(
            mascotType: .onboarding1,
            title: "Anything to PDF",
            text: "Turn photos, links, text, and files into beautiful PDFs instantly."
        )
    }

    private var page2: some View {
        OnboardingPage(
            mascotType: .onboarding2,
            title: "Share. PDF It. Done.",
            text: "Use the share sheet. We'll handle the rest."
        )
    }

    private var page3: some View {
        OnboardingPage(
            mascotType: .onboarding3,
            title: "Private & Local",
            text: "No uploads. No account. Everything stays on your device."
        )
    }
}

private struct OnboardingPage: View {
    let mascotType: MascotView.MascotType
    let title: String
    let text: String

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 20)

            VStack(spacing: 12) {
                Text(title)
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .accessibilityAddTraits(.isHeader)

                Text(text)
                    .font(.subheadline)
                    .foregroundStyle(Color.white.opacity(0.7))
                    .multilineTextAlignment(.center)
                    .lineSpacing(3)
                    .padding(.horizontal, 36)
            }
            .padding(.top, 20)

            Spacer()

            MascotView(type: mascotType, size: 240)
                .padding(.bottom, 20)

            Spacer()
        }
        .padding(.horizontal, 16)
    }
}
