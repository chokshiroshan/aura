import Foundation

/// ChatGPT backend — uses user's ChatGPT subscription via Codex OAuth.
/// No OpenClaw needed. Local memory only.
///
/// This is the "it just works" path for people who don't have OpenClaw.
final class ChatGPTBackend: AuraBackend {
    var onConnected: (() -> Void)?
    var onError: ((Error) -> Void)?
    var onAudioResponse: (() -> Void)?
    var onResponseDone: (() -> Void)?
    var onMemoryUpdate: (([MemoryEntry]) -> Void)?

    var onAuthRequired: (() -> Void)?

    private let auth = ChatGPTAuth.shared
    private var realtimeClient: RealtimeClient?
    private let audioCapture = AudioCapture()
    private var localMemory: [MemoryEntry] = []

    // MARK: - Connection

    func connect() {
        // Check if already authenticated
        if case .signedIn = auth.authState {
            connectRealtime()
            return
        }

        // Need to authenticate first
        onAuthRequired?()

        // Listen for auth state changes
        // (In practice, the UI triggers OAuth flow, then calls connect() again)
    }

    /// Call after OAuth flow completes
    func onAuthComplete() {
        connectRealtime()
    }

    func disconnect() {
        audioCapture.stop()
        audioCapture.onAudioData = nil
        realtimeClient?.disconnect()
        realtimeClient = nil
    }

    // MARK: - Realtime Connection

    private func connectRealtime() {
        Task {
            guard let token = await auth.ensureValidToken() else {
                await MainActor.run {
                    onError?(BackendError.authenticationFailed("No token"))
                }
                return
            }

            let client = RealtimeClient()
            client.onFinalTranscript = { [weak self] text in
                let entry = MemoryEntry(
                    id: UUID().uuidString,
                    content: text,
                    timestamp: Date(),
                    source: "chatgpt"
                )
                DispatchQueue.main.async {
                    self?.localMemory.append(entry)
                    self?.onMemoryUpdate?(self?.localMemory ?? [])
                }
            }
            client.onAudioResponse = { [weak self] _ in
                DispatchQueue.main.async { self?.onAudioResponse?() }
            }
            client.onResponseComplete = { [weak self] in
                DispatchQueue.main.async { self?.onResponseDone?() }
            }
            client.onError = { [weak self] message in
                DispatchQueue.main.async {
                    self?.onError?(BackendError.authenticationFailed(message))
                }
            }

            do {
                try await client.connect(
                    accessToken: token,
                    mode: .dictation(language: FlowConfig.load().language),
                    backendMode: true
                )
                await MainActor.run {
                    realtimeClient = client
                    onConnected?()
                }
            } catch {
                await MainActor.run {
                    onError?(error)
                }
            }
        }
    }

    // MARK: - Text

    func sendText(_ text: String) async -> String {
        // For ChatGPT backend, we use the Realtime API's text channel
        // (or fall back to a REST call if WebSocket isn't connected)
        return await withCheckedContinuation { continuation in
            // TODO: Send via Realtime API text channel
            // For now, simple placeholder
            continuation.resume(returning: "Response from ChatGPT")
        }
    }

    // MARK: - Audio

    func startAudioCapture() {
        audioCapture.onAudioData = { [weak self] data in
            self?.realtimeClient?.sendAudio(data)
        }

        do {
            try audioCapture.start()
        } catch {
            onError?(error)
        }
    }

    func stopAudioCapture() {
        audioCapture.stop()
        audioCapture.onAudioData = nil
        realtimeClient?.commitAndRespond()
    }

    // MARK: - Memory (local only)

    func getMemory() async -> [MemoryEntry] {
        return localMemory
    }
}
