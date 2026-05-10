import SwiftUI
import AppKit

/// Aura's companion: a particle-field body around a glowing nucleus, with
/// overlaid cat-meme reactions emerging from the field.
///
/// State drives the swarm shape (idle sphere / listening ring / processing
/// vortex / speaking waveform / sleeping drift) and the nucleus rhythm.
/// The cursor pulls the swarm and the pupil's gaze. Reactions fire from
/// the coordinator's `MemeReactionEngine`.
struct AuraCompanionView: View {
    @ObservedObject var coordinator: AuraCoordinator
    @ObservedObject var cursorTracker: CursorTracker

    @State private var field = ParticleField(count: 90)
    @State private var heartbeat: CGFloat = 0       // 0..1, flashes on reaction
    @State private var lastTickTime: TimeInterval = 0
    @State private var pupilDrift: CGPoint = .zero
    @State private var lastReactionId: UUID?

    init(coordinator: AuraCoordinator, cursorTracker: CursorTracker) {
        self.coordinator = coordinator
        self.cursorTracker = cursorTracker
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60.0)) { timeline in
            let time = timeline.date.timeIntervalSinceReferenceDate

            ZStack {
                Canvas(opaque: false) { context, size in
                    drawField(context: context, size: size, time: time)
                    drawNucleus(context: context, size: size, time: time)
                }
                .onChange(of: time) { _, newTime in
                    advance(to: newTime)
                }

                CatReactionOverlay(engine: coordinator.memes)
            }
            .frame(width: 140, height: 140)
            .onChange(of: coordinator.memes.current?.id) { _, newId in
                handleReactionChange(newId)
            }
        }
    }

    // MARK: - Per-frame stepping

    private func advance(to time: TimeInterval) {
        let dt: CGFloat
        if lastTickTime == 0 {
            dt = 1.0 / 60.0
        } else {
            dt = CGFloat(min(time - lastTickTime, 0.05))  // clamp big stalls
        }
        lastTickTime = time

        field.step(
            dt: dt,
            time: time,
            state: coordinator.orbState,
            inputLevel: coordinator.inputLevel,
            outputLevel: coordinator.outputLevel,
            cursorVec: cursorTracker.vector
        )

        // Heartbeat decay
        heartbeat = max(0, heartbeat - dt * 3.0)

        // Pupil drift (slow Lissajous when cursor far)
        let cursorMag = sqrt(cursorTracker.vector.dx * cursorTracker.vector.dx +
                             cursorTracker.vector.dy * cursorTracker.vector.dy)
        if cursorMag < 0.05 {
            pupilDrift = CGPoint(
                x: CGFloat(sin(time * 0.7)) * 1.6,
                y: CGFloat(cos(time * 0.55)) * 1.4
            )
        } else {
            // Gaze toward cursor
            pupilDrift = CGPoint(
                x: cursorTracker.vector.dx * 2.2,
                y: -cursorTracker.vector.dy * 2.2  // SwiftUI y flipped
            )
        }
    }

    // MARK: - Drawing

    private func drawField(context: GraphicsContext, size: CGSize, time: TimeInterval) {
        let cx = size.width / 2
        let cy = size.height / 2
        let baseColor = stateColor(coordinator.orbState)

        var ctx = context
        ctx.blendMode = .screen

        for p in field.particles {
            let x = cx + p.position.x
            let y = cy + p.position.y
            let lifeBoost = 1.0 + p.life * 1.3
            let radius = p.size * lifeBoost
            let glowRadius = radius * 2.5

            // Outer soft glow
            let glowRect = CGRect(x: x - glowRadius, y: y - glowRadius,
                                  width: glowRadius * 2, height: glowRadius * 2)
            ctx.fill(
                Path(ellipseIn: glowRect),
                with: .radialGradient(
                    Gradient(colors: [
                        baseColor.opacity(0.45 + Double(p.life) * 0.4),
                        baseColor.opacity(0.0)
                    ]),
                    center: CGPoint(x: x, y: y),
                    startRadius: 0,
                    endRadius: glowRadius
                )
            )

            // Core dot
            let dotRect = CGRect(x: x - radius, y: y - radius,
                                 width: radius * 2, height: radius * 2)
            ctx.fill(
                Path(ellipseIn: dotRect),
                with: .radialGradient(
                    Gradient(colors: [
                        Color.white.opacity(0.95),
                        baseColor.opacity(0.7),
                        baseColor.opacity(0.0)
                    ]),
                    center: CGPoint(x: x, y: y),
                    startRadius: 0,
                    endRadius: radius
                )
            )
        }
    }

    private func drawNucleus(context: GraphicsContext, size: CGSize, time: TimeInterval) {
        let baseColor = stateColor(coordinator.orbState)
        var nucleusCx = size.width / 2
        var nucleusCy = size.height / 2
        // Nucleus follows the cursor lean by half (so it leads the swarm)
        nucleusCx += cursorTracker.vector.dx * 7
        nucleusCy -= cursorTracker.vector.dy * 7

        // State-driven halo size & brightness
        let breath = CGFloat(0.5 + 0.5 * sin(time * 2 * .pi / 2.4))
        var haloR: CGFloat = 14 + breath * 4
        var haloOpacity: Double = 0.55
        var coreR: CGFloat = 4.5

        switch coordinator.orbState {
        case .idle:
            break
        case .listening:
            haloR = 12 + CGFloat(coordinator.inputLevel) * 8
            haloOpacity = 0.7
        case .processing:
            haloOpacity = 0.45
            haloR = 13
        case .speaking:
            haloR = 14 + CGFloat(coordinator.outputLevel) * 10
            haloOpacity = 0.85
            coreR = 5.0
        case .sleeping:
            haloR = 10
            haloOpacity = 0.35
            coreR = 3.5
        }

        // Heartbeat flash on reaction
        haloOpacity += Double(heartbeat) * 0.4
        haloR += heartbeat * 4

        // Halo
        let haloRect = CGRect(x: nucleusCx - haloR, y: nucleusCy - haloR,
                              width: haloR * 2, height: haloR * 2)
        var haloCtx = context
        haloCtx.blendMode = .screen
        haloCtx.fill(
            Path(ellipseIn: haloRect),
            with: .radialGradient(
                Gradient(colors: [
                    baseColor.opacity(haloOpacity),
                    baseColor.opacity(haloOpacity * 0.4),
                    baseColor.opacity(0)
                ]),
                center: CGPoint(x: nucleusCx, y: nucleusCy),
                startRadius: 0,
                endRadius: haloR
            )
        )

        // Core disc (crisp)
        let coreColor = baseColor.mix(with: .white, by: 0.7)
        let coreRect = CGRect(x: nucleusCx - coreR, y: nucleusCy - coreR,
                              width: coreR * 2, height: coreR * 2)
        context.fill(
            Path(ellipseIn: coreRect),
            with: .radialGradient(
                Gradient(colors: [coreColor, baseColor]),
                center: CGPoint(x: nucleusCx - 0.5, y: nucleusCy - 0.5),
                startRadius: 0,
                endRadius: coreR
            )
        )

        // Pupil (eye-like shimmer)
        if coordinator.orbState == .sleeping {
            // Closed-eye slit: a horizontal dark ellipse covering the core
            // most of the time, briefly opening every ~6s
            let blinkPhase = (time.truncatingRemainder(dividingBy: 6.0)) / 6.0
            let lidOpacity: Double = blinkPhase < 0.85 ? 0.85 : 0.0
            let lidRect = CGRect(
                x: nucleusCx - coreR - 0.5,
                y: nucleusCy - 0.6,
                width: coreR * 2 + 1,
                height: 1.6
            )
            context.fill(
                Path(ellipseIn: lidRect),
                with: .color(Color.black.opacity(lidOpacity))
            )
        } else if coordinator.orbState == .processing {
            // Pupil orbits the core
            let orbitR: CGFloat = 1.6
            let px = nucleusCx + CGFloat(cos(time * 3.5)) * orbitR
            let py = nucleusCy + CGFloat(sin(time * 3.5)) * orbitR
            context.fill(
                Path(ellipseIn: CGRect(x: px - 0.9, y: py - 0.9, width: 1.8, height: 1.8)),
                with: .color(Color.black.opacity(0.6))
            )
        } else {
            // Pupil follows cursor / drifts
            let px = nucleusCx + pupilDrift.x
            let py = nucleusCy + pupilDrift.y
            context.fill(
                Path(ellipseIn: CGRect(x: px - 0.9, y: py - 0.9, width: 1.8, height: 1.8)),
                with: .color(Color.black.opacity(0.65))
            )
        }
    }

    // MARK: - Reaction handling

    private func handleReactionChange(_ newId: UUID?) {
        guard let id = newId, id != lastReactionId else {
            if newId == nil { lastReactionId = nil }
            return
        }
        lastReactionId = id
        // Heartbeat flash
        heartbeat = 1.0
        // Particle expulsion in the direction of emergence
        if let reaction = coordinator.memes.current {
            field.expel(angle: reaction.angle, count: 30, magnitude: 100)
        }
    }

    private func stateColor(_ state: AuraState) -> Color {
        switch state {
        case .idle:       return .orbIdle
        case .listening:  return .orbListening
        case .processing: return .orbProcessing
        case .speaking:   return .orbSpeaking
        case .sleeping:   return .orbSleeping
        }
    }
}

