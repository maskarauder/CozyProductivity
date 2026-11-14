import Observation
import SwiftUI

@MainActor
@Observable
final class CelebrationController {
    struct Particle: Identifiable {
        enum ShapeKind: CaseIterable {
            case heart
            case petal
            case ribbon
            case sparkle
        }

        let id = UUID()
        let createdAt: TimeInterval
        let lifetime: TimeInterval
        let originXFraction: CGFloat
        let originYFraction: CGFloat
        let velocityX: CGFloat
        let velocityY: CGFloat
        let size: CGFloat
        let color: Color
        let shape: ShapeKind
        let baseRotation: Double
        let rotationSpeed: Double
        let flipSpeed: Double
        let swayAmplitude: CGFloat
        let swayFrequency: Double
    }

    struct PerfectOverlayState: Equatable {
        let streakDays: Int
        let id = UUID()
    }

    private(set) var particles: [Particle] = []
    private(set) var bannerMessage: String?
    private(set) var perfectOverlay: PerfectOverlayState?
    private(set) var hapticCounter: Int = 0
    private var dismissBannerTask: Task<Void, Never>?

    private static let cheers = [
        "Lovely job! 🌸",
        "One step lighter ✨",
        "So proud of you 💖",
        "Sweet progress 🌷",
        "Checked off with care 🎀",
        "Little wins add up 💕"
    ]

    func celebrate(taskTitle: String, allDoneForToday: Bool) {
        hapticCounter += 1
        spawnParticles(
            count: allDoneForToday ? 115 : 72,
            palette: CozyTheme.confettiColors,
            speedRange: allDoneForToday ? 460...860 : 380...740,
            staggerWindow: 0.14,
            wideSpread: allDoneForToday
        )

        perfectOverlay = nil
        if allDoneForToday {
            bannerMessage = "🌸 All daily tasks complete! 2 bonus tasks unlocked ✨"
        } else {
            let prefix = Self.cheers.randomElement() ?? "Lovely job! 🌸"
            bannerMessage = "\(prefix)  ·  \(taskTitle)"
        }
        scheduleDismiss(after: 2.9)
    }

    func celebrateSilver(taskTitle: String, streakDays: Int) {
        hapticCounter += 1
        spawnParticles(
            count: 130,
            palette: CozyTheme.silverConfettiColors,
            speedRange: 440...840,
            staggerWindow: 0.18,
            wideSpread: true
        )

        perfectOverlay = nil
        bannerMessage = "🥈 Silver Day! Streak preserved (\(streakDays)d) · 1 more for Gold!"
        scheduleDismiss(after: 3.1)
    }

    func celebrateGoldPerfect(streakDays: Int) {
        hapticCounter += 1
        // Massive multi-wave golden + pastel pink confetti barrage!
        spawnParticles(
            count: 240,
            palette: CozyTheme.goldConfettiColors,
            speedRange: 500...1020,
            staggerWindow: 0.55,
            wideSpread: true
        )

        bannerMessage = nil
        withAnimation(.spring(response: 0.42, dampingFraction: 0.68)) {
            perfectOverlay = PerfectOverlayState(streakDays: streakDays)
        }
        scheduleDismiss(after: 3.6)
    }

    private func spawnParticles(
        count: Int,
        palette: [Color],
        speedRange: ClosedRange<CGFloat>,
        staggerWindow: Double,
        wideSpread: Bool
    ) {
        let now = Date.timeIntervalSinceReferenceDate
        var newParticles: [Particle] = []
        newParticles.reserveCapacity(count)

        for index in 0..<count {
            let lane = index % 3
            let originX: CGFloat
            if wideSpread {
                switch lane {
                case 0: originX = CGFloat.random(in: 0.08...0.34)
                case 1: originX = CGFloat.random(in: 0.36...0.64)
                default: originX = CGFloat.random(in: 0.66...0.92)
                }
            } else {
                originX = CGFloat.random(in: 0.25...0.75)
            }
            let originY: CGFloat = CGFloat.random(in: 0.44...0.68)

            let angle = Double.random(in: (-Double.pi * 0.86)...(-Double.pi * 0.14))
            let speed = CGFloat.random(in: speedRange)
            let shape = Particle.ShapeKind.allCases.randomElement() ?? .petal
            let color = palette.randomElement() ?? CozyTheme.roseAccent

            newParticles.append(
                Particle(
                    createdAt: now + Double.random(in: 0...staggerWindow),
                    lifetime: Double.random(in: 2.2...3.5),
                    originXFraction: originX,
                    originYFraction: originY,
                    velocityX: CGFloat(cos(angle)) * speed,
                    velocityY: CGFloat(sin(angle)) * speed,
                    size: CGFloat.random(in: 8...16),
                    color: color,
                    shape: shape,
                    baseRotation: Double.random(in: 0...(Double.pi * 2)),
                    rotationSpeed: Double.random(in: -5.8...5.8),
                    flipSpeed: Double.random(in: 4.0...10.5),
                    swayAmplitude: CGFloat.random(in: 12...36),
                    swayFrequency: Double.random(in: 2.2...4.8)
                )
            )
        }

        particles = particles.filter { (now - $0.createdAt) < $0.lifetime } + newParticles
    }

