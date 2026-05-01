import Foundation

/// WebSocket client for OpenAI's Realtime API.
///
/// Matches Codex CLI v2 protocol:
/// - Transcription mode: dedicated STT with gpt-4o-transcribe
/// - Voice chat mode: conversational with server VAD
/// - Audio: PCM16 24kHz mono
///
/// Auth: Bearer token from ChatGPT OAuth (subscription) or API key.
final class RealtimeClient {
    // MARK: - Callbacks

    var onConnected: (() -> Void)?
    var onDisconnected: (() -> Void)?
    var onPartialTranscript: ((String) -> Void)?
    var onFinalTranscript: ((String) -> Void)?
    var onAudioResponse: ((Data) -> Void)?
    var onSpeechStarted: (() -> Void)?
    var onSpeechEnded: (() -> Void)?
    var onResponseComplete: (() -> Void)?
    var onError: ((String) -> Void)?

    // MARK: - State

    private var webSocket: URLSessionWebSocketTask?
    private(set) var isConnected = false
    private var partialText = ""

    // MARK: - Connection

    enum ConnectionMode {
        case dictation(language: String)
    }

    func connect(accessToken: String, model: String = FlowConfig.load().realtimeModel, mode: ConnectionMode, backendMode: Bool = false) async throws {
        let urlString = "wss://api.openai.com/v1/realtime?model=\(model)"

        guard let url = URL(string: urlString) else {
            throw RealtimeError.invalidURL
        }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("realtime=v1", forHTTPHeaderField: "OpenAI-Beta")

        print("🔌 Connecting to Realtime API: \(urlString) (backend: \(backendMode))")

        let session = URLSession(configuration: .ephemeral)
        let ws = session.webSocketTask(with: request)
        self.webSocket = ws
        ws.resume()

        try await Task.sleep(for: .milliseconds(300))

        isConnected = true
        print("🔌 Connected to Realtime API (\(model))")

        // Configure session
        try await configureSession(mode: mode)

        // Start receiving
        receiveLoop()

        onConnected?()
    }

    func disconnect() {
        isConnected = false
        webSocket?.cancel(with: .normalClosure, reason: nil)
        webSocket = nil
        partialText = ""
        onDisconnected?()
        print("🔌 Disconnected from Realtime API")
    }

    // MARK: - Session Configuration

    private func configureSession(mode: ConnectionMode) async throws {
        let sessionConfig: String

        switch mode {
        case .dictation(let lang):
            let config = FlowConfig.load()
            let instructions = ContextManager.shared.buildInstructions(config: config)

            var transConfig = """
            {"model":"\(config.transcriptionModel)","language":"\(lang)"
            """
            if let prompt = config.transcriptionPrompt, !prompt.isEmpty {
                transConfig += ",\"prompt\":\"\(prompt.escapingJSON)\""
            }
            transConfig += "}"

            var noiseReductionConfig = ""
            if let nr = config.inputAudioNoiseReduction {
                noiseReductionConfig = ",\"input_audio_noise_reduction\":{\"type\":\"\(nr)\"}"
            }

            sessionConfig = """
            {
                "type": "session.update",
                "session": {
                    "modalities": ["text"],
                    "instructions": "\(instructions.escapingJSON)",
                    "input_audio_format": "\(config.inputAudioFormat)",
                    "output_audio_format": "\(config.outputAudioFormat)",
                    "input_audio_transcription": \(transConfig),
                    "turn_detection": null,
                    "max_response_output_tokens": \(config.maxResponseOutputTokens),
                    "temperature": \(config.temperature)\(noiseReductionConfig)
                }
            }
            """

            print("📋 ═══ INITIAL SESSION CONFIG ═══")
            print("📋 model: \(config.realtimeModel)")
            print("📋 transcription_model: \(config.transcriptionModel)")
            print("📋 temperature: \(config.temperature)")
            print("📋 max_tokens: \(config.maxResponseOutputTokens)")
            print("📋 audio_format: \(config.inputAudioFormat)")
            print("📋 noise_reduction: \(config.inputAudioNoiseReduction ?? "off")")
            print("📋 transcription_prompt: \(config.transcriptionPrompt ?? "nil")")
            print("📋 instructions (first 200): \(instructions.prefix(200))\(instructions.count > 200 ? "..." : "")")
            print("📋 ═══════════════════════════")
        }

        try send(sessionConfig)
    }

