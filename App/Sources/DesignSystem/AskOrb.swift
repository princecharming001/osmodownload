import SwiftUI

// The "Ask Osmo" visual — an exact-style Siri orb clone (vendored from the same
// GetStream purposeful-ios-animations recreation used in Marque): hand-drawn
// organic petal assets layered over a dark glass sphere, each spinning at its
// own differential rate/direction with continuous hue cycling and 3D-tilted
// rotation planes. Replaces generic SF Symbol bullets ("sparkle", spinners)
// wherever Osmo visualizes the assistant thinking or answering.
//
// MOTION: idle breathes slowly; .thinking holds a brisk steady swirl (Osmo has
// no voice capture, so .listening is unused for now but kept for parity —
// trivial to wire up if voice input lands later).
struct AskOrb: View {
    enum Mode { case idle, listening, thinking, speaking }
    var mode: Mode = .idle
    var level: Double = 0
    var size: CGFloat = 132

    @State private var physics = OrbPhysics()
    @State private var idlePulse = false

    private var clampedLevel: Double { min(1, max(0, level)) }

    private static let assetSize: CGFloat = 503.58

    /// The base pose (all rotations at their start angle) — still reads as a
    /// colorful swirl since that's the artwork itself, just not mid-motion.
    private static let restState = OrbPhysics.State(time: 0, global: 0.05, petals: [0.05, 0.05, 0.05, 0.05])

