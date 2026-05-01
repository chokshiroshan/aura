import Foundation

// MARK: - App State

/// The current operational state of the app.
enum FlowState: Equatable {
    case idle
    case connecting
    case recording
    case processing
    case injecting
    case speaking
    case error(String)

    var isRecording: Bool { self == .recording }
    var isActive: Bool { self != .idle && !isError }
    var isError: Bool { if case .error = self { return true }; return false }
}

// MARK: - Auth State

enum AuthState: Equatable {
    case signedOut
    case signingIn
    case signedIn(email: String, plan: String)
    case error(String)
}

// MARK: - Usage Tracking

/// Tracks dictation usage stats, persisted to ~/.flow/usage.json
final class UsageTracker {
    static let shared = UsageTracker()
    private let url = FlowConfig.configDir.appendingPathComponent("usage.json")

    struct Stats: Codable {
        var totalSessions: Int = 0
        var totalSeconds: Double = 0
        var monthSessions: Int = 0
        var monthSeconds: Double = 0
        var monthKey: String = ""  // "2026-04" format

        var monthMinutesDisplay: String {
            let mins = Int(monthSeconds / 60)
            if mins < 1 { return "< 1 min transcribed" }
            return "~\(mins) min transcribed"
        }
    }

    private(set) var stats = Stats()

    private init() { load() }

    func recordSession(durationSeconds: Double) {
        stats.totalSessions += 1
        stats.totalSeconds += durationSeconds

        let now = Calendar.current.component(.year, from: Date()) * 100 + Calendar.current.component(.month, from: Date())
        let key = String(now)
        if stats.monthKey != key {
            stats.monthKey = key
            stats.monthSessions = 0
            stats.monthSeconds = 0
        }
        stats.monthSessions += 1
        stats.monthSeconds += durationSeconds
        save()
    }

    private func load() {
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode(Stats.self, from: data) else { return }
        stats = decoded
    }

    private func save() {
        try? FileManager.default.createDirectory(at: FlowConfig.configDir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(stats) {
            try? data.write(to: url)
        }
    }
}

// MARK: - Configuration

struct FlowConfig: Codable {
    var hotkey: String = "ctrl+space"
    var hotkeyMode: HotkeyMode = .hold
    var language: String = "en"
    var injectMethod: InjectMethod = .clipboard
    var soundEffectsEnabled: Bool = false
    var shouldMuteAudio: Bool = true
    var autoPasteEnabled: Bool = true
    var appearance: String = "system"
    var selectedMicDeviceUID: String? = nil

    // MARK: - Realtime API Session Parameters
    // Full control over everything sent to session.update

    /// The realtime model to use for the WebSocket connection.
    var realtimeModel: String = "gpt-realtime-1.5"

    /// Which STT model to use for input_audio_transcription.
    /// Options: "gpt-4o-transcribe", "gpt-4o-transcribe-diarize", "gpt-4o-mini-transcribe", "whisper-1"
    var transcriptionModel: String = "gpt-4o-transcribe"

    /// System instructions — behavior template (templates swap this entirely).
    /// Controls HOW the model transcribes (verbatim, clean, code-friendly, etc.).
    var systemInstructions: String = "Transcribe exactly what was said. Output only the spoken words. Do not correct, interpret, or rephrase anything. Preserve the speaker's exact wording including informal speech, pauses as commas, and natural sentence structure. If there is no clear speech, output nothing."

    /// User context — personal names, terms, projects, abbreviations.
    /// Survives template switches. Appended to systemInstructions every session.
    /// Plain text, e.g. "Names: Roshan, Alice. Projects: ChatFlow, OpenClaw. Apps: Discord, VS Code."
    var userContext: String = ""

    /// Whether to include active app context (e.g. "The user is currently in Discord")
    var includeAppContext: Bool = true

    /// Whether to include vocabulary from ~/.flow/vocabulary.json
    var includeVocabulary: Bool = true

    /// The transcription prompt field (input_audio_transcription.prompt).
    /// For whisper-1, this is a list of keywords. For gpt-4o-transcribe, it's free text.
    /// Set to nil/empty to omit.
    var transcriptionPrompt: String? = nil

    /// Max response output tokens. Default 1024.
    var maxResponseOutputTokens: Int = 1024

    /// Input audio format. Default "pcm16".
    var inputAudioFormat: String = "pcm16"

    /// Output audio format. Default "pcm16".
    var outputAudioFormat: String = "pcm16"

    /// Sampling temperature for the model, limited to [0.6, 1.2].
    /// Recommended 0.8 for best performance. Lower = more deterministic.
    var temperature: Double = 0.8

    /// Noise reduction for input audio. Options: nil (disabled), "near_field", "far_field".
    var inputAudioNoiseReduction: String? = nil

    enum HotkeyMode: String, Codable, CaseIterable {
        case hold
        case toggle
    }

    enum InjectMethod: String, Codable, CaseIterable {
        case clipboard
        case accessibility
        case keystrokes
    }

    static let configDir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".flow")
    static let configPath = configDir.appendingPathComponent("config.json")

    static func load() -> FlowConfig {
        guard let data = try? Data(contentsOf: configPath),
              let config = try? JSONDecoder().decode(FlowConfig.self, from: data) else {
            return FlowConfig()
        }
        return config
    }

    func save() {
        try? FileManager.default.createDirectory(at: Self.configDir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(self) {
            try? data.write(to: Self.configPath)
        }
    }
}
