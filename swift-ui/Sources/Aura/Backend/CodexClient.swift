import Foundation

/// JSON-RPC client for the Codex app-server.
///
/// Connects via WebSocket to a locally-running Codex binary.
/// Codex handles: auth, ChatGPT backend, models, tools, memory, sandbox.
/// Aura handles: the companion UI, audio I/O, screen context.
///
/// Protocol docs: codex-rs/app-server-protocol/src/protocol/common.rs
final class CodexClient {
    struct ChatGPTAuthTokensRefreshResult {
        let accessToken: String
        let accountId: String
        let planType: String?
    }
    
    // MARK: - Callbacks
    var onConnected: (() -> Void)?
    var onDisconnected: ((Error?) -> Void)?
    var onThreadCreated: ((String) -> Void)?
    var onTurnEvent: ((TurnEvent) -> Void)?
    var onModelError: ((String) -> Void)?
    var onAuthRequired: (() -> Void)?
    var onAccountUpdated: (() -> Void)?
    var onLoginCompleted: ((Bool, String?) -> Void)?
    var onRealtimeStarted: ((String) -> Void)?
    var onRealtimeTranscript: ((String, String, String, Bool) -> Void)?
    var onRealtimeAudio: ((String, Data) -> Void)?
    var onRealtimeError: ((String, String) -> Void)?
    var onRealtimeClosed: ((String, String?) -> Void)?
    var onChatGPTAuthTokensRefresh: ((String?, String) async throws -> ChatGPTAuthTokensRefreshResult)?
    
    // MARK: - State
    private var webSocket: URLSessionWebSocketTask?
    private(set) var isConnected = false
    private var requestId: Int64 = 0
    private var pendingRequests: [Int64: CheckedContinuation<JSONValue, Error>] = [:]
    private var streamedAgentMessageItemIds = Set<String>()
    private let stateQueue = DispatchQueue(label: "ai.aura.desktop.codexclient.state")
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()
    
    // MARK: - Connection
    
    /// Connect to a Codex app-server instance.
    /// - Parameter url: WebSocket URL, e.g. "ws://127.0.0.1:8080"
    func connect(url: String = "ws://127.0.0.1:8080") {
        guard let wsURL = URL(string: url) else {
            onDisconnected?(CodexError.invalidURL)
            return
        }
        
        var request = URLRequest(url: wsURL)
        // Codex uses capability token auth for non-loopback, but localhost is fine
        
        let session = URLSession(configuration: .ephemeral)
        let ws = session.webSocketTask(with: request)
        self.webSocket = ws
        ws.resume()
        
        isConnected = true
        receiveLoop()
        onConnected?()
        print("🔌 Codex client connected to \(url)")
    }
    
    func disconnect() {
        isConnected = false
        webSocket?.cancel(with: .normalClosure, reason: nil)
        webSocket = nil
        onDisconnected?(nil)
    }
    
    // MARK: - Handshake
    
    /// Initialize the connection — must be called first after connect().
    func initialize() async throws -> InitializeResult {
        let response = try await sendRequest(
            method: "initialize",
            params: [
                "clientInfo": [
                    "name": "Aura",
                    "version": "0.1.0"
                ],
                "capabilities": [
                    "experimentalApi": true
                ]
            ]
        )
        try await sendNotification(method: "initialized")
        return InitializeResult(from: response)
    }
    
    // MARK: - Auth
    
    /// Get current auth status
    func getAccount() async throws -> AccountInfo {
        let response = try await sendRequest(method: "account/read", params: ["refreshToken": false])
        return AccountInfo(from: response)
    }
    
    /// Start ChatGPT OAuth login flow
    func loginAccount() async throws -> LoginResult {
        let response = try await sendRequest(
            method: "account/login/start",
            params: ["type": "chatgpt", "codexStreamlinedLogin": true]
        )
        return LoginResult(from: response)
    }

    /// Install ChatGPT OAuth tokens that Aura obtained through its own localhost callback.
    func loginWithChatGPTAuthTokens(accessToken: String, accountId: String, planType: String?) async throws {
        var params: [String: Any] = [
            "type": "chatgptAuthTokens",
            "accessToken": accessToken,
            "chatgptAccountId": accountId
        ]
        if let planType {
            params["chatgptPlanType"] = planType
        }
        let _ = try await sendRequest(method: "account/login/start", params: params)
    }

