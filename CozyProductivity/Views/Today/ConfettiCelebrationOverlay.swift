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

    private(set) var particles: [Particle] = []
    private(set) var bannerMessage: String?
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
        let now = Date.timeIntervalSinceReferenceDate
        let count = allDoneForToday ? 110 : 72

        var newParticles: [Particle] = []
        newParticles.reserveCapacity(count)

        for index in 0..<count {
            let fromLeft = index.isMultiple(of: 2)
            let originX: CGFloat = allDoneForToday
                ? (fromLeft ? CGFloat.random(in: 0.12...0.38) : CGFloat.random(in: 0.62...0.88))
                : CGFloat.random(in: 0.25...0.75)
            let originY: CGFloat = CGFloat.random(in: 0.42...0.62)

            let angle = Double.random(in: (-Double.pi * 0.84)...(-Double.pi * 0.16))
            let speed = CGFloat.random(in: allDoneForToday ? 460...860 : 380...740)

            let shape = Particle.ShapeKind.allCases.randomElement() ?? .petal
            let color = CozyTheme.confettiColors.randomElement() ?? CozyTheme.roseAccent

            newParticles.append(
                Particle(
                    createdAt: now + Double.random(in: 0...0.12),
                    lifetime: Double.random(in: 2.0...3.1),
                    originXFraction: originX,
                    originYFraction: originY,
                    velocityX: CGFloat(cos(angle)) * speed,
                    velocityY: CGFloat(sin(angle)) * speed,
                    size: CGFloat.random(in: 8...15),
                    color: color,
                    shape: shape,
                    baseRotation: Double.random(in: 0...(Double.pi * 2)),
                    rotationSpeed: Double.random(in: -5.5...5.5),
                    flipSpeed: Double.random(in: 4.0...10.0),
                    swayAmplitude: CGFloat.random(in: 12...34),
                    swayFrequency: Double.random(in: 2.2...4.8)
                )
            )
        }

        // Prune expired particles before appending
        particles = particles.filter { (now - $0.createdAt) < $0.lifetime } + newParticles

        if allDoneForToday {
            bannerMessage = "🎉 All done for today! Enjoy your cozy rest 💖"
        } else {
            let prefix = Self.cheers.randomElement() ?? "Lovely job! 🌸"
            bannerMessage = "\(prefix)  ·  \(taskTitle)"
        }

        dismissBannerTask?.cancel()
        dismissBannerTask = Task {
            try? await Task.sleep(for: .seconds(2.8))
            guard !Task.isCancelled else { return }
            withAnimation(.spring(response: 0.45, dampingFraction: 0.82)) {
                bannerMessage = nil
            }
            let cleanupTime = Date.timeIntervalSinceReferenceDate
            particles.removeAll { (cleanupTime - $0.createdAt) >= $0.lifetime }
        }
    }
}

struct ConfettiCelebrationOverlay: View {
    var controller: CelebrationController

    var body: some View {
        ZStack(alignment: .top) {
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
        }
        .allowsHitTesting(false)
        .sensoryFeedback(.success, trigger: controller.hapticCounter)
        .animation(.spring(response: 0.4, dampingFraction: 0.78), value: controller.bannerMessage)
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
