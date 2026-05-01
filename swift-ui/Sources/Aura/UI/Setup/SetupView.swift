import SwiftUI

/// First-launch setup — pick your backend.
struct SetupView: View {
    @State private var selectedBackend: BackendOption = .none
    @State private var openclawURL: String = ""
    @State private var openclawKey: String = ""
    @State private var isConnecting = false

    var body: some View {
        VStack(spacing: 24) {
            // Header
            VStack(spacing: 8) {
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [Color.orbIdle.opacity(0.8), Color.orbIdle.darker()],
                            center: UnitPoint(x: 0.35, y: 0.35),
                            startRadius: 2,
                            endRadius: 30
                        )
                    )
                    .frame(width: 60, height: 60)

                Text("Aura")
                    .font(.system(size: 28, weight: .bold, design: .rounded))

                Text("Your AI companion, everywhere.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }

            Divider().padding(.horizontal, 40)

            // Backend options
            VStack(spacing: 12) {
                BackendOptionCard(
                    title: "Connect OpenClaw",
                    subtitle: "Full experience — sync, memory, skills, multi-device",
                    icon: "server.rack",
                    color: .green,
                    isSelected: selectedBackend == .openclaw,
                    onSelect: { selectedBackend = .openclaw }
                )

                if selectedBackend == .openclaw {
                    OpenClawConfigForm(
                        url: $openclawURL,
                        apiKey: $openclawKey
                    )
                }

                BackendOptionCard(
                    title: "Use ChatGPT",
                    subtitle: "Voice companion with your ChatGPT subscription",
                    icon: "bubble.left.and.bubble.right",
                    color: .orange,
                    isSelected: selectedBackend == .chatgpt,
                    onSelect: { selectedBackend = .chatgpt }
                )
            }

            // Connect button
            Button(action: connect) {
                HStack(spacing: 8) {
                    if isConnecting {
                        ProgressView()
                            .scaleEffect(0.8)
                    }
                    Text(isConnecting ? "Connecting..." : "Get Started")
                        .font(.headline)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
            }
            .buttonStyle(.borderedProminent)
            .disabled(selectedBackend == .none || isConnecting)
            .padding(.horizontal, 40)
        }
        .padding(32)
        .frame(width: 420, height: 520)
    }

    private func connect() {
        isConnecting = true
        // TODO: Wire to AuraCoordinator
    }
}

// MARK: - Subviews

private struct BackendOptionCard: View {
    let title: String
    let subtitle: String
    let icon: String
    let color: Color
    let isSelected: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.title2)
                    .foregroundColor(color)
                    .frame(width: 36)

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.body.weight(.semibold))
                    Text(subtitle)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Spacer()

                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(color)
                }
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(isSelected ? color.opacity(0.1) : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(isSelected ? color.opacity(0.3) : Color.gray.opacity(0.2), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 8)
    }
}

private struct OpenClawConfigForm: View {
    @Binding var url: String
    @Binding var apiKey: String

    var body: some View {
        VStack(spacing: 8) {
            TextField("Gateway URL", text: $url, prompt: Text("https://your-vps:443"))
                .textFieldStyle(.roundedBorder)
            SecureField("API Key", text: $apiKey, prompt: Text("Or scan QR from OpenClaw"))
                .textFieldStyle(.roundedBorder)
        }
        .padding(.horizontal, 16)
        .transition(.opacity.combined(with: .move(edge: .top)))
    }
}

enum BackendOption {
    case none
    case openclaw
    case chatgpt
}
