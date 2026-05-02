import SwiftUI

/// Nudge chip — small floating indicator that appears near the orb
/// when Aura has something proactive to say.
///
/// Shows a brief text snippet. Click to expand into conversation.
/// Auto-dismisses after 8 seconds.
struct NudgeChip: View {
    let text: String
    let priority: NudgeEngine.Nudge.Priority
    let onDismiss: () -> Void
    let onTap: () -> Void
    
    @State private var opacity: Double = 0
    
    private var chipColor: Color {
        switch priority {
        case .urgent: return .red
        case .high: return .orange
        case .medium: return .cyan
        case .low: return .white.opacity(0.5)
        }
    }
    
    var body: some View {
        HStack(spacing: 6) {
            // Glow dot
            Circle()
                .fill(chipColor)
                .frame(width: 6, height: 6)
                .shadow(color: chipColor, radius: 4)
            
            Text(text)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.white.opacity(0.9))
                .lineLimit(1)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(
            Capsule()
                .fill(.ultraThinMaterial)
                .overlay(
                    Capsule()
                        .stroke(chipColor.opacity(0.3), lineWidth: 1)
                )
        )
        .opacity(opacity)
        .onAppear {
            withAnimation(.easeOut(duration: 0.3)) { opacity = 1 }
            
            // Auto dismiss
            DispatchQueue.main.asyncAfter(deadline: .now() + 8) {
                withAnimation(.easeOut(duration: 0.3)) {
                    opacity = 0
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    onDismiss()
                }
            }
        }
        .onTapGesture { onTap() }
    }
}