    // MARK: - Audio Input

    func sendAudio(_ pcm16Data: Data) {
        guard isConnected else { return }
        let base64 = pcm16Data.base64EncodedString()
        let event = """
        {"type":"input_audio_buffer.append","audio":"\(base64)"}
        """
        do {
            try send(event)
        } catch {
            print("⚠️ Failed to send audio chunk: \(error)")
        }
    }

    func commitAndRespond() {
        guard isConnected else { return }
        try? send("""
        {"type":"input_audio_buffer.commit"}
        """)
        try? send("""
        {"type":"response.create","response":{"modalities":["text"]}}
        """)
    }

    /// Update session instructions with current context (active app, etc.)
    /// Call this right before recording starts so the app context is fresh.
    /// NOTE: instructions = base prompt + vocabulary (for the overall model)
    ///        transcription prompt = text field context (for the STT model specifically)
    func refreshInstructions(language: String, transcriptionPrompt: String? = nil) {
        guard isConnected else { return }
        let config = FlowConfig.load()
        let instructions = ContextManager.shared.buildInstructions(config: config)

        // Use config-level transcription prompt unless overridden
        let effectivePrompt = transcriptionPrompt ?? config.transcriptionPrompt

        var transConfig = """
        {"model":"\(config.transcriptionModel)","language":"\(language)"
        """
        if let prompt = effectivePrompt, !prompt.isEmpty {
            transConfig += ",\"prompt\":\"\(prompt.escapingJSON)\""
        }
        transConfig += "}"

        let event = """
        {"type":"session.update","session":{"instructions":"\(instructions.escapingJSON)","input_audio_transcription":\(transConfig),"temperature":\(config.temperature)}}
        """

        // Log the full context being sent
        print("📋 ═══ SESSION REFRESH ═══")
        print("📋 transcription_model: \(config.transcriptionModel)")
        print("📋 temperature: \(config.temperature)")
        print("📋 transcription_prompt: \(effectivePrompt?.description ?? "nil")")
        print("📋 instructions (first 300): \(instructions.prefix(300))\(instructions.count > 300 ? "..." : "")")
        print("📋 ═══════════════════")

        try? send(event)
    }

    /// Send a system message mid-session (for dynamic context like screen content).
    /// This is lighter-weight than session.update for small context changes.
    func sendSystemMessage(_ text: String) {
        guard isConnected else { return }
        let event = """
        {"type":"conversation.item.create","item":{"type":"message","role":"system","content":[{"type":"input_text","text":"\(text.escapingJSON)"}]}}
        """
        try? send(event)
        print("📋 System message sent: \(text.prefix(150))\(text.count > 150 ? "..." : "")")
    }

    func cancelResponse() {
        guard isConnected else { return }
        try? send("""
        {"type":"response.cancel"}
        """)
    }

    // MARK: - Sending

    func send(_ message: String) throws {
        guard let ws = webSocket else { throw RealtimeError.notConnected }
        ws.send(.string(message)) { error in
            if let error { print("⚠️ WebSocket send: \(error.localizedDescription)") }
        }
    }

    // MARK: - Receiving

    private func receiveLoop() {
        guard let ws = webSocket, isConnected else { return }

        ws.receive { [weak self] result in
            guard let self, self.isConnected else { return }

            switch result {
            case .success(let message):
                switch message {
                case .string(let json): self.handleEvent(json)
                case .data(let d):
                    if let s = String(data: d, encoding: .utf8) { self.handleEvent(s) }
                @unknown default: break
                }
                self.receiveLoop()

            case .failure(let err):
                if self.isConnected {
                    print("⚠️ WebSocket error: \(err)")
                    self.onError?(err.localizedDescription)
                    self.isConnected = false
                }
            }
        }
    }

