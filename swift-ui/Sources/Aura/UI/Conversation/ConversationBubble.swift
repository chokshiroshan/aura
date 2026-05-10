import SwiftUI

/// Conversation bubble — click the orb to talk to Aura.
///
/// Lightweight floating bubble showing the conversation.
/// Supports: text messages, voice, approval cards, nudges.
struct ConversationBubble: View {
    @ObservedObject var coordinator: AuraCoordinator
    @State private var inputText = ""
    @FocusState private var inputFocused: Bool
    
    var body: some View {
        VStack(spacing: 0) {
            // Header bar
            HStack {
                Text("Aura")
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .foregroundColor(.white.opacity(0.5))
                Spacer()
                
                // Connection indicator
                Circle()
                    .fill(connectionColor)
                    .frame(width: 6, height: 6)
            }
            .padding(.horizontal, 14)
            .padding(.top, 10)
            .padding(.bottom, 6)
            
            // Messages
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVStack(spacing: 6) {
                        ForEach(coordinator.conversationHistory) { msg in
                            if msg.role == .system {
                                // System message (tool calls, status)
                                Text(msg.content)
                                    .font(.system(size: 11))
                                    .foregroundColor(.white.opacity(0.4))
                                    .padding(.horizontal, 14)
                                    .id(msg.id)
                            } else {
                                MessageBubble(message: msg)
                                    .id(msg.id)
                            }
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.bottom, 8)
                }
                .onChange(of: coordinator.conversationHistory.count) { _ in
                    if let last = coordinator.conversationHistory.last {
                        withAnimation(.easeOut(duration: 0.2)) {
                            proxy.scrollTo(last.id, anchor: .bottom)
                        }
                    }
                }
            }
            .frame(maxHeight: 280)

            if case .authenticating = coordinator.connectionState {
                Button(action: coordinator.loginWithChatGPT) {
                    Label("Sign in with ChatGPT", systemImage: "person.badge.key.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(Color.orbIdle.opacity(0.35))
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 14)
                .padding(.bottom, 8)
            }
            
            // Nudge (if active)
            if let nudge = coordinator.activeNudge {
                NudgeChip(
                    text: nudge.text,
                    priority: nudge.priority,
                    onDismiss: { coordinator.dismissNudge() },
                    onTap: {
                        coordinator.conversationHistory.append(
                            ChatMessage(role: .assistant, content: nudge.text)
                        )
                        coordinator.dismissNudge()
                    }
                )
                .padding(.horizontal, 14)
                .padding(.bottom, 6)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            
            // Divider
            Divider()
                .overlay(Color.white.opacity(0.08))
            
            // Input bar
            HStack(spacing: 10) {
                Button(action: toggleVoice) {
                    Image(systemName: coordinator.isVoiceSessionActive ? "waveform.circle.fill" : "mic.circle")
                        .font(.system(size: 20))
                        .foregroundColor(coordinator.isVoiceSessionActive ? .cyan : .white.opacity(0.4))
                }
                .buttonStyle(.plain)
                
                TextField("Ask Aura...", text: $inputText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .foregroundColor(.white)
                    .onSubmit(sendMessage)
                    .focused($inputFocused)
                
                if !inputText.trimmingCharacters(in: .whitespaces).isEmpty {
                    Button(action: sendMessage) {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 20))
                            .foregroundColor(.orbIdle)
                    }
                    .buttonStyle(.plain)
                    .transition(.scale.combined(with: .opacity))
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
        .frame(width: 340)
        .background(
            RoundedRectangle(cornerRadius: 18)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 18)
                        .stroke(Color.white.opacity(0.1), lineWidth: 1)
                )
        )
        .onAppear { inputFocused = true }
    }
    
    private var connectionColor: Color {
        switch coordinator.connectionState {
        case .connected: return .green
        case .connecting, .authenticating: return .yellow
        case .disconnected, .error: return .red
        }
    }
    
    private func sendMessage() {
        let text = inputText.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        inputText = ""
        Task { await coordinator.sendMessage(text) }
    }
    
    private func toggleVoice() {
        if coordinator.isVoiceSessionActive {
            coordinator.stopVoiceConversation()
        } else {
            coordinator.startVoiceConversation()
        }
    }
}

// MARK: - Message Bubble

private struct MessageBubble: View {
    let message: ChatMessage
    
    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            if message.role == .user { Spacer(minLength: 40) }
            
            Text(message.content)
                .font(.system(size: 13))
                .foregroundColor(textColor)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(background)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            
            if message.role != .user { Spacer(minLength: 40) }
        }
    }
    
    private var textColor: Color {
        switch message.role {
        case .user: return .white
        case .assistant: return .white.opacity(0.9)
        case .error: return .red.opacity(0.8)
        case .system: return .white.opacity(0.4)
        }
    }
    
    private var background: Color {
        switch message.role {
        case .user: return .orbIdle.opacity(0.3)
        case .assistant: return .white.opacity(0.06)
        case .error: return .red.opacity(0.1)
        case .system: return .clear
        }
    }
}
