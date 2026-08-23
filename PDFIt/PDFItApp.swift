import SwiftUI

@main
struct PDFItApp: App {
    @AppStorage(AppSettingsKeys.hasCompletedOnboarding, store: AppConfiguration.sharedDefaults)
    private var hasCompletedOnboarding = false

    var body: some Scene {
        WindowGroup {
            if hasCompletedOnboarding {
                MainTabView()
            } else {
                OnboardingView()
            }
        }
    }
}

/// Home + Library tabs. Settings lives behind the Home toolbar — three
/// top-level destinations felt like one too many for a utility this focused.
struct MainTabView: View {
    @State private var selectedTab = 0
    @State private var showingSettings = false

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
                SettingsView()
            }
        }
    }
}