    /// Clear the current Codex account so the next login can use a different ChatGPT account.
    func logoutAccount() async throws {
        let _ = try await sendRequest(method: "account/logout", params: [:])
    }
    
    // MARK: - Thread Management
    
    /// Create a new conversation thread
    func startThread(
        cwd: String? = nil,
        instructions: String? = nil,
        config: [String: Any]? = nil,
        approvalPolicy: String? = nil,
        sandbox: String? = nil,
        approvalsReviewer: String? = nil
    ) async throws -> ThreadInfo {
        var params: [String: Any] = [:]
        if let cwd { params["cwd"] = cwd }
        if let instructions { params["developerInstructions"] = instructions }
        if let config { params["config"] = config }
        if let approvalPolicy { params["approvalPolicy"] = approvalPolicy }
        if let sandbox { params["sandbox"] = sandbox }
        if let approvalsReviewer { params["approvalsReviewer"] = approvalsReviewer }
        
        let response = try await sendRequest(method: "thread/start", params: params)
        return ThreadInfo(from: response)
    }
    
    /// Resume an existing thread
    func resumeThread(id: String) async throws -> ThreadInfo {
        let response = try await sendRequest(
            method: "thread/resume",
            params: ["threadId": id]
        )
        return ThreadInfo(from: response)
    }
    
    /// List all threads
    func listThreads() async throws -> [ThreadSummary] {
        let response = try await sendRequest(method: "thread/list", params: [:])
        return ThreadSummary.arrayFrom(response)
    }
    
    // MARK: - Turns (conversation)
    
    /// Start a turn — send a text message and get a response
    func startTurn(threadId: String, message: String, localImagePath: String? = nil) async throws {
        var input: [[String: Any]] = [
            ["type": "text", "text": message, "text_elements": []]
        ]
        if let localImagePath {
            input.append(["type": "localImage", "path": localImagePath])
        }

        let _ = try await sendRequest(
            method: "turn/start",
            params: [
                "threadId": threadId,
                "input": input,
                "effort": "medium"
            ]
        )
    }
    
    /// Interrupt an active turn
    func interruptTurn(threadId: String) async throws {
        let _ = try await sendRequest(
            method: "turn/interrupt",
            params: ["threadId": threadId]
        )
    }
    
    /// Steer an active turn with new input
    func steerTurn(threadId: String, message: String) async throws {
        let _ = try await sendRequest(
            method: "turn/steer",
            params: [
                "threadId": threadId,
                "input": [
                    ["type": "text", "text": message]
                ]
            ]
        )
    }
    
    // MARK: - Realtime (Voice)
    
    /// Start a realtime voice session on a thread
    func startRealtime(threadId: String, voice: String? = nil) async throws {
        var params: [String: Any] = [
            "threadId": threadId,
            "outputModality": "audio",
            "transport": ["type": "websocket"]
        ]
        if let voice { params["voice"] = voice }
        
        let _ = try await sendRequest(
            method: "thread/realtime/start",
            params: params
        )
    }
    
    /// Send audio to the realtime session
    func appendAudio(threadId: String, pcmData: Data, sampleRate: Int = 24_000, numChannels: Int = 1) async throws {
        let channelCount = max(numChannels, 1)
        let samplesPerChannel = pcmData.count / (2 * channelCount)
        let _ = try await sendRequest(
            method: "thread/realtime/appendAudio",
            params: [
                "threadId": threadId,
                "audio": [
                    "data": pcmData.base64EncodedString(),
                    "sampleRate": sampleRate,
                    "numChannels": channelCount,
                    "samplesPerChannel": samplesPerChannel
                ]
            ]
        )
    }

    /// Send text to the realtime session.
    func appendText(threadId: String, text: String) async throws {
        let _ = try await sendRequest(
            method: "thread/realtime/appendText",
            params: [
                "threadId": threadId,
                "text": text
            ]
        )
    }

    /// Send an image into the realtime session.
    func appendImage(threadId: String, imagePath: String, detail: String = "auto") async throws {
        let data = try Data(contentsOf: URL(fileURLWithPath: imagePath))
        let imageURL = "data:image/png;base64,\(data.base64EncodedString())"
        let _ = try await sendRequest(
            method: "thread/realtime/appendImage",
            params: [
                "threadId": threadId,
                "imageUrl": imageURL,
                "detail": detail
            ]
        )
    }
    
