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
    @Published var proactivityLevel: NudgeEngine.ProactivityLevel = .silent
    @Published private(set) var isVoiceSessionActive = false
    
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
    private var isRealtimeActive = false
    private var pendingApprovals: [String: [String: Any]] = [:]
    private var scanResponseBuffers: [String: String] = [:]
    private let attachScreenToTextTurns = true
    private var realtimeScreenTimer: Timer?
    private var pendingRealtimeStartThreadId: String?
    
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
                    
                    await self?.refreshAccountAndStart()
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

        codex.onLoginCompleted = { [weak self] success, error in
            Task { @MainActor in
                if success {
                    await self?.refreshAccountAndStart()
                } else {
                    self?.connectionState = .error(error ?? "ChatGPT login failed")
                }
            }
        }

        codex.onAccountUpdated = { [weak self] in
            Task { @MainActor in
                await self?.refreshAccountAndStart()
            }
        }

        codex.onChatGPTAuthTokensRefresh = { _, reason in
            let refreshed = await ChatGPTAuth.shared.refreshAccessToken(force: reason == "unauthorized")
            guard refreshed,
                  let tokens = KeychainStore.shared.loadTokens(),
                  let accountId = tokens.chatgptAccountId else {
                throw AuthError.authFailed("Could not refresh ChatGPT auth tokens")
            }
            return CodexClient.ChatGPTAuthTokensRefreshResult(
                accessToken: tokens.accessToken,
                accountId: accountId,
                planType: tokens.plan
            )
        }

        codex.onRealtimeStarted = { [weak self] threadId in
            Task { @MainActor in
                guard let self, threadId == self.currentThreadId else { return }
                self.isRealtimeActive = true
                self.isVoiceSessionActive = true
                self.pendingRealtimeStartThreadId = nil
                self.orbState = .listening
                self.startRealtimeAudioIO(threadId: threadId)
            }
        }

        codex.onRealtimeTranscript = { [weak self] threadId, role, text, isFinal in
            Task { @MainActor in
                guard let self, threadId == self.currentThreadId, isFinal else { return }
                self.handleRealtimeTranscript(role: role, text: text)
            }
        }

        codex.onRealtimeAudio = { [weak self] threadId, data in
            Task { @MainActor in
                guard let self, threadId == self.currentThreadId else { return }
                self.audioPlayer.enqueue(data)
            }
        }

        codex.onRealtimeError = { [weak self] threadId, message in
            Task { @MainActor in
                guard let self, threadId == self.currentThreadId else { return }
                self.failVoiceConversation(message)
            }
        }

        codex.onRealtimeClosed = { [weak self] threadId, _ in
            Task { @MainActor in
                guard let self, threadId == self.currentThreadId else { return }
                self.endVoiceLocally()
            }
        }
    }

    private func refreshAccountAndStart() async {
        do {
            let account = try await codex.getAccount()
            accountEmail = account.email
            accountPlan = account.plan

            if account.email == nil && account.authMode != "apiKey" {
                connectionState = .authenticating
                codex.onAuthRequired?()
                return
            }

            connectionState = .connected
            createOrResumeThread()
            if proactivityLevel != .silent {
                startScreenStreaming()
                nudgeEngine.startScanning()
            }
        } catch {
            connectionState = .error(error.localizedDescription)
        }
    }
    
    // MARK: - Codex Binary
    
    private func launchCodexBinary() {
        let bundle = Bundle.main
        let executableCodexPath = bundle.executableURL?
            .deletingLastPathComponent()
            .appendingPathComponent("codex-app-server")
            .path
        let codexPath = bundle.path(forResource: "codex-app-server", ofType: nil)
            ?? executableCodexPath.flatMap {
                FileManager.default.isExecutableFile(atPath: $0) ? $0 : nil
            }
        
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
        guard currentThreadId == nil else { return }

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
                    """,
                    config: realtimeThreadConfig
                )
                self.currentThreadId = thread.id
                self.connectionState = .connected
                print("🧵 Thread: \(thread.id) (model: \(thread.model))")
            } catch {
                self.connectionState = .error(error.localizedDescription)
            }
        }
    }

    private var realtimeThreadConfig: [String: Any] {
        [
            "features.realtime_conversation": true,
            "realtime.version": "v2",
            "realtime.type": "conversational",
            "realtime.transport": "websocket"
        ]
    }
    
    // MARK: - Text Chat
    
    func sendMessage(_ text: String) async {
        guard let threadId = currentThreadId else { return }
        
        conversationHistory.append(ChatMessage(role: .user, content: text))
        orbState = .processing
        
        do {
            let shouldIncludeScreen = shouldAttachScreen(to: text)
            let screenshot = shouldIncludeScreen ? screenStreamer.captureNow() : nil
            if shouldIncludeScreen && screenshot == nil && !PermissionsManager.shared.checkScreenRecording() {
                conversationHistory.append(
                    ChatMessage(
                        role: .system,
                        content: "Screen Recording permission is needed. Grant it in System Settings, then relaunch Aura."
                    )
                )
            }
            if shouldIncludeScreen && screenshot == nil {
                print("⚠️ Sending text turn without screen context")
            }
            try await codex.startTurn(
                threadId: threadId,
                message: text,
                localImagePath: screenshot?.path
            )
        } catch {
            orbState = .idle
            conversationHistory.append(ChatMessage(role: .error, content: error.localizedDescription))
        }
    }

    private func shouldAttachScreen(to text: String) -> Bool {
        if attachScreenToTextTurns {
            return true
        }

        let lowercased = text.lowercased()
        let screenPhrases = [
            "screen",
            "screenshot",
            "see this",
            "see my",
            "look at",
            "what's on",
            "whats on",
            "what is on",
            "on now",
            "visible",
            "shown",
            "window",
            "desktop",
            "here"
        ]
        return screenPhrases.contains { lowercased.contains($0) }
    }
    
    // MARK: - Voice
    
    func startVoiceConversation() {
        guard let threadId = currentThreadId else {
            conversationHistory.append(ChatMessage(role: .error, content: "Voice unavailable: no active conversation thread yet."))
            return
        }
        guard !isVoiceSessionActive, pendingRealtimeStartThreadId == nil else { return }
        
        orbState = .processing
        pendingRealtimeStartThreadId = threadId
        
        Task {
            do {
                try await codex.startRealtime(threadId: threadId)
                self.failRealtimeStartIfNeeded(threadId: threadId)
            } catch {
                self.pendingRealtimeStartThreadId = nil
                self.failVoiceConversation(error.localizedDescription)
            }
        }
    }
    
    func stopVoiceConversation() {
        guard let threadId = currentThreadId else {
            endVoiceLocally()
            return
        }

        orbState = .processing
        
        Task {
            try? await codex.stopRealtime(threadId: threadId)
            self.endVoiceLocally()
        }
    }

    private func failRealtimeStartIfNeeded(threadId: String) {
        Task {
            try? await Task.sleep(for: .seconds(8))
            guard self.pendingRealtimeStartThreadId == threadId else { return }
            self.pendingRealtimeStartThreadId = nil
            self.failVoiceConversation("Timed out waiting for realtime session to start.")
        }
    }

    private func startRealtimeAudioIO(threadId: String) {
        sendRealtimeScreenSnapshot(threadId: threadId, reason: "voice session started")
        startRealtimeScreenSnapshots(threadId: threadId)
        audioPlayer.start()

        audioCapture.onAudioData = { [weak self] pcmData in
            Task { @MainActor in
                guard let self, threadId == self.currentThreadId, self.isRealtimeActive else { return }
                do {
                    try await self.codex.appendAudio(threadId: threadId, pcmData: pcmData)
                } catch {
                    print("⚠️ Failed to append realtime audio: \(error.localizedDescription)")
                }
            }
        }

        do {
            try audioCapture.start()
        } catch {
            failVoiceConversation(error.localizedDescription)
        }
    }

    private func handleRealtimeTranscript(role: String, text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        switch role {
        case "assistant":
            conversationHistory.append(ChatMessage(role: .assistant, content: trimmed))
            orbState = .speaking
        case "user":
            conversationHistory.append(ChatMessage(role: .user, content: trimmed))
            orbState = .listening
        default:
            conversationHistory.append(ChatMessage(role: .system, content: trimmed))
        }
    }

    private func failVoiceConversation(_ message: String) {
        endVoiceLocally()
        conversationHistory.append(ChatMessage(role: .error, content: "Voice unavailable: \(message)"))
        print("❌ Voice failed: \(message)")
    }

    private func endVoiceLocally() {
        if audioCapture.isRunning {
            audioCapture.stop()
        }
        audioCapture.onAudioData = nil
        audioPlayer.stop()
        realtimeScreenTimer?.invalidate()
        realtimeScreenTimer = nil
        isRealtimeActive = false
        isVoiceSessionActive = false
        pendingRealtimeStartThreadId = nil
        orbState = .idle
    }

    private func startRealtimeScreenSnapshots(threadId: String) {
        realtimeScreenTimer?.invalidate()
        realtimeScreenTimer = Timer.scheduledTimer(withTimeInterval: 8.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.sendRealtimeScreenSnapshot(threadId: threadId, reason: "periodic voice screen update")
            }
        }
    }

    private func sendRealtimeScreenSnapshot(threadId: String, reason: String) {
        guard isRealtimeActive, threadId == currentThreadId else { return }
        guard let screenshot = screenStreamer.captureNow() else {
            if !PermissionsManager.shared.checkScreenRecording() {
                conversationHistory.append(
                    ChatMessage(
                        role: .system,
                        content: "Screen Recording permission is needed for voice screen context. Grant it in System Settings, then relaunch Aura."
                    )
                )
            }
            print("⚠️ Realtime screen snapshot skipped: capture failed")
            return
        }

        Task {
            do {
                try await codex.appendImage(threadId: threadId, imagePath: screenshot.path, detail: "low")
                try await codex.appendText(
                    threadId: threadId,
                    text: "Screen context update (\(reason)). Use the attached image as the user's current screen. Do not respond just to acknowledge this update."
                )
            } catch {
                print("⚠️ Realtime screen snapshot failed: \(error.localizedDescription)")
            }
        }
    }
    
    // MARK: - Screen Streaming
    
    private func startScreenStreaming() {
        guard !isScreenStreaming else { return }
        isScreenStreaming = true
        screenStreamer.start(fps: 1.0)
    }

    private func stopScreenStreaming() {
        guard isScreenStreaming else { return }
        isScreenStreaming = false
        screenStreamer.stop()
    }
    
    private func handleScreenFrame(_ url: URL) {
        // Feed screen frames to the active thread periodically
        // This gives Aura continuous awareness of what's on screen
        // Frames are lightweight — Codex handles vision natively
        
        // For proactive scanning, feed to nudge engine
        if proactivityLevel != .silent {
            // Every ~10 frames (10 seconds at 1fps), run a scan
            nudgeEngine.analyzeScreen(
                context: "Analyze this screen frame for a useful proactive nudge.",
                imagePath: url.path
            )
        }
    }
    
    // MARK: - Proactivity
    
    func setProactivity(_ level: NudgeEngine.ProactivityLevel) {
        proactivityLevel = level
        nudgeEngine.setLevel(level)
        if level == .silent {
            stopScreenStreaming()
            nudgeEngine.stopScanning()
        } else {
            startScreenStreaming()
            nudgeEngine.startScanning()
        }
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
        beginChatGPTLogin()
    }

    func switchChatGPTAccount() {
        Task {
            await clearCurrentAccount()
            beginChatGPTLogin()
        }
    }

    func signOut() {
        Task {
            await clearCurrentAccount()
        }
    }

    func reconnect() {
        shutdown()
        currentThreadId = nil
        connectionState = .connecting
        startCodexAndConnect()
    }

    private func beginChatGPTLogin() {
        Task {
            do {
                let tokens = try await ChatGPTAuth.shared.signInAndWait()
                guard let accountId = tokens.chatgptAccountId else {
                    throw AuthError.authFailed("ChatGPT token did not include an account id")
                }
                try await codex.loginWithChatGPTAuthTokens(
                    accessToken: tokens.accessToken,
                    accountId: accountId,
                    planType: tokens.plan
                )
                await refreshAccountAndStart()
            } catch {
                print("❌ Login failed: \(error)")
                connectionState = .error(error.localizedDescription)
            }
        }
    }

    private func clearCurrentAccount() async {
        ChatGPTAuth.shared.signOut()
        do {
            try await codex.logoutAccount()
            accountEmail = nil
            accountPlan = nil
            currentThreadId = nil
            conversationHistory.removeAll()
            connectionState = .authenticating
        } catch {
            connectionState = .error(error.localizedDescription)
        }
    }
    
    // MARK: - Events
    
    private func handleTurnEvent(_ event: TurnEvent) {
        switch event {
        case .started(let threadId):
            guard threadId == currentThreadId else { return }
            orbState = .processing
            
        case .completed(let threadId):
            if nudgeEngine.isScanThread(threadId) {
                let text = scanResponseBuffers.removeValue(forKey: threadId) ?? ""
                nudgeEngine.handleScanResult(text)
                return
            }
            guard threadId == currentThreadId else { return }
            orbState = .idle
            
        case .agentMessage(let threadId, let text):
            if nudgeEngine.isScanThread(threadId) {
                scanResponseBuffers[threadId, default: ""] += text
                return
            }
            guard threadId == currentThreadId else { return }
            if let lastIndex = conversationHistory.indices.last,
               conversationHistory[lastIndex].role == .assistant {
                conversationHistory[lastIndex].content += text
            } else {
                conversationHistory.append(ChatMessage(role: .assistant, content: text))
            }
            orbState = .speaking
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                if self?.orbState == .speaking { self?.orbState = .idle }
            }
            
        case .toolCall(let name, let args):
            let detail = "\(name) \(args.map { "\($0.key)=\($0.value)" }.joined(separator: " "))"
            conversationHistory.append(ChatMessage(role: .system, content: "🔧 \(detail)"))
            
        case .error(let threadId, let message):
            if nudgeEngine.isScanThread(threadId) {
                scanResponseBuffers.removeValue(forKey: threadId)
                return
            }
            guard threadId == currentThreadId else { return }
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
        if let process = codexProcess {
            process.terminate()
            process.waitUntilExit()
            codexProcess = nil
        }
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
    var content: String
    
    enum Role {
        case user
        case assistant
        case system
        case error
    }
}
