import SwiftUI

/// Approval card — shows when Codex wants to execute a command or modify a file.
///
/// Appears inline in the conversation bubble.
/// Auto-approve or manual approve based on Codex's approval policy.
struct ApprovalCard: View {
    let type: ApprovalType
    let detail: String
    let onApprove: () -> Void
    let onDeny: () -> Void
    
    enum ApprovalType {
        case command(shellCommand: String)
        case fileChange(path: String, change: String)

        var iconName: String {
            switch self {
            case .command:
                return "terminal"
            case .fileChange:
                return "doc.text"
            }
        }

        var title: String {
            switch self {
            case .command:
                return "Shell Command"
            case .fileChange:
                return "File Change"
            }
        }
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Header
            HStack(spacing: 6) {
                Image(systemName: type.iconName)
                    .font(.system(size: 11))
                    .foregroundColor(.orange)
                
                Text(type.title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.white.opacity(0.7))
            }
            
            // Detail
            Text(detail)
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(.white.opacity(0.9))
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.white.opacity(0.05))
                .cornerRadius(6)
            
            // Actions
            HStack(spacing: 8) {
                Button(action: onApprove) {
                    Text("Allow")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.green)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 5)
                        .background(Color.green.opacity(0.1))
                        .cornerRadius(6)
                }
                .buttonStyle(.plain)
                
                Button(action: onDeny) {
                    Text("Deny")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.red)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 5)
                        .background(Color.red.opacity(0.1))
                        .cornerRadius(6)
                }
                .buttonStyle(.plain)
                
                Spacer()
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.white.opacity(0.03))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(Color.orange.opacity(0.2), lineWidth: 1)
                )
        )
    }
}
