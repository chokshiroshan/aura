import SwiftUI
import AppKit

/// Glowing orb companion — the visual face of Aura.
///
/// Siri-like / futuristic aesthetic. Not a button, a presence.
/// Reacts to coordinator state:
/// - **Idle**: Subtle breathing, soft purple glow
/// - **Listening**: Cyan pulse, expanding rings
/// - **Processing**: Amber spin, loading feel
/// - **Speaking**: Green glow, calm rhythm
/// - **Sleeping**: Deep purple, slow breath
struct AuraCompanionView: View {
    @ObservedObject var coordinator: AuraCoordinator
    
    @State private var breathScale: CGFloat = 1.0
    @State private var glowRadius: CGFloat = 30
    @State private var ringRotation: Double = 0
    @State private var innerPulse: CGFloat = 0
    
    private var orbColor: Color {
        switch coordinator.orbState {
        case .idle:       return .orbIdle
        case .listening:  return .orbListening
        case .processing: return .orbProcessing
        case .speaking:   return .orbSpeaking
        case .sleeping:   return .orbSleeping
        }
    }
    
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
            
            // Rotating ring
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
            
            // Listening indicator — concentric rings
            if coordinator.orbState == .listening {
                ForEach(0..<3, id: \.self) { i in
                    Circle()
                        .stroke(orbColor.opacity(0.3), lineWidth: 1)
                        .frame(width: CGFloat(70 + i * 15), height: CGFloat(70 + i * 15))
                        .scaleEffect(breathScale + CGFloat(i) * 0.1 * innerPulse)
                        .opacity(Double(3 - i) / 3.0 * Double(innerPulse))
                }
            }
            
            // Processing spinner — faster ring rotation
            if coordinator.orbState == .processing {
                Circle()
                    .trim(from: 0, to: 0.7)
                    .stroke(orbColor.opacity(0.6), lineWidth: 2)
                    .frame(width: 80, height: 80)
                    .rotationEffect(.degrees(ringRotation * 3))
            }
        }
        .frame(width: 120, height: 120)
        .animation(.easeInOut(duration: 0.5), value: coordinator.orbState)
        .onAppear { startAnimations() }
    }
    
    // MARK: - Animations
    
    private func startAnimations() {
        // Breathing
        withAnimation(.easeInOut(duration: 3.0).repeatForever(autoreverses: true)) {
            breathScale = 1.08
        }
        
        // Orbital ring rotation
        withAnimation(.linear(duration: 20).repeatForever(autoreverses: false)) {
            ringRotation = 360
        }
        
        // Inner pulse
        withAnimation(.easeInOut(duration: 1.5).repeatForever(autoreverses: true)) {
            innerPulse = 1.0
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
}

extension NSColor {
    func darker() -> NSColor {
        var r: CGFloat = 0; var g: CGFloat = 0; var b: CGFloat = 0; var a: CGFloat = 0
        (usingColorSpace(.sRGB) ?? self).getRed(&r, green: &g, blue: &b, alpha: &a)
        return NSColor(red: max(r - 0.15, 0), green: max(g - 0.15, 0), blue: max(b - 0.15, 0), alpha: a)
    }
}
