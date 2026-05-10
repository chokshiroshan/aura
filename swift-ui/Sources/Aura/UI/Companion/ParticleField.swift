import SwiftUI
import CoreGraphics

/// A swarm of glowing particles with state-dependent target fields.
/// Stored as plain values inside a class so the per-frame `step` mutates in
/// place without copy-on-write overhead.
final class ParticleField {
    struct Particle {
        var position: CGPoint
        var velocity: CGVector
        var hueOffset: CGFloat
        var size: CGFloat
        var life: CGFloat   // 0..1, drives sparkle bursts and per-particle expulsion
    }

    private(set) var particles: [Particle] = []
    private let count: Int
    private var lastSparkle: TimeInterval = 0
    private var nextSparkleInterval: TimeInterval = 9
    private var startTime: TimeInterval = 0

    init(count: Int = 90) {
        self.count = count
        seed()
    }

    private func seed() {
        particles.removeAll()
        particles.reserveCapacity(count)
        for _ in 0..<count {
            let angle = Double.random(in: 0...2 * .pi)
            let radius = CGFloat.random(in: 18...26)
            particles.append(Particle(
                position: CGPoint(x: cos(angle) * radius, y: sin(angle) * radius),
                velocity: .zero,
                hueOffset: CGFloat.random(in: -0.04...0.04),
                size: CGFloat.random(in: 1.5...3.2),
                life: CGFloat.random(in: 0...1)
            ))
        }
    }

    /// Inject a velocity burst on a random subset of particles in the
    /// direction of `angle`. Used when a meme reaction emerges.
    func expel(angle: Double, count expelCount: Int = 30, magnitude: CGFloat = 80) {
        let dir = CGVector(dx: cos(angle), dy: -sin(angle))  // y inverted: SwiftUI canvas
        for _ in 0..<expelCount {
            let idx = Int.random(in: 0..<particles.count)
            particles[idx].velocity.dx += dir.dx * magnitude * CGFloat.random(in: 0.6...1.0)
            particles[idx].velocity.dy += dir.dy * magnitude * CGFloat.random(in: 0.6...1.0)
            particles[idx].life = 1.0
        }
    }

    /// Advance the simulation by `dt` seconds.
    /// Coordinate space: origin at field center; cursorVec is normalized -1..1.
    func step(
        dt: CGFloat,
        time: TimeInterval,
        state: AuraState,
        inputLevel: Float,
        outputLevel: Float,
        cursorVec: CGVector
    ) {
        if startTime == 0 { startTime = time }
        let t = time - startTime

        // Cursor-lean offset (max 14pt toward cursor when within range)
        let leanMag: CGFloat = 14
        let leanX = max(-1, min(1, cursorVec.dx)) * leanMag
        let leanY = max(-1, min(1, cursorVec.dy)) * leanMag

        // Idle sparkle scheduling
        if state == .idle, t - lastSparkle > nextSparkleInterval {
            lastSparkle = t
            nextSparkleInterval = TimeInterval.random(in: 8...14)
            for _ in 0..<Int.random(in: 6...10) {
                let idx = Int.random(in: 0..<particles.count)
                particles[idx].life = 1.0
                let kick = CGFloat.random(in: 30...60)
                let a = Double.random(in: 0...2 * .pi)
                particles[idx].velocity.dx += cos(a) * kick
                particles[idx].velocity.dy += sin(a) * kick
            }
        }

        let stiffness: CGFloat = 8.5
        let drag: CGFloat = 0.92

        for i in 0..<particles.count {
            let target = targetPoint(
                index: i,
                time: t,
                state: state,
                inputLevel: CGFloat(inputLevel),
                outputLevel: CGFloat(outputLevel)
            )
            let targetX = target.x + leanX
            let targetY = target.y + leanY

            // Spring toward target
            let dx = targetX - particles[i].position.x
            let dy = targetY - particles[i].position.y
            particles[i].velocity.dx += dx * stiffness * dt
            particles[i].velocity.dy += dy * stiffness * dt

            // Brownian jitter (lighter when sleeping)
            let jitterMag: CGFloat = state == .sleeping ? 4 : 12
            particles[i].velocity.dx += CGFloat.random(in: -jitterMag...jitterMag) * dt
            particles[i].velocity.dy += CGFloat.random(in: -jitterMag...jitterMag) * dt

            // Drag and integrate
            particles[i].velocity.dx *= drag
            particles[i].velocity.dy *= drag
            particles[i].position.x += particles[i].velocity.dx * dt
            particles[i].position.y += particles[i].velocity.dy * dt

            // Decay life
            particles[i].life = max(0, particles[i].life - CGFloat(dt) * 1.4)
        }
    }

