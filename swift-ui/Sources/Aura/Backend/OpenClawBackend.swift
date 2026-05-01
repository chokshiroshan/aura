import Foundation

/// OpenClaw backend — connects to user's self-hosted OpenClaw gateway.
/// Full experience: shared memory, skills, multi-device sync.
///
/// Setup: user provides their gateway URL + API key (or scans QR from OpenClaw).
///
/// Communication: REST API for text, WebSocket for real-time voice.
final class OpenClawBackend: AuraBackend {
    var onConnected: (() -> Void)?
    var onError: ((Error) -> Void)?
    var onAudioResponse: (() -> Void)?
    var onResponseDone: (() -> Void)?
    var onMemoryUpdate: (([MemoryEntry]) -> Void)?

    private let gatewayURL: String
    private let apiKey: String
    private var webSocket: URLSessionWebSocketTask?
    private var isConnected = false

    init(gatewayURL: String, apiKey: String) {
        self.gatewayURL = gatewayURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        self.apiKey = apiKey
    }

    // MARK: - Connection

    func connect() {
        guard let url = URL(string: "\(gatewayURL)/v1/sessions") else {
            onError?(BackendError.invalidURL)
            return
        }

        // Verify connection with a simple ping
        var request = URLRequest(url: url)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            if let error = error {
                DispatchQueue.main.async { self?.onError?(error) }
                return
            }

            if let httpResponse = response as? HTTPURLResponse,
               httpResponse.statusCode == 200 || httpResponse.statusCode == 201 {
                DispatchQueue.main.async {
                    self?.isConnected = true
                    self?.onConnected?()
                }
                // Open WebSocket for real-time communication
                self?.openWebSocket()
            } else {
                DispatchQueue.main.async {
                    self?.onError?(BackendError.authenticationFailed(
                        "HTTP \( (response as? HTTPURLResponse)?.statusCode ?? 0)"
                    ))
                }
            }
        }.resume()
    }

    func disconnect() {
        webSocket?.cancel(with: .normalClosure, reason: nil)
        webSocket = nil
        isConnected = false
    }

    // MARK: - Text

    func sendText(_ text: String) async -> String {
        guard isConnected else { return "Not connected to OpenClaw." }

        // Send via REST API to OpenClaw gateway
        guard let url = URL(string: "\(gatewayURL)/v1/chat") else {
            return "Invalid gateway URL."
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body = ["message": text, "session": "orb-desktop"]
        request.httpBody = try? JSONEncoder().encode(body)

        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            let response = try JSONDecoder().decode(OpenClawResponse.self, from: data)
            return response.content
        } catch {
            return "Error: \(error.localizedDescription)"
        }
    }

    // MARK: - Audio (via WebSocket to OpenClaw)

    func startAudioCapture() {
        // TODO: Capture mic audio → encode PCM16 → send via WebSocket
        // OpenClaw gateway will forward to whatever LLM is configured
    }

    func stopAudioCapture() {
        // TODO: Stop capture, wait for response
    }

    // MARK: - Memory

    func getMemory() async -> [MemoryEntry] {
        guard let url = URL(string: "\(gatewayURL)/v1/memory") else { return [] }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            return try JSONDecoder().decode([MemoryEntry].self, from: data)
        } catch {
            return []
        }
    }

    // MARK: - WebSocket

    private func openWebSocket() {
        guard let url = URL(string: gatewayURL.replacingOccurrences(of: "https://", with: "wss://")
            .replacingOccurrences(of: "http://", with: "ws://") + "/v1/realtime") else { return }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let session = URLSession(configuration: .default)
        webSocket = session.webSocketTask(with: request)
        webSocket?.resume()

        // Start listening for messages
        receiveWebSocketMessage()
    }

    private func receiveWebSocketMessage() {
        webSocket?.receive { [weak self] result in
            switch result {
            case .success(let message):
                switch message {
                case .string(let text):
                    self?.handleWebSocketMessage(text)
                case .data(let data):
                    self?.handleWebSocketData(data)
                @unknown default:
                    break
                }
                // Continue receiving
                self?.receiveWebSocketMessage()

            case .failure(let error):
                DispatchQueue.main.async {
                    self?.onError?(error)
                }
            }
        }
    }

    private func handleWebSocketMessage(_ text: String) {
        // Parse OpenClaw realtime response
        // Could be: transcription, LLM response, memory update, etc.
        print("[Aura] WebSocket message: \(text.prefix(200))")
    }

    private func handleWebSocketData(_ data: Data) {
        // Audio response from OpenClaw
        DispatchQueue.main.async { self.onAudioResponse?() }
        // Play audio...
    }
}

// MARK: - Response Types

struct OpenClawResponse: Codable {
    let content: String
    let session: String?
}

enum BackendError: LocalizedError {
    case invalidURL
    case authenticationFailed(String)
    case notConnected

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "Invalid gateway URL"
        case .authenticationFailed(let detail): return "Authentication failed: \(detail)"
        case .notConnected: return "Not connected to OpenClaw"
        }
    }
}