    private func scheduleDismiss(after seconds: Double) {
        dismissBannerTask?.cancel()
        dismissBannerTask = Task {
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            withAnimation(.spring(response: 0.45, dampingFraction: 0.82)) {
                bannerMessage = nil
                perfectOverlay = nil
            }
            let cleanupTime = Date.timeIntervalSinceReferenceDate
            particles.removeAll { (cleanupTime - $0.createdAt) >= $0.lifetime }
        }
    }
}

struct ConfettiCelebrationOverlay: View {
    var controller: CelebrationController

    var body: some View {
        ZStack {
            if !controller.particles.isEmpty {
                TimelineView(.animation) { timeline in
                    let now = timeline.date.timeIntervalSinceReferenceDate
                    Canvas { context, size in
                        for particle in controller.particles {
                            let age = now - particle.createdAt
                            guard age >= 0 && age < particle.lifetime else { continue }

                            let progress = age / particle.lifetime
                            let gravity: CGFloat = 560
                            let drag = max(0.35, 1.0 - CGFloat(age) * 0.22)

                            let baseX = particle.originXFraction * size.width
                                + particle.velocityX * CGFloat(age) * drag
                                + sin(CGFloat(age * particle.swayFrequency)) * particle.swayAmplitude
                            let baseY = particle.originYFraction * size.height
                                + particle.velocityY * CGFloat(age)
                                + 0.5 * gravity * CGFloat(age * age)

                            let fadeOpacity = progress > 0.72
                                ? max(0, (1.0 - progress) / 0.28)
                                : 1.0

                            var copy = context
                            copy.opacity = fadeOpacity
                            copy.translateBy(x: baseX, y: baseY)
                            copy.rotate(by: .radians(particle.baseRotation + age * particle.rotationSpeed))
                            let flipScale = max(0.22, abs(cos(age * particle.flipSpeed)))
                            copy.scaleBy(x: CGFloat(flipScale), y: 1.0)

                            let s = particle.size
                            let path = Self.path(for: particle.shape, size: s)
                            copy.fill(path, with: .color(particle.color))
                        }
                    }
                }
                .ignoresSafeArea()
            }

            // Top Toast Pill for Regular / Bronze / Silver Completions
            VStack {
                if let message = controller.bannerMessage {
                    HStack(spacing: 8) {
                        Image(systemName: "sparkles")
                            .foregroundStyle(CozyTheme.roseAccent)
                        Text(message)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(CozyTheme.inkPrimary)
                            .lineLimit(2)
                            .multilineTextAlignment(.center)
                    }
                    .padding(.horizontal, 18)
                    .padding(.vertical, 12)
                    .background(
                        Capsule(style: .continuous)
                            .fill(Color.white.opacity(0.96))
                            .shadow(color: CozyTheme.roseAccent.opacity(0.24), radius: 16, x: 0, y: 6)
                    )
                    .overlay(
                        Capsule(style: .continuous)
                            .strokeBorder(CozyTheme.cardBorder, lineWidth: 1.2)
                    )
                    .padding(.horizontal, 20)
                    .padding(.top, 12)
                    .transition(.move(edge: .top).combined(with: .opacity))
                }
                Spacer()
            }

            // Centerpiece Gold "PERFECT" + "Streak Days X" Hero Celebration
            if let perfect = controller.perfectOverlay {
                VStack(spacing: 8) {
                    HStack(spacing: 6) {
                        Image(systemName: "sparkles")
                            .font(.title3.weight(.bold))
                            .foregroundStyle(CozyTheme.goldBorder)
                        Text("🥇")
                            .font(.system(size: 32))
                        Image(systemName: "sparkles")
                            .font(.title3.weight(.bold))
                            .foregroundStyle(CozyTheme.roseAccent)
                    }

                    Text("PERFECT")
                        .font(.system(size: 46, weight: .black, design: .rounded))
                        .tracking(2)
                        .foregroundStyle(CozyTheme.perfectTitleGradient)
                        .shadow(color: CozyTheme.goldBorder.opacity(0.28), radius: 8, x: 0, y: 3)

                    Text("Streak Days \(perfect.streakDays)")
                        .font(.system(.headline, design: .rounded, weight: .bold))
                        .foregroundStyle(CozyTheme.goldInk)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 6)
                        .background(
                            Capsule(style: .continuous)
                                .fill(CozyTheme.goldGradient)
                        )
                        .overlay(
                            Capsule(style: .continuous)
                                .strokeBorder(CozyTheme.goldBorder.opacity(0.65), lineWidth: 1)
                        )
                }
                .padding(.horizontal, 34)
                .padding(.vertical, 26)
                .background(
                    RoundedRectangle(cornerRadius: 32, style: .continuous)
                        .fill(Color.white.opacity(0.96))
                        .shadow(color: CozyTheme.goldBorder.opacity(0.32), radius: 26, x: 0, y: 12)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 32, style: .continuous)
                        .strokeBorder(CozyTheme.goldGradient, lineWidth: 2.5)
                )
                .padding(.horizontal, 28)
                .transition(.scale(scale: 0.72).combined(with: .opacity))
            }
        }
        .allowsHitTesting(false)
        .sensoryFeedback(.success, trigger: controller.hapticCounter)
        .animation(.spring(response: 0.4, dampingFraction: 0.76), value: controller.bannerMessage)
        .animation(.spring(response: 0.44, dampingFraction: 0.70), value: controller.perfectOverlay)
    }

    private static func path(for shape: CelebrationController.Particle.ShapeKind, size: CGFloat) -> Path {
        let half = size / 2
        switch shape {
        case .ribbon:
            return Path(
                roundedRect: CGRect(x: -half, y: -half * 0.55, width: size, height: size * 0.55),
                cornerRadius: 3
            )

        case .heart:
            var path = Path()
            let w = size
            let h = size
            path.move(to: CGPoint(x: 0, y: h * 0.38))
            path.addCurve(
                to: CGPoint(x: -w * 0.5, y: -h * 0.12),
                control1: CGPoint(x: -w * 0.15, y: h * 0.22),
                control2: CGPoint(x: -w * 0.5, y: h * 0.08)
            )
            path.addArc(
                center: CGPoint(x: -w * 0.25, y: -h * 0.15),
                radius: w * 0.25,
                startAngle: .degrees(180),
                endAngle: .degrees(0),
                clockwise: false
            )
            path.addArc(
                center: CGPoint(x: w * 0.25, y: -h * 0.15),
                radius: w * 0.25,
                startAngle: .degrees(180),
                endAngle: .degrees(0),
                clockwise: false
            )
            path.addCurve(
                to: CGPoint(x: 0, y: h * 0.38),
                control1: CGPoint(x: w * 0.5, y: h * 0.08),
                control2: CGPoint(x: w * 0.15, y: h * 0.22)
            )
            path.closeSubpath()
            return path

        case .petal:
            var path = Path()
            path.move(to: CGPoint(x: 0, y: -half))
            path.addQuadCurve(
                to: CGPoint(x: 0, y: half),
                control: CGPoint(x: half * 0.95, y: 0)
            )
            path.addQuadCurve(
                to: CGPoint(x: 0, y: -half),
                control: CGPoint(x: -half * 0.95, y: 0)
            )
            path.closeSubpath()
            return path

        case .sparkle:
            var path = Path()
            let inner = half * 0.32
            path.move(to: CGPoint(x: 0, y: -half))
            path.addLine(to: CGPoint(x: inner, y: -inner))
            path.addLine(to: CGPoint(x: half, y: 0))
            path.addLine(to: CGPoint(x: inner, y: inner))
            path.addLine(to: CGPoint(x: 0, y: half))
            path.addLine(to: CGPoint(x: -inner, y: inner))
            path.addLine(to: CGPoint(x: -half, y: 0))
            path.addLine(to: CGPoint(x: -inner, y: -inner))
            path.closeSubpath()
            return path
        }
    }
}
