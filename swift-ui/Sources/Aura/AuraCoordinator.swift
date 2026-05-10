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
    @Published private(set) var inputLevel: Float = 0   // 0..1, smoothed RMS from mic
    @Published private(set) var outputLevel: Float = 0  // 0..1, smoothed RMS from speaker

    // MARK: - Components
    private let codex = CodexClient()
    private var realtimeClient: RealtimeClient?
    private let audioCapture = AudioCapture()
    private let audioPlayer = AudioPlayer()
    private let screenStreamer = ScreenStreamer()
    private let nudgeEngine = NudgeEngine()
    let memes = MemeReactionEngine()
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
    private var realtimeResponseBuffer = ""
    private var realtimeOutputAudioEnabled = false
    private var idleSince: Date? = Date()
    private var boredomTimer: Timer?
    
    // MARK: - Setup
    
    func startCodexAndConnect() {
        connectionState = .connecting

        // Audio-level signals → published levels
        audioCapture.onLevel = { [weak self] level in
            guard let self else { return }
            self.inputLevel = 0.7 * self.inputLevel + 0.3 * level
        }
        audioPlayer.onLevel = { [weak self] level in
            guard let self else { return }
            self.outputLevel = 0.7 * self.outputLevel + 0.3 * level
        }

        setupReactionObservers()

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

    // MARK: - Meme reaction observers

    private func setupReactionObservers() {
        // Startled: loud mic spike while Aura is speaking → user barged in.
        // The MemeReactionEngine cooldown prevents re-fires within 1.5s.
        $inputLevel
            .combineLatest($orbState)
            .filter { level, state in state == .speaking && level > 0.55 }
            .throttle(for: .milliseconds(200), scheduler: RunLoop.main, latest: false)
            .sink { [weak self] _, _ in
                self?.memes.fire(.startled)
            }
            .store(in: &cancellables)

        // Boredom: track when idle started; fire after 180s of continuous idle.
        $orbState
            .sink { [weak self] state in
                guard let self else { return }
                if state == .idle {
                    if self.idleSince == nil { self.idleSince = Date() }
                } else {
                    self.idleSince = nil
                }
            }
            .store(in: &cancellables)

        boredomTimer?.invalidate()
        boredomTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let since = self.idleSince else { return }
                if Date().timeIntervalSince(since) > 180 {
                    self.memes.fire(.bored)
                    self.idleSince = Date()  // reset so it doesn't refire every minute
                }
            }
        }

        // Decay output level when no audio is being scheduled.
        Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.outputLevel *= 0.85
                if self.outputLevel < 0.001 { self.outputLevel = 0 }
                if self.orbState != .listening { self.inputLevel *= 0.85 }
                if self.inputLevel < 0.001 { self.inputLevel = 0 }
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
    
    @discardableResult
    private func ensureCodexThread() async throws -> String {
        if let currentThreadId { return currentThreadId }

        let cwd = defaultThreadCwd
        let thread = try await codex.startThread(
            cwd: cwd,
            instructions: codexThreadInstructions,
            config: realtimeThreadConfig,
            approvalPolicy: "on-failure",
            sandbox: "workspace-write",
            approvalsReviewer: "user"
        )
        self.currentThreadId = thread.id
        self.connectionState = .connected
        print("🧵 Codex thread: \(thread.id) (model: \(thread.model), cwd: \(cwd))")
        return thread.id
    }

    private var codexThreadInstructions: String {
        """
        You are Aura's tool-and-work executor on the user's Mac desktop.
        Use tools, shell, files, and skills when the user's request needs local execution, codebase work, web/file lookup, or durable changes.
        Be concise and report the concrete result.
        """
    }

    private var realtimeConversationInstructions: String {
        """
        You are Aura, a persistent AI companion on the user's Mac desktop.
        You are the realtime voice and casual conversation layer.
        Be concise, friendly, and proactive. Help with general questions, brainstorming, screen-aware discussion, and voice conversation.
        You do not have tools in this realtime layer. If the user asks you to run commands, edit files, use skills, inspect a repo, browse, fetch, install, build, test, or perform an external action, tell them you will hand it to the tool layer.

        You are not a chatbot. You are a companion that participates in their work.
        """
    }

    private var realtimeThreadConfig: [String: Any] {
        [
            "features.realtime_conversation": true,
            "realtime.version": "v2",
            "realtime.type": "conversational",
            "realtime.transport": "websocket",
            "sandbox_workspace_write.network_access": true
        ]
    }

    private var defaultThreadCwd: String {
        let fileManager = FileManager.default
        if let override = ProcessInfo.processInfo.environment["AURA_CWD"],
           fileManager.fileExists(atPath: override) {
            return override
        }

        let appURL = Bundle.main.bundleURL.standardizedFileURL
        let buildDir = appURL.deletingLastPathComponent()
        let swiftUIDir = buildDir.deletingLastPathComponent()
        let repoDir = swiftUIDir.deletingLastPathComponent()
        let candidates = [repoDir, swiftUIDir]

        for candidate in candidates {
            let gitPath = candidate.appendingPathComponent(".git").path
            let packagePath = candidate.appendingPathComponent("Package.swift").path
            if fileManager.fileExists(atPath: gitPath) || fileManager.fileExists(atPath: packagePath) {
                return candidate.path
            }
        }

        return NSHomeDirectory()
    }
    
    // MARK: - Text Chat
    
    func sendMessage(_ text: String) async {
        conversationHistory.append(ChatMessage(role: .user, content: text))
        orbState = .processing
        
        do {
            if shouldUseCodexTools(for: text) {
                let threadId = try await ensureCodexThread()
                try await sendCodexMessage(text, threadId: threadId)
            } else {
                try await sendRealtimeMessage(text)
            }
        } catch {
            orbState = .idle
            conversationHistory.append(ChatMessage(role: .error, content: error.localizedDescription))
            memes.fire(.error)
        }
    }

    private func sendCodexMessage(_ text: String, threadId: String) async throws {
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
            print("⚠️ Sending Codex turn without screen context")
        }
        try await codex.startTurn(
            threadId: threadId,
            message: text,
            localImagePath: screenshot?.path
        )
    }

    private func sendRealtimeMessage(_ text: String) async throws {
        try await ensureRealtimeConversation(outputAudio: isVoiceSessionActive)
        let shouldIncludeScreen = shouldAttachScreen(to: text)
        let screenshot = shouldIncludeScreen ? screenStreamer.captureNow() : nil
        if shouldIncludeScreen && screenshot == nil && !PermissionsManager.shared.checkScreenRecording() {
            conversationHistory.append(
                ChatMessage(
                    role: .system,
                    content: "Screen Recording permission is needed for realtime screen context. Grant it in System Settings, then relaunch Aura."
                )
            )
        }
        realtimeResponseBuffer = ""
        realtimeClient?.sendUserText(
            text,
            imagePath: screenshot?.path,
            createResponse: true,
            outputAudio: isVoiceSessionActive
        )
    }

    private func shouldUseCodexTools(for text: String) -> Bool {
        let lowercased = text.lowercased()
        let toolPhrases = [
            "use tool",
            "use tools",
            "use skill",
            "use skills",
            "run ",
            "execute",
            "shell",
            "terminal",
            "command",
            "build",
            "test",
            "compile",
            "edit",
            "change",
            "modify",
            "patch",
            "fix",
            "file",
            "repo",
            "codebase",
            "project",
            "git",
            "commit",
            "push",
            "pull",
            "install",
            "download",
            "fetch",
            "search",
            "browse",
            "open ",
            "scrape",
            "read ",
            "write ",
            "delete",
            "move",
            "rename",
            "deploy"
        ]
        return toolPhrases.contains { lowercased.contains($0) }
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

    private func ensureRealtimeConversation(outputAudio: Bool) async throws {
        if let realtimeClient, realtimeClient.isConnected, realtimeOutputAudioEnabled == outputAudio {
            return
        }

        guard let token = await ChatGPTAuth.shared.ensureValidToken() else {
            throw AuthError.authFailed("ChatGPT auth token is unavailable. Sign in again.")
        }
        let accountId = ChatGPTAuth.shared.currentChatGPTAccountId()
        guard let accountId, !accountId.isEmpty else {
            throw AuthError.authFailed("ChatGPT account id is missing. Sign out and sign in again so Aura can refresh ChatGPT auth.")
        }

        if let realtimeClient, realtimeClient.isConnected {
            realtimeClient.disconnect()
        }

        let client = RealtimeClient()
        wireRealtimeClient(client)
        try await client.connect(
            accessToken: token,
            accountId: accountId,
            model: FlowConfig.load().realtimeModel,
            mode: .conversation(
                instructions: realtimeConversationInstructions,
                outputAudio: outputAudio
            ),
            backendMode: true
        )
        realtimeClient = client
        realtimeOutputAudioEnabled = outputAudio
    }

    private func wireRealtimeClient(_ client: RealtimeClient) {
        client.onFinalTranscript = { [weak self] text in
            Task { @MainActor in
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard let self, !trimmed.isEmpty else { return }
                self.conversationHistory.append(ChatMessage(role: .user, content: trimmed))
                self.orbState = .processing
            }
        }

        client.onResponseTextDelta = { [weak self] delta in
            Task { @MainActor in
                self?.appendRealtimeAssistantDelta(delta)
            }
        }

        client.onResponseTextDone = { [weak self] text in
            Task { @MainActor in
                self?.finishRealtimeAssistantText(text)
            }
        }

        client.onAudioResponse = { [weak self] data in
            Task { @MainActor in
                guard let self else { return }
                if !self.isVoiceSessionActive {
                    self.audioPlayer.start()
                }
                self.orbState = .speaking
                self.audioPlayer.enqueue(data)
            }
        }

        client.onSpeechStarted = { [weak self] in
            Task { @MainActor in
                self?.orbState = .listening
            }
        }

        client.onSpeechEnded = { [weak self] in
            Task { @MainActor in
                self?.orbState = .processing
            }
        }

        client.onResponseComplete = { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.realtimeResponseBuffer = ""
                self.orbState = self.isVoiceSessionActive ? .listening : .idle
            }
        }

        client.onError = { [weak self] message in
            Task { @MainActor in
                guard let self else { return }
                self.orbState = .idle
                self.conversationHistory.append(ChatMessage(role: .error, content: "Realtime unavailable: \(message)"))
                self.memes.fire(.error)
            }
        }
    }

    private func appendRealtimeAssistantDelta(_ delta: String) {
        guard !delta.isEmpty else { return }
        if realtimeResponseBuffer.isEmpty {
            conversationHistory.append(ChatMessage(role: .assistant, content: delta))
        } else if let lastIndex = conversationHistory.indices.last,
                  conversationHistory[lastIndex].role == .assistant {
            conversationHistory[lastIndex].content += delta
        } else {
            conversationHistory.append(ChatMessage(role: .assistant, content: delta))
        }
        realtimeResponseBuffer += delta
        orbState = .speaking
    }

    private func finishRealtimeAssistantText(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if realtimeResponseBuffer.isEmpty, !trimmed.isEmpty {
            conversationHistory.append(ChatMessage(role: .assistant, content: trimmed))
        }
        realtimeResponseBuffer = ""
    }

    // MARK: - Voice
    
    func startVoiceConversation() {
        guard !isVoiceSessionActive, pendingRealtimeStartThreadId == nil else { return }
        
        orbState = .processing
        
        Task {
            do {
                try await ensureRealtimeConversation(outputAudio: true)
                startDirectRealtimeAudioIO()
            } catch {
                self.pendingRealtimeStartThreadId = nil
                self.failVoiceConversation(error.localizedDescription)
            }
        }
    }
    
    func stopVoiceConversation() {
        orbState = .processing
        endVoiceLocally(disconnectRealtime: true)
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

    private func startDirectRealtimeAudioIO() {
        sendDirectRealtimeScreenSnapshot(reason: "voice session started")
        startDirectRealtimeScreenSnapshots()
        audioPlayer.start()

        audioCapture.onAudioData = { [weak self] pcmData in
            self?.realtimeClient?.sendAudio(pcmData)
        }

        do {
            try audioCapture.start()
            isRealtimeActive = true
            isVoiceSessionActive = true
            pendingRealtimeStartThreadId = nil
            orbState = .listening
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
        memes.fire(.error)
        print("❌ Voice failed: \(message)")
    }

    private func endVoiceLocally(disconnectRealtime: Bool = false) {
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
        if disconnectRealtime {
            realtimeClient?.disconnect()
            realtimeClient = nil
        }
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

    private func startDirectRealtimeScreenSnapshots() {
        realtimeScreenTimer?.invalidate()
        realtimeScreenTimer = Timer.scheduledTimer(withTimeInterval: 8.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.sendDirectRealtimeScreenSnapshot(reason: "periodic voice screen update")
            }
        }
    }

    private func sendDirectRealtimeScreenSnapshot(reason: String) {
        guard let realtimeClient, realtimeClient.isConnected else { return }
        guard let screenshot = screenStreamer.captureNow() else {
            if !PermissionsManager.shared.checkScreenRecording() {
                conversationHistory.append(
                    ChatMessage(
                        role: .system,
                        content: "Screen Recording permission is needed for voice screen context. Grant it in System Settings, then relaunch Aura."
                    )
                )
            }
            print("⚠️ Direct realtime screen snapshot skipped: capture failed")
            return
        }
        realtimeClient.sendScreenContext(imagePath: screenshot.path, reason: reason)
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
        realtimeClient?.disconnect()
        realtimeClient = nil
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
            memes.fire(.success)

        case .error(let threadId, let message):
            if nudgeEngine.isScanThread(threadId) {
                scanResponseBuffers.removeValue(forKey: threadId)
                return
            }
            guard threadId == currentThreadId else { return }
            orbState = .idle
            conversationHistory.append(ChatMessage(role: .error, content: message))
            memes.fire(.error)
        }
    }
    
    // MARK: - Cleanup
    
    func shutdown() {
        screenStreamer.stop()
        screenStreamer.cleanup()
        nudgeEngine.stopScanning()
        audioCapture.stop()
        audioPlayer.stop()
        realtimeClient?.disconnect()
        realtimeClient = nil
        boredomTimer?.invalidate()
        boredomTimer = nil
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
