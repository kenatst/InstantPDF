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
                    .environment(\.locale, activeLocale)
                    .environmentObject(languageSetting)
            } else {
                OnboardingView {
                    withAnimation(.easeInOut(duration: 0.3)) {
                        hasCompletedOnboarding = true
                    }
                }
                .environment(\.locale, activeLocale)
            }
        }
    }

    private var activeLocale: Locale {
        // Before a user picks an in-app override, resolve the iPhone's
        // preferred language through our supported set. This makes a first
        // launch deterministic (en/fr/es/de/it) and gives unsupported system
        // languages the documented English fallback.
        let language = languageSetting.language ?? LanguageManager.resolved
        return Locale(identifier: language.rawValue)
    }
}

/// Home + Library tabs. Settings lives behind the Home toolbar — three
/// top-level destinations felt like one too many for a utility this focused.
struct MainTabView: View {
    @State private var selectedTab = 0
    @State private var showingSettings = false
    @EnvironmentObject var languageSetting: LanguageSetting
    @Environment(\.colorScheme) private var colorScheme

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
        .toolbarBackground(colorScheme == .dark ? Theme.Colors.darkCard : Theme.Colors.surface, for: .tabBar)
        .toolbarBackground(.visible, for: .tabBar)
        .onAppear {
            // ONE authoritative entitlement startup: transaction listener +
            // product load + recompute. PaywallView.task calls start() too,
            // but this guarantees gating state exists before any Pro intent.
            EntitlementCenter.shared.start()
        }
        .sheet(isPresented: $showingSettings) {
            NavigationStack {
                SettingsView(languageSetting: languageSetting)
            }
        }
    }
}