    /// Stop the realtime session
    func stopRealtime(threadId: String) async throws {
        let _ = try await sendRequest(
            method: "thread/realtime/stop",
            params: ["threadId": threadId]
        )
    }
    
    /// List available voices
    func listVoices(threadId: String) async throws -> [String] {
        let response = try await sendRequest(
            method: "thread/realtime/listVoices",
            params: ["threadId": threadId]
        )
        // Parse voice list from response
        if let voices = (response as? [String: Any])?["voices"] as? [[String: Any]] {
            return voices.compactMap { $0["id"] as? String }
        }
        return []
    }
    
    // MARK: - Tools & Approvals
    
    /// Resolve a server request (approval)
    func resolveRequest(requestId: Any, result: [String: Any]) async throws {
        let approved = result["approved"] as? Bool ?? false
        try await sendServerResponse(
            id: requestId,
            method: "item/commandExecution/requestApproval",
            response: ["decision": approved ? "acceptForSession" : "decline"]
        )
    }
    
    // MARK: - Memory
    
    func getMemories(threadId: String) async throws -> [String] {
        let response = try await sendRequest(
            method: "thread/read",
            params: ["threadId": threadId]
        )
        // Parse memories from thread data
        return []
    }
    
    // MARK: - Low-Level JSON-RPC
    
    private func nextId() -> Int64 {
        stateQueue.sync {
            requestId += 1
            return requestId
        }
    }

    private func storePendingRequest(
        id: Int64,
        continuation: CheckedContinuation<JSONValue, Error>
    ) {
        stateQueue.sync {
            pendingRequests[id] = continuation
        }
    }

    private func takePendingRequest(id: Int64) -> CheckedContinuation<JSONValue, Error>? {
        stateQueue.sync {
            pendingRequests.removeValue(forKey: id)
        }
    }

    private func markStreamedAgentMessageItem(_ itemId: String) {
        stateQueue.sync {
            streamedAgentMessageItemIds.insert(itemId)
        }
    }

    private func hasStreamedAgentMessageItem(_ itemId: String) -> Bool {
        stateQueue.sync {
            streamedAgentMessageItemIds.contains(itemId)
        }
    }
    
    private func sendRequest(method: String, params: [String: Any]) async throws -> JSONValue {
        let id = nextId()
        
        var message: [String: Any] = [
            "id": id,
            "method": method
        ]
        if !params.isEmpty {
            message["params"] = params
        }
        
        let data = try JSONSerialization.data(withJSONObject: message)
        guard let jsonStr = String(data: data, encoding: .utf8) else {
            throw CodexError.serializationFailed
        }

        guard let webSocket, isConnected else {
            throw CodexError.notConnected
        }
        
        return try await withCheckedThrowingContinuation { continuation in
            storePendingRequest(id: id, continuation: continuation)
            
            webSocket.send(.string(jsonStr)) { [weak self] error in
                guard let error, let continuation = self?.takePendingRequest(id: id) else {
                    return
                }
                continuation.resume(throwing: error)
            }
        }
    }

    private func sendNotification(method: String, params: [String: Any]? = nil) async throws {
        var message: [String: Any] = ["method": method]
        if let params {
            message["params"] = params
        }

        let data = try JSONSerialization.data(withJSONObject: message)
        guard let jsonStr = String(data: data, encoding: .utf8) else {
            throw CodexError.serializationFailed
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            webSocket?.send(.string(jsonStr)) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }

    private func sendServerResponse(id: Any, method: String, response: [String: Any]) async throws {
        let data = try JSONSerialization.data(withJSONObject: [
            "method": method,
            "id": id,
            "response": response
        ])
        guard let jsonStr = String(data: data, encoding: .utf8) else {
            throw CodexError.serializationFailed
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            webSocket?.send(.string(jsonStr)) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }

    private func sendServerError(id: Any, message: String) async {
        let payload: [String: Any] = [
            "id": id,
            "error": [
                "code": -32000,
                "message": message
            ]
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let jsonStr = String(data: data, encoding: .utf8) else {
            return
        }

        webSocket?.send(.string(jsonStr)) { error in
            if let error {
                print("⚠️ Failed to send server-request error: \(error.localizedDescription)")
            }
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
                case .string(let json):
                    self.handleMessage(json)
                case .data(let data):
                    if let json = String(data: data, encoding: .utf8) {
                        self.handleMessage(json)
                    }
                @unknown default:
                    break
                }
                self.receiveLoop()
                
            case .failure(let error):
                if self.isConnected {
                    print("⚠️ Codex WebSocket error: \(error)")
                    self.isConnected = false
                    self.onDisconnected?(error)
                }
            }
        }
    }
    
    private func handleMessage(_ json: String) {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return
        }
        
        // Request initiated by the server.
        if let id = obj["id"], let method = obj["method"] as? String {
            handleServerRequest(id: id, method: method, params: obj["params"] as? [String: Any] ?? [:])
            return
        }

        // Response to a request we sent
        if let id = Self.requestId(from: obj["id"]) {
            if let result = obj["result"] {
                if let cont = takePendingRequest(id: id) {
                    cont.resume(returning: result)
                }
            } else if let error = obj["error"] as? [String: Any] {
                let msg = error["message"] as? String ?? "Unknown error"
                if let cont = takePendingRequest(id: id) {
                    cont.resume(throwing: CodexError.serverError(msg))
                }
            }
            return
        }
        
        // Notification from server
        if let method = obj["method"] as? String,
           let params = obj["params"] as? [String: Any] {
            handleNotification(method: method, params: params)
            return
        }
    }

