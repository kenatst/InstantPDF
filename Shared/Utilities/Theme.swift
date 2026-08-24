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

    enum Spacing {
        static let xxs: CGFloat = 4
        static let xs: CGFloat = 8
        static let sm: CGFloat = 12
        static let md: CGFloat = 16
        static let lg: CGFloat = 20
        static let xl: CGFloat = 24
        static let xxl: CGFloat = 32
    }

    enum Radius {
        static let control: CGFloat = 12
        static let card: CGFloat = 16
        static let feature: CGFloat = 20
        static let hero: CGFloat = 24
    }

    enum Colors {
        static let orangePrimary = Color(hex: "FF7A1A")
        static let orangeLight = Color(hex: "FFA351")
        static let orangeDark = Color(hex: "C94700")
        static let amber = Color(hex: "FFB02E")

        static let warmBackground = Color(hex: "F7F3ED")
        static let warmBackgroundRaised = Color(hex: "FCF9F5")
        static let surface = Color(hex: "FFFDFC")
        static let surfaceMuted = Color(hex: "F1ECE5")
        static let ink = Color(hex: "1E1815")
        static let inkSecondary = Color(hex: "766D66")
        static let stroke = Color(hex: "DED5CB")
        
        static let orangeGradient = LinearGradient(
            colors: [Color(hex: "FF963D"), Color(hex: "E95708")],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )

        static let heroCardGradient = LinearGradient(
            colors: [Color(hex: "FF9A3D"), Color(hex: "F16A16"), Color(hex: "D94A00")],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )

        static let darkBackground = Color(hex: "12100F")
        static let darkCard = Color(hex: "1D1A18")
        static let darkCardSecondary = Color(hex: "29231F")
        static let darkStroke = Color(hex: "403832")
        
        static let glow = Color(hex: "FF7A1A").opacity(0.25)
    }

    // Dynamic background for Light & Dark mode
    struct BackgroundModifier: ViewModifier {
        @Environment(\.colorScheme) private var colorScheme

        func body(content: Content) -> some View {
            content.background {
                ZStack {
                    (colorScheme == .dark ? Colors.darkBackground : Colors.warmBackground)
                        .ignoresSafeArea()
                    RadialGradient(
                        colors: [
                            Colors.orangePrimary.opacity(colorScheme == .dark ? 0.075 : 0.055),
                            .clear
                        ],
                        center: .topTrailing,
                        startRadius: 0,
                        endRadius: 360
                    )
                    .ignoresSafeArea()
                }
            }
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
                            isSelected ? Colors.orangePrimary : (colorScheme == .dark ? Colors.darkStroke : Colors.stroke.opacity(0.72)),
                                    lineWidth: isSelected ? 2 : 1
                                )
                        )
                        .shadow(
                            color: isSelected ? Colors.glow : (colorScheme == .dark ? Color.black.opacity(0.34) : Color(hex: "6F4D35").opacity(0.075)),
                            radius: isSelected ? 12 : 14,
                            x: 0,
                            y: isSelected ? 4 : 2
                        )
                )
        }
    }

    // Primary CTA Button Style
    struct PrimaryButtonStyle: ButtonStyle {
        @Environment(\.isEnabled) private var isEnabled
        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        func makeBody(configuration: Configuration) -> some View {
            configuration.label
                .font(.headline.weight(.bold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .frame(minHeight: 54)
                .contentShape(Rectangle())
                .background(
                    RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                        .fill(isEnabled ? Colors.orangeGradient : LinearGradient(colors: [Color.gray.opacity(0.5)], startPoint: .top, endPoint: .bottom))
                        .overlay(alignment: .top) {
                            RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                                .strokeBorder(Color.white.opacity(isEnabled ? 0.24 : 0), lineWidth: 1)
                        }
                        .shadow(color: isEnabled ? Colors.orangeDark.opacity(0.25) : Color.clear, radius: 10, x: 0, y: 6)
                )
                .scaleEffect(configuration.isPressed && !reduceMotion ? 0.975 : 1.0)
                .opacity(isEnabled ? 1.0 : 0.6)
                .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
        }
    }

    // Secondary Outline Button Style
    struct SecondaryButtonStyle: ButtonStyle {
        @Environment(\.colorScheme) private var colorScheme
        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        func makeBody(configuration: Configuration) -> some View {
            configuration.label
                .font(.subheadline.weight(.medium))
                .foregroundStyle(colorScheme == .dark ? Color.white : Color(hex: "111215"))
                .frame(maxWidth: .infinity)
                .frame(minHeight: 50)
                .contentShape(Rectangle())
                .background(
                    RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                        .fill(colorScheme == .dark ? Colors.darkCardSecondary : Colors.surfaceMuted)
                        .overlay(
                            RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                                .strokeBorder(colorScheme == .dark ? Colors.darkStroke : Colors.stroke.opacity(0.85), lineWidth: 1)
                        )
                )
                .scaleEffect(configuration.isPressed && !reduceMotion ? 0.98 : 1.0)
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

// MARK: - Transparent Living Mascot View (No Clipping, Organic Shadow)

struct MascotView: View {
    enum MascotType {
        case hero
        case photos
        case link
        case text
        case files
        case library
        case scan
        case onboarding1
        case onboarding2
        case onboarding3
        case success
        case error
        case crown
        case pro
        
        var assetName: String {
            switch self {
            case .hero: return "MascotHeroPremium"
            case .photos: return "MascotPhotos"
            case .link: return "MascotLink"
            case .text: return "MascotText"
            case .files: return "MascotFiles"
            case .library: return "MascotLibrary"
            case .scan: return "MascotScan"
            case .onboarding1: return "MascotOnboarding1"
            case .onboarding2: return "MascotOnboarding2"
            case .onboarding3: return "MascotOnboarding3"
            case .success, .crown, .pro: return "MascotCrown"
            case .error: return "MascotError"
            }
        }
    }

    let type: MascotType
    var size: CGFloat = 180
    var enableFloatingAnimation: Bool = true
    
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
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
                Image(systemName: "cloud.fill")
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(Theme.Colors.orangePrimary)
            }
        }
        .frame(width: size, height: size)
        .shadow(color: Color.black.opacity(0.09), radius: 13, x: 0, y: 7)
        .offset(y: (!reduceMotion && enableFloatingAnimation && isFloating) ? -4 : 0)
        .onAppear {
            if !reduceMotion && enableFloatingAnimation {
                withAnimation(
                    .easeInOut(duration: 2.8)
                    .repeatForever(autoreverses: true)
                ) {
                    isFloating = true
                }
            }
        }
    }
}

// MARK: - Spark Particle Effect for Success State

struct AmberSparkParticles: View {
    @State private var animate = false

    var body: some View {
        ZStack {
            ForEach(0..<12) { i in
                let angle = Double(i) * (360.0 / 12.0)
                let radius: CGFloat = (i % 2 == 0) ? 80 : 105
                Circle()
                    .fill(i % 3 == 0 ? Color.white : Theme.Colors.orangeLight)
                    .frame(width: (i % 3 == 0) ? 5 : 4, height: (i % 3 == 0) ? 5 : 4)
                    .offset(
                        x: cos(angle * .pi / 180) * (animate ? radius : radius * 0.4),
                        y: sin(angle * .pi / 180) * (animate ? radius : radius * 0.4)
                    )
                    .opacity(animate ? 0.85 : 0.2)
                    .scaleEffect(animate ? 1.0 : 0.4)
            }
        }
        .onAppear {
            withAnimation(.easeOut(duration: 1.2).repeatForever(autoreverses: true)) {
                animate = true
            }
        }
    }
}
