import SwiftUI
import Combine

/// Central coordinator — the brain that wires everything together.
///
/// Architecture:
/// ```
/// Aura App (.app bundle)
/// ├── Swift UI (this file, companion, audio, screen)
/// │     ↕ JSON-RPC over WebSocket
/// └── Codex binary (background process)
///       ↕ ChatGPT Backend API
///       GPT-5 / gpt-realtime (free via subscription)
/// ```
///
/// Manages:
/// - Codex binary lifecycle + WebSocket connection
/// - Thread/turn management for conversations
/// - Voice sessions (mic → Codex → speaker)
/// - Screen streaming (1fps → Codex vision)
/// - Proactive nudges (scan → detect → notify)
/// - Approval flow (command/file → UI → resolve)
@MainActor
final class AuraCoordinator: ObservableObject {
    @Published var orbState: AuraState = .idle
    @Published var connectionState: ConnectionState = .disconnected
    @Published var currentThreadId: String?
    @Published var accountEmail: String?
    @Published var accountPlan: String?
    @Published var conversationHistory: [ChatMessage] = []
    @Published var activeNudge: NudgeEngine.Nudge?
    @Published var proactivityLevel: NudgeEngine.ProactivityLevel = .active
    
    // MARK: - Components
    private let codex = CodexClient()
    private let audioCapture = AudioCapture()
    private let audioPlayer = AudioPlayer()
    private let screenStreamer = ScreenStreamer()
    private let nudgeEngine = NudgeEngine()
    private var codexProcess: Process?
    private var cancellables = Set<AnyCancellable>()
    
    // MARK: - State
    private var isScreenStreaming = false
    private var pendingApprovals: [String: [String: Any]] = [:]
    
    // MARK: - Setup
    
    func startCodexAndConnect() {
        connectionState = .connecting
        
        // Wire sub-components
        nudgeEngine.setCodexClient(codex)
        nudgeEngine.onNudge = { [weak self] nudge in
            Task { @MainActor in
                self?.activeNudge = nudge
                self?.orbState = .speaking  // Brief glow
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                    if self?.orbState == .speaking { self?.orbState = .idle }
                }
            }
        }
        
        screenStreamer.onFrame = { [weak self] url in
            self?.handleScreenFrame(url)
        }
        