    private static func requestId(from value: Any?) -> Int64? {
        if let id = value as? Int64 { return id }
        if let id = value as? Int { return Int64(id) }
        if let id = value as? NSNumber { return id.int64Value }
        return nil
    }

    private func handleServerRequest(id: Any, method: String, params: [String: Any]) {
        switch method {
        case "account/chatgptAuthTokens/refresh":
            Task { [weak self] in
                guard let self else { return }
                do {
                    guard let refresh = self.onChatGPTAuthTokensRefresh else {
                        throw CodexError.serverError("ChatGPT token refresh is not configured")
                    }
                    let result = try await refresh(
                        params["previousAccountId"] as? String,
                        params["reason"] as? String ?? "unknown"
                    )
                    try await self.sendServerResponse(
                        id: id,
                        method: method,
                        response: [
                            "accessToken": result.accessToken,
                            "chatgptAccountId": result.accountId,
                            "chatgptPlanType": result.planType ?? NSNull()
                        ]
                    )
                } catch {
                    await self.sendServerError(id: id, message: error.localizedDescription)
                }
            }

        case "item/commandExecution/requestApproval":
            onTurnEvent?(.toolCall(name: "shell approval", args: approvalDisplayArgs(params)))
            Task { [weak self] in
                do {
                    try await self?.sendServerResponse(
                        id: id,
                        method: method,
                        response: ["decision": "acceptForSession"]
                    )
                } catch {
                    await self?.sendServerError(id: id, message: error.localizedDescription)
                }
            }

        case "item/fileChange/requestApproval":
            onTurnEvent?(.toolCall(name: "file approval", args: approvalDisplayArgs(params)))
            Task { [weak self] in
                do {
                    try await self?.sendServerResponse(
                        id: id,
                        method: method,
                        response: ["decision": "acceptForSession"]
                    )
                } catch {
                    await self?.sendServerError(id: id, message: error.localizedDescription)
                }
            }

        case "item/permissions/requestApproval":
            onTurnEvent?(.toolCall(name: "permission approval", args: approvalDisplayArgs(params)))
            Task { [weak self] in
                guard let self else { return }
                do {
                    let cwd = params["cwd"] as? String
                    var fileSystem: [String: Any] = [:]
                    if let cwd, !cwd.isEmpty {
                        fileSystem["read"] = [cwd]
                        fileSystem["write"] = [cwd]
                    }
                    try await self.sendServerResponse(
                        id: id,
                        method: method,
                        response: [
                            "permissions": [
                                "network": ["enabled": true],
                                "fileSystem": fileSystem
                            ],
                            "scope": "session"
                        ]
                    )
                } catch {
                    await self.sendServerError(id: id, message: error.localizedDescription)
                }
            }

        case "mcpServer/elicitation/request":
            onTurnEvent?(.toolCall(name: "mcp elicitation", args: approvalDisplayArgs(params)))
            Task { [weak self] in
                do {
                    try await self?.sendServerResponse(
                        id: id,
                        method: method,
                        response: [
                            "action": "decline",
                            "content": NSNull(),
                            "_meta": NSNull()
                        ]
                    )
                } catch {
                    await self?.sendServerError(id: id, message: error.localizedDescription)
                }
            }

        case "item/tool/requestUserInput":
            Task { [weak self] in
                do {
                    try await self?.sendServerResponse(
                        id: id,
                        method: method,
                        response: ["answers": [:]]
                    )
                } catch {
                    await self?.sendServerError(id: id, message: error.localizedDescription)
                }
            }

        case "item/tool/call":
            onTurnEvent?(.toolCall(name: "client tool", args: approvalDisplayArgs(params)))
            Task { [weak self] in
                do {
                    try await self?.sendServerResponse(
                        id: id,
                        method: method,
                        response: [
                            "contentItems": [
                                [
                                    "type": "inputText",
                                    "text": "Aura has no client-side dynamic tool registered for this request."
                                ]
                            ],
                            "success": false
                        ]
                    )
                } catch {
                    await self?.sendServerError(id: id, message: error.localizedDescription)
                }
            }

        default:
            Task { [weak self] in
                await self?.sendServerError(id: id, message: "Unsupported server request: \(method)")
            }
        }
    }
    
