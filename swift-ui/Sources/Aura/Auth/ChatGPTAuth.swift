import Foundation
import AppKit
import CryptoKit
import CommonCrypto

/// Authenticates with ChatGPT via OAuth PKCE — exactly matching the Codex CLI flow.
///
/// Reverse-engineered from openai/codex source (codex-rs/login/):
/// - Client ID: app_EMoamEEZ73f0CkXaXp7hrann
/// - Issuer: https://auth.openai.com
/// - Scope: openid profile email offline_access api.connectors.read api.connectors.invoke
/// - Extra params: id_token_add_organizations, codex_cli_simplified_flow, originator
/// - PKCE: S256 with URL-safe base64 no-pad verifier (64 random bytes)
/// - Token exchange: form-urlencoded (not JSON)
/// - Refresh: form-urlencoded (not JSON)
///
/// For ChatGPT subscription auth, all API calls route through:
///   https://chatgpt.com/backend-api/codex
/// (not api.openai.com — that's for API key auth only)
final class ChatGPTAuth: @unchecked Sendable, ObservableObject {
    static let shared = ChatGPTAuth()

    @Published var authState: AuthState = .signedOut
    @Published var userEmail: String?

    /// Current access token (if signed in)
    private(set) var accessToken: String?

    private let keychain = KeychainStore.shared
    private var callbackServer: OAuthCallbackServer?

    // MARK: - OAuth Config (matching Codex CLI exactly)

    /// Codex CLI client ID (from codex-rs/login/src/auth/manager.rs)
    private let clientID = "app_EMoamEEZ73f0CkXaXp7hrann"
    private let issuer = "https://auth.openai.com"

    /// Codex CLI scope (from codex-rs/login/src/server.rs build_authorize_url)
    private let scopes = "openid profile email offline_access api.connectors.read api.connectors.invoke"
    private let redirectPath = "/auth/callback"
    private let callbackPort: UInt16 = 1455

    init() {
        // Restore existing session
        if let tokens = Self.tokensFromCodexAuthFile(), !tokens.isExpired {
            try? keychain.saveTokens(tokens)
            let email = Self.extractEmailFromJWT(tokens.idToken ?? tokens.accessToken)
            self.accessToken = tokens.accessToken
            self.userEmail = email
            self.authState = .signedIn(email: email ?? "ChatGPT User", plan: tokens.plan ?? "ChatGPT")
            return
        }

        if let tokens = keychain.loadTokens(), !tokens.isExpired {
            let email = Self.extractEmailFromJWT(tokens.accessToken)
            self.accessToken = tokens.accessToken
            self.userEmail = email
            self.authState = .signedIn(email: email ?? "ChatGPT User", plan: tokens.plan ?? "ChatGPT")
        }
    }

    // MARK: - Sign In

    func signIn() {
        guard authState != .signingIn else { return }
        Task {
            do {
                _ = try await self.signInAndWait()
            } catch {
                print("❌ Auth failed: \(error)")
                self.callbackServer?.stop()
                self.callbackServer = nil
                DispatchQueue.main.async {
                    self.authState = .error(error.localizedDescription)
                }
            }
        }
    }