        launchCodexBinary()
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.connectToCodex()
        }
    }
    
    func connectToCodex(url: String = "ws://127.0.0.1:8080") {
        setupCodexCallbacks()
        codex.connect(url: url)
    }
    
    private func setupCodexCallbacks() {
        codex.onConnected = { [weak self] in
            Task { @MainActor in
                do {
                    let initResult = try await self?.codex.initialize()
                    print("✅ Codex initialized: \(initResult?.userAgent ?? "?")")
                    
                    let account = try await self?.codex.getAccount()
                    self?.accountEmail = account?.email
                    self?.accountPlan = account?.plan
                    
                    if account?.email == nil {
                        self?.connectionState = .authenticating
                        self?.codex.onAuthRequired?()
                    } else {
                        self?.connectionState = .connected
                        self?.createOrResumeThread()
                        self?.startScreenStreaming()
                        self?.nudgeEngine.startScanning()
                    }
                } catch {
                    self?.connectionState = .error(error.localizedDescription)
                }
            }
        }
        
        codex.onDisconnected = { [weak self] error in
            Task { @MainActor in
                self?.connectionState = .disconnected
            }
        }
        
        codex.onAuthRequired = { [weak self] in
            Task { @MainActor in
                self?.connectionState = .authenticating
            }
        }
        
        codex.onTurnEvent = { [weak self] event in
            Task { @MainActor in
                self?.handleTurnEvent(event)
            }
        }
        
        codex.onModelError = { [weak self] msg in
            Task { @MainActor in
                self?.orbState = .idle
                self?.connectionState = .error(msg)
            }
        }
    }
    
    // MARK: - Codex Binary
    
    private func launchCodexBinary() {
        let bundle = Bundle.main
        let codexPath = bundle.path(forResource: "codex-app-server", ofType: nil)
            ?? bundle.path(forResource: "codex-app-server", ofType: nil, inDirectory: "Contents/MacOS")
        
        guard let binaryPath = codexPath else {
            connectionState = .error("Codex binary not found")
            return
        }
        
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binaryPath)
        process.arguments = ["--listen", "ws://127.0.0.1:8080", "--session-source", "aura"]
        
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        
        do {
            try process.run()
            self.codexProcess = process
            print("🚀 Codex launched (PID: \(process.processIdentifier))")
        } catch {
            connectionState = .error("Failed to launch Codex: \(error.localizedDescription)")
        }
    }
    
    // MARK: - Thread Management
    
    private func createOrResumeThread() {
        Task {
            do {
                let thread = try await codex.startThread(
                    cwd: NSHomeDirectory(),
                    instructions: """
                    You are Aura, a persistent AI companion on the user's Mac desktop.
                    You see their screen in real-time and hear their voice.
                    You help with any task — coding, writing, research, debugging, brainstorming.
                    Be concise, friendly, and proactive. Use tools when helpful.
                    
                    You are not a chatbot. You are a companion that participates in their work.
                    """
                )
                self.currentThreadId = thread.id
                self.connectionState = .connected
                print("🧵 Thread: \(thread.id) (model: \(thread.model))")
            } catch {
                self.connectionState = .error(error.localizedDescription)
            }
        }
    }
    
    // MARK: - Text Chat
    
    func sendMessage(_ text: String) async {
        guard let threadId = currentThreadId else { return }
        
        conversationHistory.append(ChatMessage(role: .user, content: text))
        orbState = .processing
        
        do {
            // Attach current screen context
            let screenshot = screenStreamer.captureNow()
            var input: [[String: Any]] = [["type": "text", "text": text]]
            
            if let path = screenshot?.path {
                input.append(["type": "localImage", "path": path])
            }
            
            try await codex.startTurn(threadId: threadId, message: text)
        } catch {
            orbState = .idle
            conversationHistory.append(ChatMessage(role: .error, content: error.localizedDescription))
        }
    }
    
    // MARK: - Voice
    
    func startVoiceConversation() {
        guard let threadId = currentThreadId else { return }
        
        orbState = .listening
        
        Task {
            do {
                try await codex.startRealtime(threadId: threadId)
                
                audioPlayer.start()
                
                audioCapture.start { [weak self] pcmData in
                    guard let self, let threadId = self.currentThreadId else { return }
                    let base64 = pcmData.base64EncodedString()
                    Task { try? await self.codex.appendAudio(threadId: threadId, base64Audio: base64) }
                }
            } catch {
                self.orbState = .idle
                print("❌ Voice failed: \(error)")
            }
        }
    }
    
    func stopVoiceConversation() {
        guard let threadId = currentThreadId else { return }
        
        audioCapture.stop()
        orbState = .processing
        
        Task {
            try? await codex.stopRealtime(threadId: threadId)
            audioPlayer.stop()
            self.orbState = .idle
        }
    }
    
    // MARK: - Screen Streaming
    
    private func startScreenStreaming() {
        guard !isScreenStreaming else { return }
        isScreenStreaming = true
        screenStreamer.start(fps: 1.0)
    }
    
    private func handleScreenFrame(_ url: URL) {
        // Feed screen frames to the active thread periodically
        // This gives Aura continuous awareness of what's on screen
        // Frames are lightweight — Codex handles vision natively
        
        // For proactive scanning, feed to nudge engine
        if proactivityLevel != .silent {
            // Every ~10 frames (10 seconds at 1fps), run a scan
            nudgeEngine.analyzeScreen(context: "Screen frame at \(url.lastPathComponent)")
        }
    }
    
    // MARK: - Proactivity
    
    func setProactivity(_ level: NudgeEngine.ProactivityLevel) {
        proactivityLevel = level
        nudgeEngine.setLevel(level)
    }
    
    func dismissNudge() {
        activeNudge = nil
    }
    
    // MARK: - Approvals
    
    func approveRequest(id: String) {
        guard let pending = pendingApprovals.removeValue(forKey: id) else { return }
        Task {
            try? await codex.resolveRequest(requestId: pending["id"] as Any, result: ["approved": true])
        }
    }
    
    func denyRequest(id: String) {
        guard let pending = pendingApprovals.removeValue(forKey: id) else { return }
        Task {
            try? await codex.resolveRequest(requestId: pending["id"] as Any, result: ["approved": false])
        }
    }
    
    // MARK: - Login
    
    func loginWithChatGPT() {
        Task {
            do {
                let result = try await codex.loginAccount()
                if let url = result.loginUrl, let url = URL(string: url) {
                    NSWorkspace.shared.open(url)
                }
            } catch {
                print("❌ Login failed: \(error)")
            }
        }
    }
    
    // MARK: - Events
    
    private func handleTurnEvent(_ event: TurnEvent) {
        switch event {
        case .started:
            orbState = .processing
            
        case .completed:
            orbState = .idle
            
        case .agentMessage(let text):
            conversationHistory.append(ChatMessage(role: .assistant, content: text))
            orbState = .speaking
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                if self?.orbState == .speaking { self?.orbState = .idle }
            }
            
        case .toolCall(let name, let args):
            let detail = "\(name) \(args.map { "\($0.key)=\($0.value)" }.joined(separator: " "))"
            conversationHistory.append(ChatMessage(role: .system, content: "🔧 \(detail)"))
            
        case .error(let message):
            orbState = .idle
            conversationHistory.append(ChatMessage(role: .error, content: message))
        }
    }
    
    // MARK: - Cleanup
    
    func shutdown() {
        screenStreamer.stop()
        screenStreamer.cleanup()
        nudgeEngine.stopScanning()
        audioCapture.stop()
        audioPlayer.stop()
        codex.disconnect()
        codexProcess?.terminate()
    }
}

// MARK: - Types

enum AuraState: Equatable {
    case idle
    case listening
    case processing
    case speaking
    case sleeping
}

enum ConnectionState {
    case disconnected
    case connecting
    case authenticating
    case connected
    case error(String)
}

struct ChatMessage: Identifiable {
    let id = UUID()
    let role: Role
    let content: String
    
    enum Role {
        case user
        case assistant
        case system
        case error
    }
}
