import SwiftUI
import Combine

/// Central coordinator — glues companion UI, voice, Codex backend, and screen context.
///
/// Architecture:
/// ```
/// Aura App (.app bundle)
/// ├── Swift UI (this file, audio, companion)
/// │     ↕ JSON-RPC over WebSocket
/// └── Codex binary (launched as background process)
///       ↕ ChatGPT Backend API
///       GPT-5 / gpt-realtime (free via subscription)
/// ```
@MainActor
final class AuraCoordinator: ObservableObject {
    @Published var orbState: AuraState = .idle
    @Published var connectionState: ConnectionState = .disconnected
    @Published var currentThreadId: String?
    @Published var accountEmail: String?
    @Published var accountPlan: String?
    @Published var conversationHistory: [ChatMessage] = []
    
    // MARK: - Components
    private let codex = CodexClient()
    private let screenContext = ScreenContextExtractor()
    private let audioCapture = AudioCapture()
    private var codexProcess: Process?
    private var cancellables = Set<AnyCancellable>()
    
    // MARK: - Setup
    
    /// Launch the bundled Codex binary and connect to it.
    func startCodexAndConnect() {
        connectionState = .connecting
        
        // 1. Launch Codex binary as background process
        launchCodexBinary()
        
        // 2. Wait briefly for it to start, then connect via WebSocket
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.connectToCodex()
        }
    }
    
    /// Connect to an already-running Codex instance
    func connectToCodex(url: String = "ws://127.0.0.1:8080") {
        setupCodexCallbacks()
        codex.connect(url: url)
    }
    
    private func setupCodexCallbacks() {
        codex.onConnected = { [weak self] in
            Task { @MainActor in
                self?.connectionState = .connected
                // Initialize the protocol
                do {
                    let initResult = try await self?.codex.initialize() 
                    print("✅ Codex initialized: \(initResult?.userAgent ?? "unknown") on \(initResult?.platform ?? "?")")
                    
                    // Check if we need to log in
                    let account = try await self?.codex.getAccount()
                    self?.accountEmail = account?.email
                    self?.accountPlan = account?.plan
                    
                    if account?.email == nil {
                        self?.connectionState = .authenticating
                        self?.codex.onAuthRequired?()
                    } else {
                        // Ready to use
                        self?.createOrResumeThread()
                    }
                } catch {
                    print("❌ Codex init failed: \(error)")
                    self?.connectionState = .error(error.localizedDescription)
                }
            }
        }
        
        codex.onDisconnected = { [weak self] error in
            Task { @MainActor in
                self?.connectionState = .disconnected
                if let error { print("⚠️ Codex disconnected: \(error)") }
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
        // Path to bundled Codex binary inside the .app
        let bundle = Bundle.main
        let codexPath = bundle.path(forResource: "codex-app-server", ofType: nil)
            ?? bundle.path(forResource: "codex-app-server", ofType: nil, inDirectory: "Contents/MacOS")
        
        guard let binaryPath = codexPath else {
            print("❌ Codex binary not found in app bundle")
            connectionState = .error("Codex binary not found")
            return
        }
        
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binaryPath)
        
        // Launch with WebSocket transport on localhost
        process.arguments = [
            "--listen", "ws://127.0.0.1:8080",
            "--session-source", "orb"
        ]
        
        // Redirect stdout/stderr to /dev/null (Codex is a daemon)
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        
        do {
            try process.run()
            self.codexProcess = process
            print("🚀 Codex binary launched (PID: \(process.processIdentifier))")
        } catch {
            print("❌ Failed to launch Codex: \(error)")
            connectionState = .error("Failed to launch Codex: \(error.localizedDescription)")
        }
    }
    
    // MARK: - Thread Management
    
    private func createOrResumeThread() {
        Task {
            do {
                // Create a new thread for this session
                let thread = try await codex.startThread(
                    cwd: NSHomeDirectory(),
                    instructions: """
                    You are Aura, a helpful AI companion that lives on the user's desktop.
                    You can see their screen, hear their voice, and help with any task.
                    Be concise, friendly, and proactive. Use tools when helpful.
                    """
                )
                self.currentThreadId = thread.id
                self.connectionState = .connected
                print("🧵 Thread created: \(thread.id) (model: \(thread.model))")
            } catch {
                print("❌ Failed to create thread: \(error)")
                self.connectionState = .error(error.localizedDescription)
            }
        }
    }
    
    // MARK: - Text Chat
    
    func sendMessage(_ text: String) async {
        guard let threadId = currentThreadId else {
            print("⚠️ No active thread")
            return
        }
        
        // Add user message to history
        conversationHistory.append(ChatMessage(role: .user, content: text))
        orbState = .processing
        
        do {
            try await codex.startTurn(threadId: threadId, message: text)
        } catch {
            print("❌ Failed to send message: \(error)")
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
                // Start realtime voice session through Codex
                try await codex.startRealtime(threadId: threadId)
                
                // Begin audio capture
                audioCapture.start { [weak self] pcmData in
                    guard let self, let threadId = self.currentThreadId else { return }
                    let base64 = pcmData.base64EncodedString()
                    Task {
                        try? await self.codex.appendAudio(threadId: threadId, base64Audio: base64)
                    }
                }
            } catch {
                print("❌ Failed to start voice: \(error)")
                self.orbState = .idle
            }
        }
    }
    
    func stopVoiceConversation() {
        guard let threadId = currentThreadId else { return }
        
        audioCapture.stop()
        orbState = .processing
        
        Task {
            do {
                try await codex.stopRealtime(threadId: threadId)
            } catch {
                print("❌ Failed to stop voice: \(error)")
            }
            self.orbState = .idle
        }
    }
    
    // MARK: - Events
    
    private func handleTurnEvent(_ event: TurnEvent) {
        switch event {
        case .started(let threadId):
            print("🔄 Turn started on \(threadId)")
            
        case .completed(let threadId):
            print("✅ Turn completed on \(threadId)")
            orbState = .idle
            
        case .agentMessage(let text):
            conversationHistory.append(ChatMessage(role: .assistant, content: text))
            
        case .toolCall(let name, let args):
            print("🔧 Tool call: \(name) \(args)")
            
        case .error(let message):
            orbState = .idle
            conversationHistory.append(ChatMessage(role: .error, content: message))
        }
    }
    
    // MARK: - Login
    
    func loginWithChatGPT() {
        Task {
            do {
                let result = try await codex.loginAccount()
                if let url = result.loginUrl {
                    // Open the OAuth URL in the browser
                    if let url = URL(string: url) {
                        NSWorkspace.shared.open(url)
                    }
                }
            } catch {
                print("❌ Login failed: \(error)")
            }
        }
    }
    
    // MARK: - Cleanup
    
    func shutdown() {
        codex.disconnect()
        audioCapture.stop()
        codexProcess?.terminate()
    }
}

// MARK: - Types

enum AuraState {
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
