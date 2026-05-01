import Foundation

// MARK: - Protocol

/// Abstract backend — the app doesn't care whether it's OpenClaw or ChatGPT.
protocol AuraBackend: AnyObject {
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

struct AuraConfig: Codable {
    var backendType: String // "openclaw" | "chatgpt"
    var openclawURL: String?
    var openclawAPIKey: String?
    var lastConnected: Date?

    static let storageKey = "ai.aura.desktop.config"

    static func load() -> AuraConfig? {
        guard let data = UserDefaults.standard.data(forKey: storageKey) else { return nil }
        return try? JSONDecoder().decode(AuraConfig.self, from: data)
    }

    func save() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        UserDefaults.standard.set(data, forKey: AuraConfig.storageKey)
    }
}
