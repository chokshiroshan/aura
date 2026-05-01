import Foundation

/// Stores and retrieves OAuth tokens from a local file.
///
/// Originally used macOS Keychain, but unsigned CLI builds trigger
/// repeated password prompts. File-based storage avoids this entirely.
/// Tokens are stored at ~/.flow/auth.json with restricted permissions (600).
final class KeychainStore {
    static let shared = KeychainStore()
    private var storageURL: URL {
        FlowConfig.configDir.appendingPathComponent("auth.json")
    }

    private init() {}

    // MARK: - Token Storage

    struct AuthTokens: Codable {
        let accessToken: String
        let refreshToken: String
        let idToken: String?
        let expiresAt: Date
        let email: String?
        let plan: String?

        var isExpired: Bool {
            Date() > expiresAt.addingTimeInterval(-60) // 60s buffer
        }
    }

    func saveTokens(_ tokens: AuthTokens) throws {
        // Ensure ~/.flow/ exists
        try? FileManager.default.createDirectory(
            at: FlowConfig.configDir,
            withIntermediateDirectories: true
        )

        let data = try JSONEncoder().encode(tokens)
        try data.write(to: storageURL, options: .atomic)

        // Set file permissions to owner-only (rw-------)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: storageURL.path
        )
    }

    func loadTokens() -> AuthTokens? {
        guard FileManager.default.fileExists(atPath: storageURL.path),
              let data = try? Data(contentsOf: storageURL) else {
            return nil
        }
        return try? JSONDecoder().decode(AuthTokens.self, from: data)
    }

    func deleteTokens() {
        try? FileManager.default.removeItem(at: storageURL)
    }
}
