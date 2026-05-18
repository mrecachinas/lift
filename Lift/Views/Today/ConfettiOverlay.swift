import SwiftUI

/// A decorative confetti overlay driven by a trigger counter. Increment the
/// `trigger` value to fire off a new burst. Honors Reduce Motion by no-op'ing.
///
/// Implemented with `Canvas` + `TimelineView` so it stays a single
/// Metal-backed redraw rather than spawning N SwiftUI views per particle.
struct ConfettiOverlay: View {
    let trigger: Int

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var bursts: [Burst] = []

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: bursts.isEmpty)) { context in
            Canvas(opaque: false) { ctx, size in
                let now = context.date
                for burst in bursts {
                    draw(burst: burst, at: now, in: ctx, size: size)
                }
            }
            .accessibilityHidden(true)
        }
        .allowsHitTesting(false)
        .onChange(of: trigger) { _, _ in
            spawnBurst()
        }
    }

    private func spawnBurst() {
        guard !reduceMotion else { return }
        let burst = Burst.makeRandom()
        bursts.append(burst)
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(burst.duration + 0.5))
            bursts.removeAll { Date().timeIntervalSince($0.startDate) > $0.duration }
        }
    }

    private func draw(burst: Burst, at now: Date, in ctx: GraphicsContext, size: CGSize) {
        let elapsed = now.timeIntervalSince(burst.startDate)
        guard elapsed >= 0, elapsed < burst.duration else { return }

        let progress = elapsed / burst.duration
        let fadeStart = 0.7
        let opacity: Double = progress < fadeStart
            ? 1.0
            : max(0.0, 1.0 - (progress - fadeStart) / (1.0 - fadeStart))

        let gravity: CGFloat = 1100
        let drag: CGFloat = 0.92

        for particle in burst.particles {
            let t = CGFloat(elapsed)
            let dragFactor = pow(drag, t * 4)
            let dx = particle.velocity.dx * t * dragFactor
            let dy = particle.velocity.dy * t + 0.5 * gravity * t * t
            let x = particle.origin.x * size.width + dx
            let y = particle.origin.y * size.height + dy

            let rotation = particle.initialRotation + particle.rotationSpeed * elapsed
            let rect = CGRect(
                x: -particle.size.width / 2,
                y: -particle.size.height / 2,
                width: particle.size.width,
                height: particle.size.height
            )

            var local = ctx
            local.opacity = opacity
            local.translateBy(x: x, y: y)
            local.rotate(by: .degrees(rotation))

            switch particle.shape {
            case .rect:
                local.fill(Path(rect), with: .color(particle.color))
            case .circle:
                local.fill(Path(ellipseIn: rect), with: .color(particle.color))
            }
        }
    }
}

private struct Burst {
    let particles: [Particle]
    let startDate: Date
    let duration: TimeInterval

    static func makeRandom() -> Burst {
        let palette: [Color] = [
            LiftTheme.accent,
            LiftTheme.success,
            LiftTheme.warning,
            Color(red: 0.45, green: 0.85, blue: 0.95),
            Color(red: 0.96, green: 0.96, blue: 0.96)
        ]
        let particles = (0..<140).map { _ in Particle.random(palette: palette) }
        return Burst(particles: particles, startDate: .now, duration: 3.5)
    }
}

private struct Particle {
    enum Shape { case rect, circle }

    let origin: CGPoint
    let velocity: CGVector
    let initialRotation: Double
    let rotationSpeed: Double
    let color: Color
    let size: CGSize
    let shape: Shape

    static func random(palette: [Color]) -> Particle {
        Particle(
            origin: CGPoint(
                x: Double.random(in: 0.15...0.85),
                y: Double.random(in: 0.30...0.55)
            ),
            velocity: CGVector(
                dx: Double.random(in: -420...420),
                dy: Double.random(in: -820 ... -360)
            ),
            initialRotation: Double.random(in: 0...360),
            rotationSpeed: Double.random(in: -540...540),
            color: palette.randomElement() ?? .white,
            size: CGSize(
                width: Double.random(in: 6...12),
                height: Double.random(in: 9...18)
            ),
            shape: Bool.random() ? .rect : .circle
        )
    }
}

#Preview {
    struct PreviewHost: View {
        @State private var trigger = 0
        var body: some View {
            ZStack {
                LiftTheme.canvas.ignoresSafeArea()
                Button("Pop") { trigger += 1 }
                    .buttonStyle(.borderedProminent)
                ConfettiOverlay(trigger: trigger)
                    .ignoresSafeArea()
            }
        }
    }
    return PreviewHost()
}
