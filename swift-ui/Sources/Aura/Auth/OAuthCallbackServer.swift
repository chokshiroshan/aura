import Foundation

/// A minimal HTTP server that runs on localhost to catch OAuth callbacks.
///
/// Flow:
/// 1. Start server on port 1455 (Codex CLI standard)
/// 2. Open browser → auth.openai.com login
/// 3. Browser redirects to http://localhost:1455/auth/callback?code=xxx&state=yyy
/// 4. Server captures the auth code + state
/// 5. Shuts down
final class OAuthCallbackServer {
    private var serverSocket: Int32 = -1
    private var port: UInt16 = 0
    private var continuation: CheckedContinuation<CallbackResult, Error>?
    private var isListening = false

    /// The callback path (default: /auth/callback matching Codex CLI)
    var path: String = "/auth/callback"

    /// If set, try to bind to this specific port (default: random)
    var fixedPort: UInt16? = nil

    /// The redirect URI to use in the OAuth URL.
    var redirectURI: String {
        "http://localhost:\(port)\(path)"
    }

    struct CallbackResult {
        let code: String
        let state: String?
    }

    /// Start the server on a specific or random port. Returns the port used.
    /// If the fixed port is taken, tries to kill the stale process and retry,
    /// then falls back to a random port.
    func start(fixedPort: UInt16? = nil) throws -> UInt16 {
        self.fixedPort = fixedPort

        // Try the fixed port first
        do {
            try bindAndListen()
            return port
        } catch {
            if fixedPort != nil {
                // Try to kill any stale process on that port
                if let port = fixedPort {
                    _ = shell("lsof -ti :\(port) | xargs kill -9 2>/dev/null")
                    Thread.sleep(forTimeInterval: 0.3)
                }
                // Retry fixed port
                do {
                    try bindAndListen()
                    return port
                } catch {
                    // Fall back to random port
                    print("⚠️ Port \(fixedPort!) taken, using random port")
                    self.fixedPort = nil
                    try bindAndListen()
                    return port
                }
            }
            throw error
        }
    }

    /// Wait for the OAuth callback. Server must already be started via start().
    func waitForCallback() async throws -> CallbackResult {
        guard serverSocket != -1 else {
            throw OAuthError.serverStartFailed
        }
        print("📡 OAuth callback server listening on http://localhost:\(port)\(path)")
        return try await withCheckedThrowingContinuation { cont in
            self.continuation = cont
            self.acceptConnection()
        }
    }

    /// Shut down the server.
    func stop() {
        if serverSocket != -1 {
            shutdown(serverSocket, SHUT_RDWR)
            close(serverSocket)
            serverSocket = -1
            isListening = false
        }
    }

    deinit { stop() }

    // MARK: - Private

