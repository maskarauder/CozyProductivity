import SwiftUI

enum CozyTheme {
    // MARK: - Core Pastel Pink Surfaces
    static let canvasTop = Color(red: 1.00, green: 0.95, blue: 0.97)       // #FFF2F7
    static let canvasMiddle = Color(red: 1.00, green: 0.97, blue: 0.98)    // #FFF7FA
    static let canvasBottom = Color(red: 0.98, green: 0.95, blue: 0.99)    // #FAF2FC

    static let cardBackground = Color.white.opacity(0.92)
    static let completedCardBackground = Color(red: 0.99, green: 0.94, blue: 0.96).opacity(0.82)
    static let softBlushFill = Color(red: 0.99, green: 0.89, blue: 0.93)   // #FCE3ED
    static let petalPill = Color(red: 0.98, green: 0.84, blue: 0.90)       // #FAD6E5
    static let cardBorder = Color(red: 0.96, green: 0.80, blue: 0.87)      // #F5CCDE

    // MARK: - Rose & Berry Accents
    static let roseAccent = Color(red: 0.91, green: 0.48, blue: 0.65)      // #E87AA6
    static let deepRose = Color(red: 0.72, green: 0.34, blue: 0.50)        // #B85780
    static let coralBlush = Color(red: 0.95, green: 0.62, blue: 0.67)      // #F29EAB

    // MARK: - Calm Typography Colors
    static let inkPrimary = Color(red: 0.30, green: 0.20, blue: 0.25)      // #4D3340
    static let inkSecondary = Color(red: 0.55, green: 0.42, blue: 0.49)    // #8C6B7D
    static let inkMuted = Color(red: 0.70, green: 0.58, blue: 0.64)        // #B394A3

    // MARK: - Gentle Supporting Pastels
    static let pastelPeach = Color(red: 1.00, green: 0.86, blue: 0.80)     // #FFDBCC
    static let pastelPeachInk = Color(red: 0.75, green: 0.42, blue: 0.32)
    static let pastelLavender = Color(red: 0.91, green: 0.86, blue: 0.98)  // #E8DCFA
    static let pastelLavenderInk = Color(red: 0.48, green: 0.38, blue: 0.66)
    static let pastelMint = Color(red: 0.85, green: 0.95, blue: 0.90)      // #D9F2E6
    static let pastelMintInk = Color(red: 0.28, green: 0.55, blue: 0.44)
    static let pastelButter = Color(red: 1.00, green: 0.94, blue: 0.78)    // #FFF0C7
    static let pastelButterInk = Color(red: 0.66, green: 0.50, blue: 0.20)
    static let pastelSky = Color(red: 0.86, green: 0.93, blue: 0.99)       // #DCF0FC
    static let pastelSkyInk = Color(red: 0.31, green: 0.50, blue: 0.68)

    // MARK: - Gradients
    static let backgroundGradient = LinearGradient(
        colors: [canvasTop, canvasMiddle, canvasBottom],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    static let primaryButtonGradient = LinearGradient(
        colors: [
            Color(red: 0.94, green: 0.55, blue: 0.70),
            Color(red: 0.88, green: 0.44, blue: 0.62)
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    static let headerCardGradient = LinearGradient(
        colors: [
            Color(red: 1.00, green: 0.91, blue: 0.95),
            Color(red: 0.98, green: 0.86, blue: 0.92)
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    // MARK: - Confetti Palette
    static let confettiColors: [Color] = [
        Color(red: 0.95, green: 0.52, blue: 0.69), // Strawberry pink
        Color(red: 0.99, green: 0.73, blue: 0.83), // Cotton candy pink
        Color(red: 1.00, green: 0.80, blue: 0.73), // Pastel peach
        Color(red: 0.87, green: 0.79, blue: 0.98), // Soft lavender
        Color(red: 0.78, green: 0.93, blue: 0.86), // Mint leaf
        Color(red: 1.00, green: 0.90, blue: 0.66), // Honey butter
        Color(red: 0.93, green: 0.39, blue: 0.59)  // Rosebud
    ]
}

struct CozyCardModifier: ViewModifier {
    var isCompleted: Bool = false
    var cornerRadius: CGFloat = 22

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(isCompleted ? CozyTheme.completedCardBackground : CozyTheme.cardBackground)
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(
                        isCompleted ? CozyTheme.cardBorder.opacity(0.45) : CozyTheme.cardBorder.opacity(0.85),
                        lineWidth: 1
                    )
            )
            .shadow(
                color: CozyTheme.roseAccent.opacity(isCompleted ? 0.04 : 0.10),
                radius: isCompleted ? 6 : 14,
                x: 0,
                y: isCompleted ? 2 : 6
            )
    }
}

extension View {
    func cozyCard(isCompleted: Bool = false, cornerRadius: CGFloat = 22) -> some View {
        modifier(CozyCardModifier(isCompleted: isCompleted, cornerRadius: cornerRadius))
    }

    func cozyScreenBackground() -> some View {
        background(
            ZStack {
                CozyTheme.backgroundGradient
                Circle()
                    .fill(CozyTheme.petalPill.opacity(0.45))
                    .frame(width: 280, height: 280)
                    .blur(radius: 60)
                    .offset(x: 130, y: -240)
                Circle()
                    .fill(CozyTheme.pastelLavender.opacity(0.40))
                    .frame(width: 260, height: 260)
                    .blur(radius: 65)
                    .offset(x: -140, y: 260)
            }
            .ignoresSafeArea()
        )
    }
}