    @MainActor
    func signInAndWait() async throws -> KeychainStore.AuthTokens {
        guard authState != .signingIn else {
            throw AuthError.authFailed("A sign-in is already in progress")
        }
        authState = .signingIn

        // Generate PKCE (matching Codex: URL-safe base64 no-pad, 64 random bytes)
        let verifier = Self.generateCodeVerifier()
        let challenge = Self.generateCodeChallenge(from: verifier)
        let state = Self.randomState()

        // Start callback server on port 1455 (Codex standard), falling back to random.
        let server = OAuthCallbackServer()
        server.path = redirectPath
        self.callbackServer = server
        let port = try server.start(fixedPort: callbackPort)
        let redirectURI = "http://localhost:\(port)\(redirectPath)"

        // Build authorize URL with a localhost callback owned by Aura. This avoids
        // Codex.app deep-link callbacks and the "Open Codex?" browser prompt.
        var components = URLComponents(string: "\(issuer)/oauth/authorize")!
        components.queryItems = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "scope", value: scopes),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "id_token_add_organizations", value: "true"),
            URLQueryItem(name: "codex_cli_simplified_flow", value: "true"),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "originator", value: "codex_cli_rs"),
        ]

        guard let authURL = components.url else {
            throw AuthError.serverFailed
        }

        print("🌐 Opening OAuth: \(authURL)")
        NSWorkspace.shared.open(authURL)

        do {
            let result = try await server.waitForCallback()
            server.stop()
            self.callbackServer = nil

            guard result.state == state else {
                throw AuthError.authFailed("State mismatch")
            }

            let tokens = try await exchangeCode(result.code, verifier: verifier, redirectURI: redirectURI)
            self.accessToken = tokens.accessToken
            try keychain.saveTokens(tokens)

            let displayEmail = tokens.email ?? "ChatGPT User"
            self.userEmail = displayEmail
            self.authState = .signedIn(email: displayEmail, plan: tokens.plan ?? "ChatGPT")
            print("✅ Authenticated as \(displayEmail) (refresh token: \(tokens.refreshToken.isEmpty ? "NO" : "YES"))")
            return tokens
        } catch {
            server.stop()
            self.callbackServer = nil
            self.authState = .error(error.localizedDescription)
            throw error
        }
    }

    func signOut() {
        keychain.deleteTokens()
        accessToken = nil
        userEmail = nil
        authState = .signedOut
        callbackServer?.stop()
        callbackServer = nil
    }

    // MARK: - Token Refresh

    @discardableResult
    func refreshAccessToken(force: Bool = false) async -> Bool {
        guard let tokens = keychain.loadTokens(),
              !tokens.refreshToken.isEmpty else {
            return false
        }

        // If not expired, just return current token
        if !force && !tokens.isExpired {
            accessToken = tokens.accessToken
            return true
        }

        print("🔄 Refreshing access token...")
        do {
            let newTokens = try await refreshToken(tokens.refreshToken)
            try keychain.saveTokens(newTokens)
            accessToken = newTokens.accessToken

            let email = Self.extractEmailFromJWT(newTokens.accessToken) ?? userEmail
            DispatchQueue.main.async {
                self.userEmail = email
                self.authState = .signedIn(email: email ?? "ChatGPT User", plan: "ChatGPT")
            }
            print("✅ Token refreshed successfully")
            return true
        } catch {
            print("❌ Token refresh failed: \(error)")
            return false
        }
    }

    func ensureValidToken() async -> String? {
        if let tokens = Self.tokensFromCodexAuthFile(), !tokens.isExpired {
            try? keychain.saveTokens(tokens)
            accessToken = tokens.accessToken
            return accessToken
        }

        // If token is still valid, return it
        if let tokens = keychain.loadTokens(), !tokens.isExpired {
            accessToken = tokens.accessToken
            _ = currentChatGPTAccountId()
            return accessToken
        }

        // Try to refresh
        if await refreshAccessToken() {
            return accessToken
        }

        // Refresh failed, need re-auth
        DispatchQueue.main.async {
            self.authState = .signedOut
        }
        return nil
    }

    func currentChatGPTAccountId() -> String? {
        guard let tokens = keychain.loadTokens() else {
            return Self.accountIdFromCodexAuthFile()
        }

        if let accountId = tokens.chatgptAccountId, !accountId.isEmpty {
            return accountId
        }

        let recoveredAccountId = tokens.idToken.flatMap(Self.extractChatGPTAccountId)
            ?? Self.extractChatGPTAccountId(from: tokens.accessToken)
            ?? Self.accountIdFromCodexAuthFile()

        guard let recoveredAccountId, !recoveredAccountId.isEmpty else {
            return nil
        }

        let repaired = KeychainStore.AuthTokens(
            accessToken: tokens.accessToken,
            refreshToken: tokens.refreshToken,
            idToken: tokens.idToken,
            expiresAt: tokens.expiresAt,
            email: tokens.email,
            plan: tokens.plan,
            chatgptAccountId: recoveredAccountId
        )
        try? keychain.saveTokens(repaired)
        return recoveredAccountId
    }

    // MARK: - OAuth Token Exchange (matching Codex's exchange_code_for_tokens)

    private func exchangeCode(_ code: String, verifier: String, redirectURI: String) async throws -> KeychainStore.AuthTokens {
        var request = URLRequest(url: URL(string: "\(issuer)/oauth/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        let params: [(String, String)] = [
            ("grant_type", "authorization_code"),
            ("code", code),
            ("redirect_uri", redirectURI),
            ("client_id", clientID),
            ("code_verifier", verifier),
        ]

        request.httpBody = params.map { "\($0.0)=\($0.1.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")" }
            .joined(separator: "&")
            .data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResp = response as? HTTPURLResponse else {
            throw AuthError.authFailed("Invalid response")
        }

        guard httpResp.statusCode == 200 else {
            let body = String(data: data, encoding: .utf8) ?? "unknown"
            print("❌ Token exchange failed (\(httpResp.statusCode)): \(body)")
            throw AuthError.authFailed("Token exchange failed (\(httpResp.statusCode)): \(body)")
        }

        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        guard let accessToken = json["access_token"] as? String else {
            throw AuthError.authFailed("No access_token in response")
        }

        let refreshToken = json["refresh_token"] as? String ?? ""
        let expiresIn = json["expires_in"] as? TimeInterval ?? 3600
        let idToken = json["id_token"] as? String
        let email = Self.extractEmailFromJWT(idToken ?? accessToken)
        let accountId = idToken.flatMap(Self.extractChatGPTAccountId)
            ?? Self.extractChatGPTAccountId(from: accessToken)
            ?? Self.accountIdFromCodexAuthFile()
        let plan = idToken.flatMap { Self.extractAuthClaim("chatgpt_plan_type", from: $0) }
            ?? Self.extractAuthClaim("chatgpt_plan_type", from: accessToken)

        print("📋 Token response scopes: \(json["scope"] ?? "none")")
        print("📋 Refresh token present: \(!refreshToken.isEmpty)")
        print("📋 ChatGPT account id present: \(accountId == nil ? "NO" : "YES")")

        return KeychainStore.AuthTokens(
            accessToken: accessToken,
            refreshToken: refreshToken,
            idToken: idToken,
            expiresAt: Date().addingTimeInterval(expiresIn - 60),
            email: email,
            plan: plan ?? "ChatGPT",
            chatgptAccountId: accountId
        )
    }

    /// Refresh token using form-urlencoded (matching Codex's refresh flow)
    private func refreshToken(_ refreshToken: String) async throws -> KeychainStore.AuthTokens {
        var request = URLRequest(url: URL(string: "\(issuer)/oauth/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        let params: [(String, String)] = [
            ("grant_type", "refresh_token"),
            ("refresh_token", refreshToken),
            ("client_id", clientID),
        ]

        request.httpBody = params.map { "\($0.0)=\($0.1.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")" }
            .joined(separator: "&")
            .data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResp = response as? HTTPURLResponse, httpResp.statusCode == 200 else {
            let httpResp = response as? HTTPURLResponse
            let body = String(data: data, encoding: .utf8) ?? "unknown"
            throw AuthError.authFailed("Refresh failed (\(httpResp?.statusCode ?? 0)): \(body)")
        }

        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        guard let accessToken = json["access_token"] as? String else {
            throw AuthError.authFailed("No access_token in refresh response")
        }

        let newRefreshToken = json["refresh_token"] as? String ?? refreshToken
        let expiresIn = json["expires_in"] as? TimeInterval ?? 3600
        let idToken = json["id_token"] as? String
        let email = Self.extractEmailFromJWT(idToken ?? accessToken)
        let accountId = idToken.flatMap(Self.extractChatGPTAccountId)
            ?? Self.extractChatGPTAccountId(from: accessToken)
            ?? Self.accountIdFromCodexAuthFile()
        let plan = idToken.flatMap { Self.extractAuthClaim("chatgpt_plan_type", from: $0) }
            ?? Self.extractAuthClaim("chatgpt_plan_type", from: accessToken)

        return KeychainStore.AuthTokens(
            accessToken: accessToken,
            refreshToken: newRefreshToken,
            idToken: idToken,
            expiresAt: Date().addingTimeInterval(expiresIn - 60),
            email: email,
            plan: plan ?? "ChatGPT",
            chatgptAccountId: accountId
        )
    }

    // MARK: - PKCE Helpers (matching Codex's pkce.rs exactly)

    /// Generate PKCE code verifier: URL-safe base64 no-pad of 64 random bytes
    private static func generateCodeVerifier() -> String {
        var buffer = [UInt8](repeating: 0, count: 64)
        _ = SecRandomCopyBytes(kSecRandomDefault, 64, &buffer)
        return Data(buffer).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// Generate PKCE code challenge: URL-safe base64 no-pad of SHA256(verifier)
    private static func generateCodeChallenge(from verifier: String) -> String {
        let data = verifier.data(using: .utf8)!
        let hashed = SHA256.hash(data: data)
        return Data(hashed).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// Generate random state: URL-safe base64 no-pad of 32 random bytes
    private static func randomState() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, 32, &bytes)
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    // MARK: - JWT Parsing

    static func extractEmailFromJWT(_ jwt: String) -> String? {
        let claims = jwtClaims(jwt)
        let profile = claims?["https://api.openai.com/profile"] as? [String: Any]
        return claims?["email"] as? String
            ?? claims?["name"] as? String
            ?? profile?["email"] as? String
    }

    static func extractAuthClaim(_ key: String, from jwt: String) -> String? {
        guard let claims = jwtClaims(jwt) else { return nil }
        let auth = claims["https://api.openai.com/auth"] as? [String: Any]
        return auth?[key] as? String ?? claims[key] as? String
    }

    private static func extractChatGPTAccountId(from jwt: String) -> String? {
        extractAuthClaim("chatgpt_account_id", from: jwt)
            ?? extractAuthClaim("account_id", from: jwt)
    }

    private static func accountIdFromCodexAuthFile() -> String? {
        tokensFromCodexAuthFile()?.chatgptAccountId
    }

    private static func tokensFromCodexAuthFile() -> KeychainStore.AuthTokens? {
        let authURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex")
            .appendingPathComponent("auth.json")

        guard let data = try? Data(contentsOf: authURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tokens = json["tokens"] as? [String: Any],
              let accessToken = tokens["access_token"] as? String else {
            return nil
        }

        let refreshToken = tokens["refresh_token"] as? String ?? ""
        let idToken = tokens["id_token"] as? String
        let accountId = (tokens["account_id"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            ?? idToken.flatMap(extractChatGPTAccountId)
            ?? extractChatGPTAccountId(from: accessToken)
        guard let accountId, !accountId.isEmpty else { return nil }

        let email = idToken.flatMap(extractEmailFromJWT)
            ?? extractEmailFromJWT(accessToken)
        let plan = idToken.flatMap { extractAuthClaim("chatgpt_plan_type", from: $0) }
            ?? extractAuthClaim("chatgpt_plan_type", from: accessToken)
        let expiresAt = jwtExpiryDate(accessToken) ?? Date().addingTimeInterval(3000)

        return KeychainStore.AuthTokens(
            accessToken: accessToken,
            refreshToken: refreshToken,
            idToken: idToken,
            expiresAt: expiresAt,
            email: email,
            plan: plan ?? "ChatGPT",
            chatgptAccountId: accountId
        )
    }

    private static func jwtExpiryDate(_ jwt: String) -> Date? {
        guard let claims = jwtClaims(jwt) else { return nil }
        if let exp = claims["exp"] as? TimeInterval {
            return Date(timeIntervalSince1970: exp)
        }
        if let exp = claims["exp"] as? Int {
            return Date(timeIntervalSince1970: TimeInterval(exp))
        }
        return nil
    }

    private static func jwtClaims(_ jwt: String) -> [String: Any]? {
        let parts = jwt.split(separator: ".")
        guard parts.count >= 2 else { return nil }

        var payload = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")

        while payload.count % 4 != 0 { payload += "=" }

        guard let data = Data(base64Encoded: payload),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        return json
    }
}

enum AuthError: LocalizedError {
    case serverFailed
    case authFailed(String)

    var errorDescription: String? {
        switch self {
        case .serverFailed: return "Could not start local auth server"
        case .authFailed(let msg): return "Auth failed: \(msg)"
        }
    }
}
