import Foundation

// MARK: - Protocol

/// Abstract backend — the app doesn't care whether it's OpenClaw or ChatGPT.
protocol OrbBackend: AnyObject {
    var onConnected: (() -> Void)? { get set }
    var onError: ((Error) -> Void)? { get set }
    var onAudioResponse: (() -> Void)? { get set }
    var onResponseDone: (() -> Void)? { get set }
    var onMemoryUpdate: (([MemoryEntry]) -> Void)? { get set }

    func connect()
    func disconnect()
    func sendText(_ text: String) async -> String
    func startAudioCapture()
    func stopAudioCapture()
    func getMemory() async -> [MemoryEntry]
}

// MARK: - Shared Types

struct MemoryEntry: Codable, Identifiable {
    let id: String
    let content: String
    let timestamp: Date
    let source: String // "openclaw", "chatgpt", "local"
}

struct OrbConfig: Codable {
    var backendType: String // "openclaw" | "chatgpt"
    var openclawURL: String?
    var openclawAPIKey: String?
    var lastConnected: Date?

    static let storageKey = "ai.orb.desktop.config"

    static func load() -> OrbConfig? {
        guard let data = UserDefaults.standard.data(forKey: storageKey) else { return nil }
        return try? JSONDecoder().decode(OrbConfig.self, from: data)
    }

    func save() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        UserDefaults.standard.set(data, forKey: OrbConfig.storageKey)
    }
}