    private func shell(_ cmd: String) -> String {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", cmd]
        process.standardOutput = pipe
        try? process.run()
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8) ?? ""
    }

    /// Bind the socket and start listening. Only call once.
    private func bindAndListen() throws {
        guard serverSocket == -1 else { return } // Already bound

        serverSocket = socket(AF_INET, SOCK_STREAM, 0)
        guard serverSocket != -1 else {
            throw OAuthError.serverStartFailed
        }

        // Allow port reuse
        var reuse: Int32 = 1
        setsockopt(serverSocket, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout.size(ofValue: reuse)))

        // Bind to localhost on specified or random port
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout.size(ofValue: addr))
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = INADDR_ANY  // 0.0.0.0 — works with both localhost and 127.0.0.1
        addr.sin_port = fixedPort.map { $0.bigEndian } ?? 0

        let bindResult = withUnsafePointer(to: addr) { ptr in
            bind(serverSocket, UnsafeRawPointer(ptr).assumingMemoryBound(to: sockaddr.self), socklen_t(MemoryLayout<sockaddr_in>.size))
        }

        guard bindResult == 0 else {
            let errno = Darwin.errno
            print("❌ bind() failed: errno=\(errno) (\(String(cString: strerror(errno))))")
            close(serverSocket)
            serverSocket = -1
            throw OAuthError.serverStartFailed
        }

        // Get the assigned port
        var assignedAddr = sockaddr_in()
        var addrLen = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &assignedAddr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { rebound in
                getsockname(serverSocket, rebound, &addrLen)
            }
        }
        port = UInt16(assignedAddr.sin_port.bigEndian)

        // Start listening
        guard listen(serverSocket, 1) == 0 else {
            close(serverSocket)
            serverSocket = -1
            throw OAuthError.serverStartFailed
        }

        isListening = true
    }

    private func acceptConnection() {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self, self.serverSocket != -1 else { return }

            print("📡 Waiting for callback connection on port \(self.port)...")

            var clientAddr = sockaddr()
            var clientLen = socklen_t(MemoryLayout.size(ofValue: clientAddr))
            let clientSocket = accept(self.serverSocket, &clientAddr, &clientLen)

            guard clientSocket != -1 else {
                print("❌ accept() failed: \(String(cString: strerror(Darwin.errno)))")
                self.continuation?.resume(throwing: OAuthError.acceptFailed)
                return
            }
            defer { close(clientSocket) }

            // Read the HTTP request
            var buffer = [UInt8](repeating: 0, count: 16384)
            let bytesRead = recv(clientSocket, &buffer, buffer.count, 0)
            guard bytesRead > 0 else {
                self.continuation?.resume(throwing: OAuthError.noData)
                return
            }

            let request = String(bytes: buffer.prefix(bytesRead), encoding: .utf8) ?? ""
            print("📡 Received callback request: \(request.prefix(200))")

            // Parse code + state from the URL
            // GET /auth/callback?code=xxx&state=yyy HTTP/1.1
            if let result = self.extractCallback(from: request) {
                self.sendResponse(clientSocket, html: """
                <html><body style="font-family:system-ui;text-align:center;padding-top:15%">
                <h2>✅ Authenticated!</h2>
                <p>You can close this tab and go back to ChatFlow.</p>
                <script>setTimeout(() => window.close(), 1500)</script>
                </body></html>
                """)
                self.continuation?.resume(returning: result)
            } else {
                self.sendResponse(clientSocket, html: """
                <html><body>
                <h2>❌ Authentication Failed</h2>
                <p>No authorization code received. Please try again.</p>
                <script>setTimeout(() => window.close(), 2000)</script>
                </body></html>
                """)
                self.continuation?.resume(throwing: OAuthError.noCode)
            }
        }
    }

    private func extractCallback(from request: String) -> CallbackResult? {
        // Find the request line: "GET /auth/callback?code=XXX&state=YYY HTTP/1.1"
        guard let pathPrefix = request.range(of: "GET \(path)?") else { return nil }
        let afterPath = String(request[pathPrefix.upperBound...])
        guard let spaceIdx = afterPath.firstIndex(of: " ") else { return nil }
        let queryString = String(afterPath[..<spaceIdx])

        var code: String?
        var state: String?

        for param in queryString.split(separator: "&") {
            let parts = param.split(separator: "=", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let key = String(parts[0])
            let value = String(parts[1]).removingPercentEncoding ?? String(parts[1])
            if key == "code" { code = value }
            if key == "state" { state = value }
        }

        guard let code else { return nil }
        return CallbackResult(code: code, state: state)
    }

    private func sendResponse(_ socket: Int32, html: String) {
        let httpResponse = """
        HTTP/1.1 200 OK\r
        Content-Type: text/html; charset=utf-8\r
        Connection: close\r
        Content-Length: \(html.utf8.count)\r
        \r
        \(html)
        """
        let data = Data(httpResponse.utf8)
        _ = data.withUnsafeBytes { ptr in
            send(socket, ptr.baseAddress, data.count, 0)
        }
    }
}

enum OAuthError: LocalizedError {
    case serverStartFailed
    case acceptFailed
    case noData
    case noCode
    case invalidState
    case tokenExchangeFailed(String)
    case noRefreshToken

    var errorDescription: String? {
        switch self {
        case .serverStartFailed: return "Could not start local OAuth server"
        case .acceptFailed: return "Could not accept OAuth callback connection"
        case .noData: return "Empty callback data received"
        case .noCode: return "No authorization code in callback"
        case .invalidState: return "OAuth state mismatch — possible CSRF"
        case .tokenExchangeFailed(let msg): return "Token exchange failed: \(msg)"
        case .noRefreshToken: return "No refresh token available"
        }
    }
}
