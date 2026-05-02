import SwiftUI

/// Conversation bubble — appears when you click the orb.
///
/// Not a chat window. A lightweight floating bubble that shows
/// the current conversation with Aura. One at a time. Dismissible.
///
/// The companion experience: you click the orb, ask something (voice or type),
/// Aura responds, you dismiss. Natural and fast.
struct ConversationBubble: View {
    @ObservedObject var coordinator: AuraCoordinator
    @State private var inputText = ""
    @State private var showInput = false
    @FocusState private var inputFocused: Bool
    
    var body: some View {
        VStack(spacing: 0) {
            // Messages
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVStack(spacing: 8) {
                        ForEach(coordinator.conversationHistory) { msg in
                            MessageBubble(message: msg)
                                .id(msg.id)
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.top, 12)
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
            .frame(maxHeight: 320)
            
            // Divider
            Divider()
                .overlay(Color.white.opacity(0.08))
            
            // Input bar
            HStack(spacing: 10) {
                // Voice button
                Button(action: toggleVoice) {
                    Image(systemName: coordinator.orbState == .listening ? "waveform.circle.fill" : "mic.circle")
                        .font(.system(size: 20))
                        .foregroundColor(coordinator.orbState == .listening ? .cyan : .white.opacity(0.5))
                }
                .buttonStyle(.plain)
                
                // Text input
                TextField("Ask Aura...", text: $inputText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .foregroundColor(.white)
                    .onSubmit(sendMessage)
                    .focused($inputFocused)
                
                // Send button
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
        .onAppear {
            inputFocused = true
        }
    }
    
    private func sendMessage() {
        let text = inputText.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        inputText = ""
        
        Task {
            await coordinator.sendMessage(text)
        }
    }
    
    private func toggleVoice() {
        switch coordinator.orbState {
        case .listening:
            coordinator.stopVoiceConversation()
        default:
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
            
            VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 4) {
                Text(message.content)
                    .font(.system(size: 13))
                    .foregroundColor(textColor)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(background)
                    .clipShape(BubbleShape(isUser: message.role == .user))
            }
            
            if message.role != .user { Spacer(minLength: 40) }
        }
    }
    
    private var textColor: Color {
        switch message.role {
        case .user: return .white
        case .assistant: return .white.opacity(0.9)
        case .error: return .red.opacity(0.8)
        case .system: return .white.opacity(0.5)
        }
    }
    
    private var background: Color {
        switch message.role {
        case .user: return .orbIdle.opacity(0.3)
        case .assistant: return .white.opacity(0.06)
        case .error: return .red.opacity(0.1)
        case .system: return .white.opacity(0.03)
        }
    }
}

// MARK: - Bubble Shape

private struct BubbleShape: Shape {
    let isUser: Bool
    
    func path(in rect: CGRect) -> Path {
        let r: CGFloat = 14
        let tail: CGFloat = 4
        let path = UIBezierPath()
        
        if isUser {
            path.move(to: CGPoint(x: rect.maxX - r, y: rect.minY))
            path.addLine(to: CGPoint(x: r, y: rect.minY))
            path.addArc(withCenter: CGPoint(x: r, y: r), radius: r, startAngle: .pi * 1.5, endAngle: .pi, clockwise: true)
            path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY - r))
            path.addArc(withCenter: CGPoint(x: r, y: rect.maxY - r), radius: r, startAngle: .pi, endAngle: .pi * 0.5, clockwise: true)
            path.addLine(to: CGPoint(x: rect.maxX - tail, y: rect.maxY))
            path.addCurve(to: CGPoint(x: rect.maxX, y: rect.maxY - tail),
                          controlPoint1: CGPoint(x: rect.maxX + 4, y: rect.maxY),
                          controlPoint2: CGPoint(x: rect.maxX, y: rect.maxY + 4))
            path.addLine(to: CGPoint(x: rect.maxX, y: r))
            path.addArc(withCenter: CGPoint(x: rect.maxX - r, y: r), radius: r, startAngle: 0, endAngle: .pi * 1.5, clockwise: true)
        } else {
            path.move(to: CGPoint(x: rect.maxX - r, y: rect.minY))
            path.addLine(to: CGPoint(x: tail, y: rect.minY))
            path.addCurve(to: CGPoint(x: rect.minX, y: tail),
                          controlPoint1: CGPoint(x: rect.minX - 4, y: rect.minY),
                          controlPoint2: CGPoint(x: rect.minX, y: rect.minY - 4))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY - r))
            path.addArc(withCenter: CGPoint(x: r, y: rect.maxY - r), radius: r, startAngle: .pi, endAngle: .pi * 0.5, clockwise: true)
            path.addLine(to: CGPoint(x: rect.maxX - r, y: rect.maxY))
            path.addArc(withCenter: CGPoint(x: rect.maxX - r, y: rect.maxY - r), radius: r, startAngle: .pi * 0.5, endAngle: 0, clockwise: true)
            path.addLine(to: CGPoint(x: rect.maxX, y: r))
            path.addArc(withCenter: CGPoint(x: rect.maxX - r, y: r), radius: r, startAngle: 0, endAngle: .pi * 1.5, clockwise: true)
        }
        
        return Path(path.cgPath)
    }
}