    var body: some View {
        Group {
            if mode == .idle {
                // Osmo shows this inline, at rest, for nearly all of its on-screen
                // time — continuously re-rasterizing the 10-layer blended/hued/
                // 3D-rotated composite here would burn real CPU for a decoration.
                // A static pose + a transform-only pulse (cheap: no re-render of
                // the underlying texture, just an interpolated scale/opacity) reads
                // just as alive at a glance and costs nothing.
                orbBody(Self.restState)
            } else {
                // Actively working — the full physics-driven swirl, reserved for
                // when it's actually signaling something (thinking/answering).
                TimelineView(.animation(minimumInterval: 1.0 / 30)) { timeline in
                    let s = physics.step(now: timeline.date.timeIntervalSinceReferenceDate,
                                         rawLevel: clampedLevel, mode: mode)
                    orbBody(s)
                }
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    private func orbBody(_ s: OrbPhysics.State) -> some View {
        let t = s.time
        return ZStack {
            Image("shadow")

            ZStack {
                Image("icon-bg")

                Group {
                    Image("pink-top")
                        .scaleEffect(1 + 0.16 * s.petals[0])
                        .rotationEffect(.degrees(t * 56.7))
                        .hueRotation(.degrees(t * -27.5))
                    Image("pink-left")
                        .scaleEffect(1 + 0.13 * s.petals[0])
                        .rotationEffect(.degrees(t * -45.0))
                        .hueRotation(.degrees(t * -43.3))
                    Image("blue-middle")
                        .scaleEffect(1 + 0.15 * s.petals[1])
                        .rotationEffect(.degrees(t * -65.0))
                        .hueRotation(.degrees(t * -12.5))
                        .rotation3DEffect(.degrees(75), axis: (x: 3 + 2 * sin(t * 0.26), y: 0, z: 0))
                    Image("blue-right")
                        .scaleEffect(1 + 0.12 * s.petals[1])
                        .rotationEffect(.degrees(t * -65.0))
                        .hueRotation(.degrees(t * 64.2))
                        .rotation3DEffect(.degrees(75), axis: (x: 1, y: 0, z: 5 + 10 * sin(t * 0.21)))
                    Image("Intersect")
                        .scaleEffect(1 + 0.11 * s.petals[3])
                        .rotationEffect(.degrees(t * 37.5))
                        .hueRotation(.degrees(t * -60.0))
                        .rotation3DEffect(.degrees(15), axis: (x: 1, y: 1, z: 1),
                                          perspective: 5 * sin(t * 0.24))
                    Image("green-right")
                        .scaleEffect(1 + 0.14 * s.petals[2])
                        .rotationEffect(.degrees(t * -55.0))
                        .hueRotation(.degrees(t * 26.3))
                        .rotation3DEffect(.degrees(15), axis: (x: 1, y: sin(t * 0.3), z: 0),
                                          perspective: -sin(t * 0.3))
                    Image("green-left")
                        .scaleEffect(1 + 0.12 * s.petals[2])
                        .rotationEffect(.degrees(t * 60.0))
                        .hueRotation(.degrees(t * 10.8))
                        .rotation3DEffect(.degrees(75), axis: (x: 1, y: 5 + 10 * sin(t * 0.19), z: 0))
                    Image("bottom-pink")
                        .scaleEffect(1 + 0.10 * s.petals[0])
                        .rotationEffect(.degrees(t * 63.3))
                        .hueRotation(.degrees(t * -19.2))
                        .opacity(0.25)
                        .blendMode(.multiply)
                        .rotation3DEffect(.degrees(75), axis: (x: 5, y: -22 + 23 * sin(t * 0.17), z: 0))
                }
                .blendMode(.hardLight)

                Image("highlight")
                    .rotationEffect(.degrees(t * 9.2))
                    .hueRotation(.degrees(t * -19.2))
                    .opacity(0.62 + 0.38 * min(1, s.global))
                    .scaleEffect(1 + 0.18 * s.global)
            }
            // drawingGroup() rasterizes the whole subtree into one Metal texture
            // so the blend modes / 3D rotations resolve INSIDE the clip mask —
            // without it the petals sail past the disc's edge.
            .drawingGroup()
            .frame(width: Self.assetSize, height: Self.assetSize)
            .clipShape(DiscClip())
        }
        .offset(y: (251.79 - DiscClip.discCenter.y) * (size / Self.assetSize))
        .scaleEffect(size / Self.assetSize)
        .frame(width: size, height: size)
    }
}

/// Clips to the icon-bg asset's actual dark disc — pixel-measured from the
/// rendered asset: a perfect circle, center (250.8, 232.8), radius 195.8 in
/// the 503.58pt canvas.
private struct DiscClip: Shape {
    static let discCenter = CGPoint(x: 250.8, y: 232.8)
    static let discRadius: CGFloat = 195.8
    func path(in rect: CGRect) -> Path {
        let k = rect.width / 503.58
        let center = CGPoint(x: Self.discCenter.x * k, y: Self.discCenter.y * k)
        let r = (Self.discRadius - 1.5) * k
        return Path(ellipseIn: CGRect(x: center.x - r, y: center.y - r,
                                      width: r * 2, height: r * 2))
    }
}

// MARK: - Physics rig

/// Envelope follower + damped springs + volume-warped clock. The asymmetric
/// follower makes each syllable/tick register as a distinct hit; the springs
/// turn hits into elastic bounces with overshoot; per-petal spring constants
/// stagger the response so the orb deforms organically rather than as one
/// rigid unit.
private final class OrbPhysics {
    struct State {
        var time: Double
        var global: Double
        var petals: [Double]
    }

    private struct Spring {
        var pos = 0.0
        var vel = 0.0
        let stiffness: Double
        let damping: Double
        mutating func step(target: Double, dt: Double) {
            let acc = stiffness * (target - pos) - damping * vel
            vel += acc * dt
            pos += vel * dt
            if pos < 0 { pos = 0; vel = max(0, vel) }
        }
    }

    private var envelope = 0.0
    private var warped = 0.0
    private var lastTime: Double?
    private var global = Spring(stiffness: 140, damping: 11)
    private var petalSprings = [
        Spring(stiffness: 120, damping: 10),
        Spring(stiffness: 165, damping: 13),
        Spring(stiffness: 95, damping: 9),
        Spring(stiffness: 145, damping: 12),
    ]

    func step(now: Double, rawLevel: Double, mode: AskOrb.Mode) -> State {
        let dt = lastTime.map { min(0.1, max(0, now - $0)) } ?? 1.0 / 60.0
        lastTime = now

        let target: Double
        switch mode {
        case .idle:      target = 0.05 + 0.04 * sin(now * 0.7)
        case .thinking:  target = 0.22
        case .listening, .speaking: target = rawLevel
        }

        let rate = target > envelope ? 28.0 : 4.5
        envelope += (target - envelope) * min(1, rate * dt)

        global.step(target: envelope, dt: dt)
        for i in petalSprings.indices {
            petalSprings[i].step(target: envelope, dt: dt)
        }

        let base: Double
        switch mode {
        case .idle:      base = 0.45
        case .thinking:  base = 1.25
        case .listening, .speaking: base = 0.7
        }
        let agitation = mode == .idle ? 0.0 : 1.9 * envelope + 0.10 * min(3, abs(global.vel))
        warped += dt * (base + agitation)

        return State(time: warped, global: global.pos, petals: petalSprings.map(\.pos))
    }
}
