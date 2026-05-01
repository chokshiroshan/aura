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
        realtimeClient = nil
    }

    // MARK: - Realtime Connection

    private func connectRealtime() {
        guard case .signedIn(let token) = auth.authState else {
            onError?(BackendError.authenticationFailed("No token"))
            return
        }

        let client = RealtimeClient(token: token)
        client.onTranscript = { [weak self] text in
            // Save to local memory
            let entry = MemoryEntry(
                id: UUID().uuidString,
                content: text,
                timestamp: Date(),
                source: "chatgpt"
            )
            self?.localMemory.append(entry)
            self?.onMemoryUpdate?(self?.localMemory ?? [])
        }
        client.onAudioResponse = { [weak self] in
            DispatchQueue.main.async { self?.onAudioResponse?() }
        }
        client.onResponseDone = { [weak self] in
            DispatchQueue.main.async { self?.onResponseDone?() }
        }
        client.onError = { [weak self] error in
            DispatchQueue.main.async { self?.onError?(error) }
        }

        realtimeClient = client
        client.connect()
        onConnected?()
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
        realtimeClient?.startAudioCapture()
    }

    func stopAudioCapture() {
        realtimeClient?.stopAudioCapture()
    }

    // MARK: - Memory (local only)

    func getMemory() async -> [MemoryEntry] {
        return localMemory
    }
}