    /// State-dependent target field. Each particle gets its own target so the
    /// swarm has structure rather than collapsing to a single point.
    private func targetPoint(
        index i: Int,
        time t: TimeInterval,
        state: AuraState,
        inputLevel: CGFloat,
        outputLevel: CGFloat
    ) -> CGPoint {
        let n = max(1, particles.count)
        let phi = 2 * .pi * Double(i) / Double(n)
        let phiOffset = Double(i) * 0.7  // pseudo-random per index

        switch state {
        case .idle:
            // Loose breathing sphere shell
            let breathe: CGFloat = 1 + 0.06 * CGFloat(sin(t * 0.55))
            let r: CGFloat = 22 * breathe + CGFloat(sin(phiOffset * 1.3)) * 1.5
            let a = phi + t * 0.08
            return CGPoint(x: cos(a) * r, y: sin(a) * r)

        case .listening:
            // Tight ring; radius pumps with mic level (+ small wave for life)
            let baseR: CGFloat = 24
            let pump = inputLevel * 14
            let wobble = CGFloat(sin(t * 4 + phi * 3)) * 1.5
            let r = baseR + pump + wobble
            let a = phi + t * 0.6
            return CGPoint(x: cos(a) * r, y: sin(a) * r)

        case .processing:
            // Toroidal swirl: target moves along a Lissajous curve, particles
            // spread along it with index-dependent phase.
            let rOuter: CGFloat = 24
            let rInner: CGFloat = 8
            let a = phi + t * 1.4
            let lx = cos(a) * rOuter
            let ly = sin(a * 1.3 + t * 0.6) * rInner + sin(a) * rOuter * 0.5
            return CGPoint(x: lx, y: ly)

        case .speaking:
            // 5 vertical waveform bands. Particles are distributed across bands
            // by index; each band's height pumps with output level + a phase-
            // shifted sine (no real FFT, but reads naturally).
            let bandCount = 5
            let bandIdx = i % bandCount
            let bandX = (CGFloat(bandIdx) - 2) * 11  // -22, -11, 0, 11, 22
            let phase = Double(bandIdx) * 0.7 + t * 6
            let baseH: CGFloat = 8
            let pump = outputLevel * 28
            let h = (baseH + pump) * CGFloat(0.6 + 0.4 * sin(phase))
            // Half the particles get +h, half -h, so the band has thickness.
            let sign: CGFloat = (i / bandCount) % 2 == 0 ? 1 : -1
            let yJitter = CGFloat(sin(phiOffset + t * 3)) * 2
            return CGPoint(x: bandX, y: sign * h * 0.5 + yJitter)

        case .sleeping:
            // Half drift far + dim; half cluster low and slow.
            if i % 2 == 0 {
                let r: CGFloat = 32 + CGFloat(sin(phiOffset + t * 0.3)) * 6
                let a = phi + t * 0.05
                return CGPoint(x: cos(a) * r, y: sin(a) * r * 0.4 + 6)
            } else {
                let xs = CGFloat(sin(phiOffset + t * 0.4)) * 12
                let ys = 8 + CGFloat(cos(phiOffset * 1.7 + t * 0.3)) * 4
                return CGPoint(x: xs, y: ys)
            }
        }
    }
}
