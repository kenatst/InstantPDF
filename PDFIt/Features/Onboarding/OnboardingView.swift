import SwiftUI

/// Three cinematic onboarding screens with character interaction and native SwiftUI compositions.
struct OnboardingView: View {
    @AppStorage(AppSettingsKeys.hasCompletedOnboarding)
    private var hasCompletedOnboarding = false

    @State private var page: Int
    var onComplete: (() -> Void)?

    init(initialPage: Int = 0, onComplete: (() -> Void)? = nil) {
        _page = State(initialValue: initialPage)
        self.onComplete = onComplete
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
                    .padding(.bottom, 22)

                    // Bottom Action Button
                    Button {
                        if page < 2 {
                            withAnimation(.easeInOut(duration: 0.3)) {
                                page += 1
                            }
                        } else {
                            completeOnboarding()
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
                        completeOnboarding()
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

    private func completeOnboarding() {
        hasCompletedOnboarding = true
        UserDefaults.standard.set(true, forKey: AppSettingsKeys.hasCompletedOnboarding)
        AppConfiguration.sharedDefaults.set(true, forKey: AppSettingsKeys.hasCompletedOnboarding)
        onComplete?()
    }

    // MARK: - Screen 1: Anything to PDF + Floating Vector Tiles

    private var page1: some View {
        VStack(spacing: 0) {
            header(
                title: "Anything to PDF",
                subtitle: "Turn photos, links, text, and files into beautiful PDFs instantly."
            )

            Spacer()

            ZStack {
                // Background ambient warm glow
                RadialGradient(
                    colors: [Theme.Colors.orangePrimary.opacity(0.25), Color.clear],
                    center: .center,
                    startRadius: 10,
                    endRadius: 160
                )
                .frame(width: 320, height: 320)

                // Mascot in Center
                MascotView(type: .onboarding1, size: 195)

                // Floating Vector Source Tiles
                FloatingSourceTile(icon: "photo.fill", label: "Photos", xOffset: -125, yOffset: -75)
                FloatingSourceTile(icon: "link", label: "Link", xOffset: 125, yOffset: -75)
                FloatingSourceTile(icon: "doc.text.fill", label: "Text", xOffset: -125, yOffset: 65)
                FloatingSourceTile(icon: "folder.fill", label: "Files", xOffset: 125, yOffset: 65)
            }
            .frame(height: 280)

            Spacer()
        }
        .padding(.horizontal, 16)
    }

    // MARK: - Screen 2: Share Sheet Composition + Sitting Mascot

    private var page2: some View {
        VStack(spacing: 0) {
            header(
                title: "Share. PDF It. Done.",
                subtitle: "Use the share sheet. We'll handle the rest."
            )

            Spacer()

            ZStack(alignment: .top) {
                // Stylized iOS Share Sheet Panel
                VStack(spacing: 12) {
                    // App Row
                    HStack(spacing: 14) {
                        ShareAppIcon(name: "AirDrop", icon: "paperplane.fill", color: .blue)
                        ShareAppIcon(name: "Messages", icon: "message.fill", color: .green)
                        ShareAppIcon(name: "Mail", icon: "envelope.fill", color: .cyan)
                        ShareAppIcon(name: "Notes", icon: "note.text", color: .orange)
                    }
                    .padding(.top, 38) // Room for mascot sitting on top

                    Divider()
                        .background(Color.white.opacity(0.1))
                        .padding(.vertical, 2)

                    // PDF It Highlighted Action Row
                    HStack {
                        ZStack {
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(Theme.Colors.orangeGradient)
                                .frame(width: 32, height: 32)
                            Image(systemName: "doc.fill")
                                .font(.system(size: 16, weight: .bold))
                                .foregroundStyle(.white)
                        }

                        Text("PDF It")
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(.white)

                        Spacer()

                        HStack(spacing: 4) {
                            Text("PDF")
                                .font(.system(size: 11, weight: .bold))
                            Image(systemName: "arrow.right")
                                .font(.system(size: 10, weight: .bold))
                        }
                        .foregroundStyle(Theme.Colors.orangePrimary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(Theme.Colors.orangePrimary.opacity(0.15), in: Capsule())
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(Color.white.opacity(0.06))
                            .overlay(
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .strokeBorder(Theme.Colors.orangePrimary.opacity(0.4), lineWidth: 1)
                            )
                    )
                }
                .padding(16)
                .frame(maxWidth: 320)
                .background(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .fill(Theme.Colors.darkCard)
                        .overlay(
                            RoundedRectangle(cornerRadius: 22, style: .continuous)
                                .strokeBorder(Color.white.opacity(0.1), lineWidth: 1)
                        )
                        .shadow(color: Color.black.opacity(0.4), radius: 16, y: 8)
                )
                .padding(.top, 40) // Push panel down so mascot rests on its top edge

                // Mascot Sitting on the Share Sheet edge
                MascotView(type: .onboarding2, size: 145, enableFloatingAnimation: false)
                    .offset(y: -30)
            }
            .frame(height: 290)

            Spacer()
        }
        .padding(.horizontal, 16)
    }

    // MARK: - Screen 3: Private & Local + Floating Shield Glow

    private var page3: some View {
        VStack(spacing: 0) {
            header(
                title: "Private & Local",
                subtitle: "No uploads. No account. Everything stays on your device."
            )

            Spacer()

            ZStack {
                // Soft radial security aura
                RadialGradient(
                    colors: [Theme.Colors.orangePrimary.opacity(0.22), Color.clear],
                    center: .center,
                    startRadius: 20,
                    endRadius: 170
                )
                .frame(width: 320, height: 320)

                // Glowing Security Shield Vector behind Mascot
                Image(systemName: "lock.shield.fill")
                    .font(.system(size: 140))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [Theme.Colors.orangeLight.opacity(0.4), Theme.Colors.orangeDark.opacity(0.15)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .shadow(color: Theme.Colors.orangePrimary.opacity(0.3), radius: 20)
                    .offset(y: -10)

                // Mascot Holding PDF
                MascotView(type: .onboarding3, size: 195)
            }
            .frame(height: 280)

            Spacer()
        }
        .padding(.horizontal, 16)
    }

    // MARK: - Header Helper

    private func header(title: String, subtitle: String) -> some View {
        VStack(spacing: 10) {
            Text(title)
                .font(.system(size: 32, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
                .accessibilityAddTraits(.isHeader)

            Text(subtitle)
                .font(.subheadline)
                .foregroundStyle(Color.white.opacity(0.7))
                .multilineTextAlignment(.center)
                .lineSpacing(3)
                .padding(.horizontal, 32)
        }
        .padding(.top, 24)
    }
}

// MARK: - Floating Source Tile (Screen 1)

private struct FloatingSourceTile: View {
    let icon: String
    let label: String
    let xOffset: CGFloat
    let yOffset: CGFloat

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(Theme.Colors.orangePrimary)
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            Capsule()
                .fill(Theme.Colors.darkCardSecondary.opacity(0.92))
                .overlay(
                    Capsule()
                        .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
                )
                .shadow(color: Theme.Colors.orangePrimary.opacity(0.2), radius: 8, y: 3)
        )
        .offset(x: xOffset, y: yOffset)
    }
}

// MARK: - Share App Icon (Screen 2)

private struct ShareAppIcon: View {
    let name: String
    let icon: String
    let color: Color

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(color.opacity(0.2))
                    .frame(width: 44, height: 44)
                Image(systemName: icon)
                    .font(.system(size: 20))
                    .foregroundStyle(color)
            }
            Text(name)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(Color.white.opacity(0.7))
        }
    }
}
