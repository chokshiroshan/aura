import SwiftUI

/// Settings window — proactivity dial, voice selection, hotkey config.
struct SettingsView: View {
    @ObservedObject var coordinator: AuraCoordinator
    
    var body: some View {
        TabView {
            GeneralSettingsView(coordinator: coordinator)
                .tabItem { Label("General", systemImage: "gear") }
            
            VoiceSettingsView()
                .tabItem { Label("Voice", systemImage: "mic") }
            
            ProactivitySettingsView(coordinator: coordinator)
                .tabItem { Label("Proactivity", systemImage: "bell") }
        }
        .frame(width: 450, height: 320)
    }
}

// MARK: - General

private struct GeneralSettingsView: View {
    @ObservedObject var coordinator: AuraCoordinator
    @State private var permissions = PermissionsManager.shared.checkAll()
    private let permissionPoller = Timer.publish(every: 1.0, on: .main, in: .common).autoconnect()
    
    var body: some View {
        Form {
            Section("Connection") {
                LabeledContent("Status") {
                    switch coordinator.connectionState {
                    case .connected:
                        Label("Connected", systemImage: "checkmark.circle.fill")
                            .foregroundColor(.green)
                    case .connecting:
                        Label("Connecting...", systemImage: "arrow.2.circlepath")
                            .foregroundColor(.yellow)
                    case .authenticating:
                        Label("Signing in...", systemImage: "person.badge.key")
                            .foregroundColor(.yellow)
                    case .disconnected:
                        Label("Disconnected", systemImage: "xmark.circle")
                            .foregroundColor(.red)
                    case .error(let msg):
                        Label(msg.prefix(30).description, systemImage: "exclamationmark.triangle")
                            .foregroundColor(.red)
                    }
                }
                
                if let email = coordinator.accountEmail {
                    LabeledContent("Account") {
                        Text(email)
                            .foregroundColor(.secondary)
                    }
                }
                
                if let plan = coordinator.accountPlan {
                    LabeledContent("Plan") {
                        Text(plan)
                            .foregroundColor(.secondary)
                    }
                }
            }
            
            Section("Screen") {
                LabeledContent("Permission") {
                    HStack(spacing: 8) {
                        Label(
                            permissions.screenRecording ? "Granted" : "Needed",
                            systemImage: permissions.screenRecording ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
                        )
                        .foregroundColor(permissions.screenRecording ? .green : .orange)

                        if !permissions.screenRecording {
                            Button("Allow") {
                                _ = PermissionsManager.shared.requestScreenRecording()
                                PermissionsManager.shared.openScreenRecordingSettings()
                            }
                        }
                    }
                }

                LabeledContent("Vision") {
                    Toggle("Stream screen to Aura", isOn: .constant(true))
                }
            }
        }
        .formStyle(.grouped)
        .padding()
        .onAppear {
            permissions = PermissionsManager.shared.checkAll()
        }
        .onReceive(permissionPoller) { _ in
            permissions = PermissionsManager.shared.checkAll()
        }
    }
}

// MARK: - Voice

private struct VoiceSettingsView: View {
    @State private var selectedVoice = "alloy"
    
    let voices = ["alloy", "ash", "ballad", "coral", "echo", "sage", "shimmer", "verse"]
    
    var body: some View {
        Form {
            Section("Voice") {
                Picker("Aura's Voice", selection: $selectedVoice) {
                    ForEach(voices, id: \.self) { voice in
                        Text(voice.capitalized).tag(voice)
                    }
                }
            }
            
            Section("Microphone") {
                LabeledContent("Input") {
                    Text(AudioCapture.listInputDevices().first?.name ?? "Default")
                        .foregroundColor(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}

// MARK: - Proactivity

private struct ProactivitySettingsView: View {
    @ObservedObject var coordinator: AuraCoordinator
    
    var body: some View {
        VStack(spacing: 16) {
            Text("How proactive should Aura be?")
                .font(.headline)
            
            ForEach(NudgeEngine.ProactivityLevel.allCases, id: \.self) { level in
                ProactivityOption(
                    level: level,
                    isSelected: coordinator.proactivityLevel == level,
                    onSelect: { coordinator.setProactivity(level) }
                )
            }
        }
        .padding(20)
    }
}

private struct ProactivityOption: View {
    let level: NudgeEngine.ProactivityLevel
    let isSelected: Bool
    let onSelect: () -> Void
    
    var body: some View {
        Button(action: onSelect) {
            HStack {
                Image(systemName: iconName)
                    .font(.title3)
                    .foregroundColor(isSelected ? color : .secondary)
                    .frame(width: 30)
                
                VStack(alignment: .leading, spacing: 2) {
                    Text(level.rawValue.capitalized)
                        .font(.body.weight(.semibold))
                    Text(description)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                
                Spacer()
                
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(color)
                }
            }
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isSelected ? color.opacity(0.1) : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(isSelected ? color.opacity(0.3) : Color.gray.opacity(0.2), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
    
    private var iconName: String {
        switch level {
        case .silent: return "moon.fill"
        case .light: return "light.max"
        case .active: return "bell.fill"
        case .partner: return "heart.fill"
        }
    }
    
    private var color: Color {
        switch level {
        case .silent: return .purple
        case .light: return .blue
        case .active: return .cyan
        case .partner: return .green
        }
    }
    
    private var description: String {
        switch level {
        case .silent: return "Only responds when asked"
        case .light: return "Errors and obvious improvements"
        case .active: return "Offers help when it can be useful"
        case .partner: return "Actively suggests, reminds, assists"
        }
    }
}
