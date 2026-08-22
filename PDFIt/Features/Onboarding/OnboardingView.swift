import SwiftUI

/// Three screens, then out of the way.
struct OnboardingView: View {
    @AppStorage(AppSettingsKeys.hasCompletedOnboarding)
    private var hasCompletedOnboarding = false

    @State private var page = 0

    var body: some View {
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
    }

    private var page1: some View {
        OnboardingPage(symbol: "arrow.triangle.swap",
                       title: "Anything → PDF",
                       text: "Photos, webpages, text and files — turned into clean PDFs.")
    }

    private var page2: some View {
        OnboardingPage(symbol: "square.and.arrow.up",
                       title: "Share → PDF It → Done",
                       text: "Tap Share in any app, choose PDF It, and preview your document in seconds.")
    }

    private var page3: some View {
        OnboardingPage(symbol: "lock.shield",
                       title: "Private by default",
                       text: "Conversions happen on your device whenever possible. No signup, no account, no unnecessary permissions.")
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
