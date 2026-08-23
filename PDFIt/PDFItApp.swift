import SwiftUI

@main
struct PDFItApp: App {
    @AppStorage(AppSettingsKeys.hasCompletedOnboarding)
    private var hasCompletedOnboarding = false
    @StateObject private var languageSetting = LanguageSetting.shared

    var body: some Scene {
        WindowGroup {
            if hasCompletedOnboarding {
                MainTabView()
                    .environment(\.pdfItLanguage, languageSetting.language)
                    .environmentObject(languageSetting)
                    // Identity token: switching language rebuilds the tree so
                    // every localized string re-resolves immediately — no
                    // relaunch required.
                    .id(languageSetting.refreshToken)
            } else {
                OnboardingView {
                    withAnimation(.easeInOut(duration: 0.3)) {
                        hasCompletedOnboarding = true
                    }
                }
                .id(languageSetting.refreshToken)
            }
        }
    }
}

/// Home + Library tabs. Settings lives behind the Home toolbar — three
/// top-level destinations felt like one too many for a utility this focused.
struct MainTabView: View {
    @State private var selectedTab = 0
    @State private var showingSettings = false
    @EnvironmentObject var languageSetting: LanguageSetting

    var body: some View {
        TabView(selection: $selectedTab) {
            NavigationStack {
                HomeView(showingSettings: $showingSettings)
            }
            .tabItem {
                Label("Home", systemImage: "house.fill")
            }
            .tag(0)

            NavigationStack {
                LibraryView()
            }
            .tabItem {
                Label("Library", systemImage: "books.vertical.fill")
            }
            .tag(1)
        }
        .tint(Theme.Colors.orangePrimary)
        .sheet(isPresented: $showingSettings) {
            NavigationStack {
                SettingsView(languageSetting: languageSetting)
            }
        }
    }
}