    private func handleNotification(method: String, params: [String: Any]) {
        switch method {
        case "thread/started":
            if let threadId = (params["thread"] as? [String: Any])?["id"] as? String {
                onThreadCreated?(threadId)
            }
            
        case "turn/started":
            onTurnEvent?(.started(threadId: params["threadId"] as? String ?? ""))
            
        case "turn/completed":
            onTurnEvent?(.completed(threadId: params["threadId"] as? String ?? ""))

        case "item/started":
            if let item = params["item"] as? [String: Any] {
                handleItemProgress(item, threadId: params["threadId"] as? String ?? "", phase: "started")
            }

        case "item/agentMessage/delta":
            if let delta = params["delta"] as? String {
                let threadId = params["threadId"] as? String ?? ""
                if let itemId = params["itemId"] as? String {
                    markStreamedAgentMessageItem(itemId)
                }
                onTurnEvent?(.agentMessage(threadId: threadId, text: delta))
            }

        case "item/completed":
            guard let item = params["item"] as? [String: Any] else {
                break
            }
            if item["type"] as? String != "agentMessage" {
                handleItemProgress(item, threadId: params["threadId"] as? String ?? "", phase: "completed")
                break
            }
            guard let text = item["text"] as? String, !text.isEmpty else { break }
            if let itemId = item["id"] as? String,
               hasStreamedAgentMessageItem(itemId) {
                break
            }
            let threadId = params["threadId"] as? String ?? ""
            onTurnEvent?(.agentMessage(threadId: threadId, text: text))

        case "account/login/completed":
            let success = params["success"] as? Bool ?? false
            let error = params["error"] as? String
            onLoginCompleted?(success, error)

        case "account/updated":
            onAccountUpdated?()

        case "thread/realtime/started":
            let threadId = params["threadId"] as? String ?? ""
            onRealtimeStarted?(threadId)

        case "thread/realtime/transcript/delta":
            let threadId = params["threadId"] as? String ?? ""
            let role = params["role"] as? String ?? ""
            let delta = params["delta"] as? String ?? ""
            onRealtimeTranscript?(threadId, role, delta, false)

        case "thread/realtime/transcript/done":
            let threadId = params["threadId"] as? String ?? ""
            let role = params["role"] as? String ?? ""
            let text = params["text"] as? String ?? ""
            onRealtimeTranscript?(threadId, role, text, true)

        case "thread/realtime/outputAudio/delta":
            let threadId = params["threadId"] as? String ?? ""
            if let audio = params["audio"] as? [String: Any],
               let data = audio["data"] as? String,
               let decoded = Data(base64Encoded: data) {
                onRealtimeAudio?(threadId, decoded)
            }

        case "thread/realtime/error":
            let threadId = params["threadId"] as? String ?? ""
            let message = params["message"] as? String ?? "Realtime voice failed"
            onRealtimeError?(threadId, message)

        case "thread/realtime/closed":
            let threadId = params["threadId"] as? String ?? ""
            let reason = params["reason"] as? String
            onRealtimeClosed?(threadId, reason)
            
        case "error":
            let msg = (params["error"] as? [String: Any])?["message"] as? String ?? "Unknown error"
            let threadId = params["threadId"] as? String ?? ""
            if threadId.isEmpty {
                onModelError?(msg)
            } else {
                onTurnEvent?(.error(threadId: threadId, message: msg))
            }
            
        case "item/commandExecution/requestApproval":
            // Server wants approval for a shell command
            handleApprovalRequest(params)
            
        case "item/fileChange/requestApproval":
            // Server wants approval for a file change
            handleApprovalRequest(params)
            
        default:
            print("📨 Codex notification: \(method)")
        }
    }
    