    private func handleEvent(_ json: String) {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = obj["type"] as? String else { return }

        switch type {
        // Session lifecycle
        case "session.created":
            print("  ✅ Session created")

        case "session.updated":
            // Log what the server confirmed — proves our params were accepted
            if let session = obj["session"] as? [String: Any] {
                print("  ✅ Session configured (server confirmed):")
                print("    📋 model: \(session["model"] as? String ?? "?")")
                if let trans = session["input_audio_transcription"] as? [String: Any] {
                    print("    📋 transcription_model: \(trans["model"] as? String ?? "?")")
                    print("    📋 transcription_language: \(trans["language"] as? String ?? "?")")
                }
                if let temp = session["temperature"] { print("    📋 temperature: \(temp)") }
                if let maxTok = session["max_response_output_tokens"] { print("    📋 max_tokens: \(maxTok)") }
                if let mod = session["modalities"] { print("    📋 modalities: \(mod)") }
                if let nr = session["input_audio_noise_reduction"] as? [String: Any] {
                    print("    📋 noise_reduction: \(nr["type"] as? String ?? "?")")
                } else {
                    print("    📋 noise_reduction: off")
                }
                if let instr = session["instructions"] as? String {
                    print("    📋 instructions (first 100): \(instr.prefix(100))...")
                }
            } else {
                print("  ✅ Session configured")
            }

        // Input audio transcription (gpt-4o-transcribe — primary STT)
        // This is the server-side transcription of what was actually spoken.
        case "conversation.item.input_audio_transcription.delta":
            if let delta = obj["delta"] as? String {
                partialText += delta
                onPartialTranscript?(partialText)
            }

        case "conversation.item.input_audio_transcription.completed":
            if let t = obj["transcript"] as? String {
                partialText = t
                onFinalTranscript?(t)
            }

        // Response text (model output — fallback if no transcription event)
        case "response.text.delta":
            if let delta = obj["delta"] as? String, partialText.isEmpty {
                partialText += delta
                onPartialTranscript?(partialText)
            }

        case "response.text.done":
            if let t = obj["text"] as? String, partialText.isEmpty {
                partialText = t
                onFinalTranscript?(t)
            }

        // Response audio (future voice chat mode)
        case "response.audio.delta":
            if let b64 = obj["delta"] as? String,
               let audioData = Data(base64Encoded: b64) {
                onAudioResponse?(audioData)
            }

        case "response.audio.done":
            break

        // Rate limits
        case "rate_limits.updated":
            print("  📊 Rate limits raw: \(json)")

        // Response lifecycle
        case "response.done":
            onResponseComplete?()
            partialText = ""

        // Speech detection
        case "input_audio_buffer.speech_started":
            onSpeechStarted?()

        case "input_audio_buffer.speech_stopped":
            onSpeechEnded?()

        // Audio buffer
        case "input_audio_buffer.committed":
            break

        // Conversation item
        case "conversation.item.created":
            break

        // Errors
        case "error":
            let msg = (obj["error"] as? [String: Any])?["message"] as? String ?? json
            print("  ❌ Error: \(msg)")
            onError?(msg)

        default:
            if !type.hasPrefix("session.") && !type.hasPrefix("input_audio_buffer.speech") {
                print("  📨 Event: \(type)")
            }
        }
    }
}

enum RealtimeError: LocalizedError {
    case invalidURL
    case notConnected
    case authFailed

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "Invalid Realtime API URL"
        case .notConnected: return "Not connected to Realtime API"
        case .authFailed: return "Authentication failed"
        }
    }
}

// MARK: - String JSON Escaping

extension String {
    /// Escape a string for embedding inside a JSON string value.
    /// Handles: backslash, double-quote, newline, carriage return, tab,
    /// and control characters (U+0000..U+001F) per RFC 8259 §7.
    var escapingJSON: String {
        var result = ""
        result.reserveCapacity(count)
        for char in self {
            switch char {
            case "\\": result += "\\\\"
            case "\"": result += "\\\""
            case "\n":  result += "\\n"
            case "\r":  result += "\\r"
            case "\t":  result += "\\t"
            default:
                if char.asciiValue.map({ $0 < 0x20 }) ?? false {
                    // Control character — encode as \u00XX
                    let hex = String(format: "\\u%04x", char.asciiValue!)
                    result += hex
                } else {
                    result.append(char)
                }
            }
        }
        return result
    }
}