// MARK: - Orb Colors

extension Color {
    static let orbIdle       = Color(hex: "6C63FF") // Purple
    static let orbListening  = Color(hex: "00D9FF") // Cyan
    static let orbProcessing = Color(hex: "FFB800") // Amber
    static let orbSpeaking   = Color(hex: "00FF88") // Green
    static let orbSleeping   = Color(hex: "4A42D1") // Deep purple

    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch hex.count {
        case 6: (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8: (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default: (a, r, g, b) = (255, 0, 0, 0)
        }
        self.init(
            .sRGB,
            red: Double(r) / 255,
            green: Double(g) / 255,
            blue: Double(b) / 255,
            opacity: Double(a) / 255
        )
    }

    func darker() -> Color {
        Color(NSColor(self).darker())
    }

    /// Linear blend between two SwiftUI colors via NSColor.
    func mix(with other: Color, by t: CGFloat) -> Color {
        let a = NSColor(self).usingColorSpace(.sRGB) ?? NSColor.black
        let b = NSColor(other).usingColorSpace(.sRGB) ?? NSColor.white
        var ar: CGFloat = 0, ag: CGFloat = 0, ab: CGFloat = 0, aa: CGFloat = 0
        var br: CGFloat = 0, bg: CGFloat = 0, bb: CGFloat = 0, ba: CGFloat = 0
        a.getRed(&ar, green: &ag, blue: &ab, alpha: &aa)
        b.getRed(&br, green: &bg, blue: &bb, alpha: &ba)
        let tt = max(0, min(1, t))
        return Color(.sRGB,
                     red: Double(ar + (br - ar) * tt),
                     green: Double(ag + (bg - ag) * tt),
                     blue: Double(ab + (bb - ab) * tt),
                     opacity: Double(aa + (ba - aa) * tt))
    }
}

extension NSColor {
    func darker() -> NSColor {
        var r: CGFloat = 0; var g: CGFloat = 0; var b: CGFloat = 0; var a: CGFloat = 0
        (usingColorSpace(.sRGB) ?? self).getRed(&r, green: &g, blue: &b, alpha: &a)
        return NSColor(red: max(r - 0.15, 0), green: max(g - 0.15, 0), blue: max(b - 0.15, 0), alpha: a)
    }
}