    private func handleApprovalRequest(_ params: [String: Any]) {
        // For now, auto-approve everything
        // TODO: Show approval UI in the companion
        guard let requestId = params["id"] else { return }
        Task {
            try? await resolveRequest(requestId: requestId, result: ["approved": true])
        }
    }

    private func approvalDisplayArgs(_ params: [String: Any]) -> [String: Any] {
        var args: [String: Any] = [:]
        for key in ["command", "cwd", "reason", "serverName", "tool"] {
            if let value = params[key] {
                args[key] = value
            }
        }
        return args
    }

    private func handleItemProgress(_ item: [String: Any], threadId: String, phase: String) {
        guard let type = item["type"] as? String,
              type != "agentMessage",
              type != "reasoning" else {
            return
        }

        var args: [String: Any] = ["phase": phase]
        for key in ["command", "cwd", "tool", "serverName", "status"] {
            if let value = item[key] {
                args[key] = value
            }
        }
        if !threadId.isEmpty {
            args["threadId"] = threadId
        }
        onTurnEvent?(.toolCall(name: type, args: args))
    }
}

// MARK: - Types

typealias JSONValue = Any

enum CodexError: LocalizedError {
    case invalidURL
    case serializationFailed
    case serverError(String)
    case notConnected
    
    var errorDescription: String? {
        switch self {
        case .invalidURL: return "Invalid URL"
        case .serializationFailed: return "Serialization failed"
        case .serverError(let msg): return "Codex error: \(msg)"
        case .notConnected: return "Not connected to Codex"
        }
    }
}

struct InitializeResult {
    let userAgent: String
    let codexHome: String
    let platform: String
    
    init(from json: JSONValue) {
        guard let dict = json as? [String: Any] else {
            userAgent = "unknown"
            codexHome = ""
            platform = "unknown"
            return
        }
        self.userAgent = dict["userAgent"] as? String ?? "unknown"
        self.codexHome = dict["codexHome"] as? String ?? ""
        self.platform = dict["platformOs"] as? String ?? "unknown"
    }
}

struct AccountInfo {
    let authMode: String
    let email: String?
    let plan: String?
    
    init(from json: JSONValue) {
        guard let dict = json as? [String: Any] else {
            authMode = "unknown"
            email = nil
            plan = nil
            return
        }

        if let account = dict["account"] as? [String: Any] {
            self.authMode = account["type"] as? String ?? "unknown"
            self.email = account["email"] as? String
            self.plan = account["planType"] as? String
        } else {
            self.authMode = dict["authMode"] as? String ?? "unknown"
            self.email = dict["email"] as? String
            self.plan = dict["plan"] as? String ?? dict["planType"] as? String
        }
    }
}

struct LoginResult {
    let loginUrl: String?
    
    init(from json: JSONValue) {
        guard let dict = json as? [String: Any] else {
            loginUrl = nil
            return
        }
        self.loginUrl = dict["authUrl"] as? String ?? dict["url"] as? String
    }
}

struct ThreadInfo {
    let id: String
    let model: String
    let cwd: String
    
    init(from json: JSONValue) {
        guard let dict = json as? [String: Any],
              let thread = dict["thread"] as? [String: Any] else {
            id = ""
            model = ""
            cwd = ""
            return
        }
        self.id = thread["id"] as? String ?? ""
        self.model = dict["model"] as? String ?? ""
        self.cwd = dict["cwd"] as? String ?? ""
    }
}

struct ThreadSummary {
    let id: String
    let preview: String
    let updatedAt: String?
    
    init(from dict: [String: Any]) {
        self.id = dict["id"] as? String ?? ""
        self.preview = dict["preview"] as? String ?? ""
        self.updatedAt = dict["updatedAt"] as? String
    }
    
    static func arrayFrom(_ json: JSONValue) -> [ThreadSummary] {
        guard let dict = json as? [String: Any],
              let threads = dict["threads"] as? [[String: Any]] else {
            return []
        }
        return threads.map { ThreadSummary(from: $0) }
    }
}

enum TurnEvent {
    case started(threadId: String)
    case completed(threadId: String)
    case agentMessage(threadId: String, text: String)
    case toolCall(name: String, args: [String: Any])
    case error(threadId: String, message: String)
}
