import SwiftUI

/// Glowing orb companion — the visual face of Orb.
/// Pulses, changes color with state, reacts to interaction.
struct OrbCompanionView: View {
    @State private var breathScale: CGFloat = 1.0
    @State private var glowRadius: CGFloat = 30
    @State private var ringRotation: Double = 0
    @State private var orbColor: Color = .orbIdle
    @State private var innerPulse: CGFloat = 0

    var body: some View {
        ZStack {
            // Outer glow
            Circle()
                .fill(
                    RadialGradient(
                        colors: [
                            orbColor.opacity(0.4),
                            orbColor.opacity(0.1),
                            orbColor.opacity(0.0)
                        ],
                        center: .center,
                        startRadius: 20,
                        endRadius: 60
                    )
                )
                .frame(width: 120, height: 120)
                .scaleEffect(breathScale)
                .blur(radius: glowRadius * 0.3)

            // Rotating ring (subtle orbital)
            Circle()
                .stroke(
                    AngularGradient(
                        colors: [
                            orbColor.opacity(0.6),
                            orbColor.opacity(0.0),
                            orbColor.opacity(0.3),
                            orbColor.opacity(0.0)
                        ],
                        center: .center
                    ),
                    lineWidth: 1.5
                )
                .frame(width: 76, height: 76)
                .rotationEffect(.degrees(ringRotation))

            // Main orb body
            Circle()
                .fill(
                    RadialGradient(
                        colors: [
                            Color.white.opacity(0.9),
                            orbColor.opacity(0.8),
                            orbColor.opacity(0.6),
                            orbColor.darker().opacity(0.9)
                        ],
                        center: UnitPoint(x: 0.35, y: 0.35),
                        startRadius: 2,
                        endRadius: 32
                    )
                )
                .frame(width: 64, height: 64)
                .scaleEffect(breathScale)
                .overlay(
                    // Inner highlight
                    Circle()
                        .fill(
                            RadialGradient(
                                colors: [Color.white.opacity(0.5), Color.clear],
                                center: UnitPoint(x: 0.3, y: 0.3),
                                startRadius: 2,
                                endRadius: 20
                            )
                        )
                        .frame(width: 40, height: 40)
                        .opacity(0.6 + Double(innerPulse) * 0.3)
                )

            // Listening indicator (concentric rings)
            if true { // TODO: bind to orbState == .listening
                ForEach(0..<3) { i in
                    Circle()
                        .stroke(orbColor.opacity(0.3), lineWidth: 1)
                        .frame(width: CGFloat(70 + i * 15), height: CGFloat(70 + i * 15))
                        .scaleEffect(breathScale + CGFloat(i) * 0.1 * innerPulse)
                        .opacity(Double(3 - i) / 3.0 * Double(innerPulse))
                }
            }
        }
        .frame(width: 120, height: 120)
        .onAppear {
            startAnimations()
        }
        .onTapGesture {
            // TODO: trigger interaction
            pulseOnce()
        }
    }

    // MARK: - Animations

    private func startAnimations() {
        // Breathing
        withAnimation(
            .easeInOut(duration: 3.0)
            .repeatForever(autoreverses: true)
        ) {
            breathScale = 1.08
        }

        // Orbital ring rotation
        withAnimation(
            .linear(duration: 20)
            .repeatForever(autoreverses: false)
        ) {
            ringRotation = 360
        }

        // Inner pulse
        withAnimation(
            .easeInOut(duration: 1.5)
            .repeatForever(autoreverses: true)
        ) {
            innerPulse = 1.0
        }
    }

    private func pulseOnce() {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.4)) {
            breathScale = 1.2
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            withAnimation(.spring(response: 0.5, dampingFraction: 0.6)) {
                breathScale = 1.08
            }
        }
    }

    // MARK: - State Colors

    private func updateColor(for state: OrbState) {
        withAnimation(.easeInOut(duration: 0.5)) {
            switch state {
            case .idle:       orbColor = .orbIdle
            case .listening:  orbColor = .orbListening
            case .processing: orbColor = .orbProcessing
            case .speaking:   orbColor = .orbSpeaking
            case .sleeping:   orbColor = .orbSleeping
            }
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

    func darker() -> Color {
        // Simple darkening for gradients
        Color(hex: self.hexValue().darker())
    }

    private func hexValue() -> String {
        // Extract hex from UIColor
        let uiColor = UIColor(self)
        var r: CGFloat = 0; var g: CGFloat = 0; var b: CGFloat = 0
        uiColor.getRed(&r, green: &g, blue: &b, alpha: nil)
        return String(format: "%02X%02X%02X", Int(r * 255), Int(g * 255), Int(b * 255))
    }
}

private extension String {
    func darker() -> String {
        guard let val = UInt64(self, radix: 16) else { return self }
        let r = max(Int((val >> 16) & 0xFF) - 40, 0)
        let g = max(Int((val >> 8) & 0xFF) - 40, 0)
        let b = max(Int(val & 0xFF) - 40, 0)
        return String(format: "%02X%02X%02X", r, g, b)
    }
}
