import SwiftUI
import UIKit

// MARK: - Color Hex Initializer

extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch hex.count {
        case 3: // RGB (12-bit)
            (a, r, g, b) = (255, (int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6: // RGB (24-bit)
            (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8: // ARGB (32-bit)
            (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default:
            (a, r, g, b) = (255, 0, 0, 0)
        }
        self.init(
            .sRGB,
            red: Double(r) / 255,
            green: Double(g) / 255,
            blue: Double(b) / 255,
            opacity: Double(a) / 255
        )
    }
}

// MARK: - Theme System

enum Theme {

    enum Colors {
        static let orangePrimary = Color(hex: "FF7A1A")
        static let orangeLight = Color(hex: "FF9538")
        static let orangeDark = Color(hex: "E05A00")
        
        static let orangeGradient = LinearGradient(
            colors: [Color(hex: "FF8A28"), Color(hex: "E85800")],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )

        static let heroCardGradient = LinearGradient(
            colors: [Color(hex: "FF8526"), Color(hex: "E55400")],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )

        static let darkBackground = Color(hex: "0D0E12")
        static let darkCard = Color(hex: "18191E")
        static let darkCardSecondary = Color(hex: "22242B")
        
        static let glow = Color(hex: "FF7A1A").opacity(0.3)
    }

    // Dynamic background for Light & Dark mode
    struct BackgroundModifier: ViewModifier {
        @Environment(\.colorScheme) private var colorScheme

        func body(content: Content) -> some View {
            content
                .background(
                    (colorScheme == .dark ? Colors.darkBackground : Color(hex: "F7F8FA"))
                        .ignoresSafeArea()
                )
        }
    }

    // Dynamic card style
    struct CardModifier: ViewModifier {
        @Environment(\.colorScheme) private var colorScheme
        var isSelected: Bool = false
        var padding: CGFloat = 16
        var cornerRadius: CGFloat = 20

        func body(content: Content) -> some View {
            content
                .padding(padding)
                .background(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(colorScheme == .dark ? Colors.darkCard : Color.white)
                        .overlay(
                            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                                .strokeBorder(
                                    isSelected ? Colors.orangePrimary : (colorScheme == .dark ? Color.white.opacity(0.08) : Color.black.opacity(0.06)),
                                    lineWidth: isSelected ? 2 : 1
                                )
                        )
                        .shadow(
                            color: isSelected ? Colors.glow : (colorScheme == .dark ? Color.black.opacity(0.3) : Color.black.opacity(0.04)),
                            radius: isSelected ? 12 : 8,
                            x: 0,
                            y: isSelected ? 4 : 2
                        )
                )
        }
    }

    // Primary CTA Button Style
    struct PrimaryButtonStyle: ButtonStyle {
        @Environment(\.isEnabled) private var isEnabled

        func makeBody(configuration: Configuration) -> some View {
            configuration.label
                .font(.headline.weight(.semibold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .background(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(isEnabled ? Colors.orangeGradient : LinearGradient(colors: [Color.gray.opacity(0.5)], startPoint: .top, endPoint: .bottom))
                        .shadow(color: isEnabled ? Colors.orangePrimary.opacity(0.35) : Color.clear, radius: 10, x: 0, y: 5)
                )
                .scaleEffect(configuration.isPressed ? 0.98 : 1.0)
                .opacity(isEnabled ? 1.0 : 0.6)
                .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
        }
    }

    // Secondary Outline Button Style
    struct SecondaryButtonStyle: ButtonStyle {
        @Environment(\.colorScheme) private var colorScheme

        func makeBody(configuration: Configuration) -> some View {
            configuration.label
                .font(.subheadline.weight(.medium))
                .foregroundStyle(colorScheme == .dark ? Color.white : Color(hex: "111215"))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(colorScheme == .dark ? Colors.darkCardSecondary : Color(hex: "EAECEF"))
                        .overlay(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .strokeBorder(colorScheme == .dark ? Color.white.opacity(0.1) : Color.black.opacity(0.05), lineWidth: 1)
                        )
                )
                .scaleEffect(configuration.isPressed ? 0.98 : 1.0)
                .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
        }
    }
}

// MARK: - View Modifiers Extension

extension View {
    func themeBackground() -> some View {
        modifier(Theme.BackgroundModifier())
    }

    func premiumCard(isSelected: Bool = false, padding: CGFloat = 16, cornerRadius: CGFloat = 20) -> some View {
        modifier(Theme.CardModifier(isSelected: isSelected, padding: padding, cornerRadius: cornerRadius))
    }

    func primaryOrangeButton() -> some View {
        buttonStyle(Theme.PrimaryButtonStyle())
    }

    func secondaryDarkButton() -> some View {
        buttonStyle(Theme.SecondaryButtonStyle())
    }
}

// MARK: - Animated Mascot View

struct MascotView: View {
    enum MascotType {
        case hero
        case onboarding1
        case onboarding2
        case onboarding3
        case success
        case error
        
        var assetName: String {
            switch self {
            case .hero: return "MascotHero"
            case .onboarding1: return "MascotOnboarding1"
            case .onboarding2: return "MascotOnboarding2"
            case .onboarding3: return "MascotOnboarding3"
            case .success: return "MascotSuccess"
            case .error: return "MascotError"
            }
        }
    }

    let type: MascotType
    var size: CGFloat = 180
    var enableFloatingAnimation: Bool = true
    
    @State private var isFloating = false

    private var image: UIImage? {
        if let img = UIImage(named: type.assetName) { return img }
        if let img = UIImage(named: type.assetName, in: Bundle.main, with: nil) { return img }
        for bundle in Bundle.allBundles {
            if let img = UIImage(named: type.assetName, in: bundle, with: nil) { return img }
        }
        return nil
    }

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
            } else {
                Image(systemName: "cloud.sun.fill")
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(Theme.Colors.orangePrimary)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.2, style: .continuous))
        .shadow(color: Theme.Colors.orangePrimary.opacity(0.3), radius: 16, x: 0, y: 8)
        .offset(y: (enableFloatingAnimation && isFloating) ? -6 : 0)
        .onAppear {
            if enableFloatingAnimation {
                withAnimation(
                    .easeInOut(duration: 2.2)
                    .repeatForever(autoreverses: true)
                ) {
                    isFloating = true
                }
            }
        }
    }
}
