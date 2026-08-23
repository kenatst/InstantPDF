import SwiftUI

/// Three screens, then out of the way.
struct OnboardingView: View {
    @AppStorage(AppSettingsKeys.hasCompletedOnboarding, store: AppConfiguration.sharedDefaults)
    private var hasCompletedOnboarding = false

    @State private var page = 0

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                TabView(selection: $page) {
                    page1.tag(0)
                    page2.tag(1)
                    page3.tag(2)
                }
                .tabViewStyle(.page(indexDisplayMode: .always))
                .indexViewStyle(.page(backgroundDisplayMode: .always))

                Button {
                    withAnimation(.easeInOut(duration: 0.25)) {
                        if page < 2 {
                            page += 1
                        } else {
                            hasCompletedOnboarding = true
                        }
                    }
                } label: {
                    Text(page < 2 ? "Next" : "Get Started")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .padding(.horizontal, 24)
                .padding(.bottom, 16)
                .accessibilityHint(page < 2 ? "Show the next page" : "Start using PDF It")
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Skip") {
                        hasCompletedOnboarding = true
                    }
                    .font(.subheadline)
                }
            }
        }
    }

    private var page1: some View {
        OnboardingPage(symbol: "arrow.triangle.swap",
                       title: "Anything to PDF",
                       text: "Photos, webpages, text, and files — converted into clean, readable PDFs in seconds.")
    }

    private var page2: some View {
        OnboardingPage(symbol: "square.and.arrow.up",
                       title: "From Any App",
                       text: "Tap Share in Safari, Photos, or Notes. Choose PDF It and your PDF is ready instantly.")
    }

    private var page3: some View {
        OnboardingPage(symbol: "lock.shield",
                       title: "Private & Local",
                       text: "Your documents are processed directly on your device. No account, no cloud upload, no tracking.")
    }
}

private struct OnboardingPage: View {
    let symbol: String
    let title: String
    let text: String

    var body: some View {
        VStack(spacing: 22) {
            Spacer()
            Image(systemName: symbol)
                .font(.system(size: 56, weight: .medium))
                .foregroundStyle(.tint)
                .accessibilityHidden(true)

            Text(title)
                .font(.system(size: 30, weight: .heavy, design: .rounded))
                .multilineTextAlignment(.center)
                .accessibilityAddTraits(.isHeader)

            Text(text)
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 36)

            Spacer()
            Spacer()
        }
        .padding(.top, 24)
    }
}
