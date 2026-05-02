import Foundation
import AppKit

/// Proactive nudge system — Aura offers help when it spots something useful.
///
/// The proactivity dial:
/// - **Silent**: Only responds when asked
/// - **Light**: Errors, obvious improvements
/// - **Active**: Offers help when it thinks it can be useful
/// - **Partner**: Actively suggests, reminds, assists
///
/// How it works:
/// 1. Screen streamer captures frames periodically
/// 2. Each frame is analyzed by Codex via a lightweight "scan" prompt
/// 3. If Codex flags something worth mentioning, a nudge is created
/// 4. The orb glows and shows a small chip near the cursor
final class NudgeEngine {
    
    var onNudge: ((Nudge) -> Void)?
    
    enum ProactivityLevel: String, CaseIterable {
        case silent
        case light
        case active
        case partner
    }
    
    struct Nudge {
        let id = UUID()
        let text: String
        let priority: Priority
        let context: String  // What was on screen
        
        enum Priority {
            case low       // "Did you know..."
            case medium    // "You might want to..."
            case high      // "Error detected on line 42"
            case urgent    // "Your build is failing"
        }
    }
    
    // MARK: - State
    private(set) var level: ProactivityLevel = .active
    private var lastNudgeTime: Date = .distantPast
    private let minInterval: TimeInterval = 30  // Don't nudge more than every 30s
    private var scanTimer: Timer?
    private var codex: CodexClient?
    private var scanThreadId: String?
    
    // MARK: - Config
    
    func setLevel(_ level: ProactivityLevel) {
        self.level = level
        if level == .silent {
            stopScanning()
        }
        print("🔔 Proactivity level: \(level.rawValue)")
    }
    
    func setCodexClient(_ client: CodexClient) {
        self.codex = client
    }
    
    // MARK: - Scanning
    
    func startScanning() {
        guard level != .silent else { return }
        
        let interval: TimeInterval
        switch level {
        case .silent: return
        case .light:  interval = 120   // Every 2 min
        case .active: interval = 60    // Every 1 min
        case .partner: interval = 30   // Every 30s
        }
        
        print("🔔 Nudge scanning started (every \(interval)s)")
        
        scanTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.performScan()
        }
    }
    
    func stopScanning() {
        scanTimer?.invalidate()
        scanTimer = nil
    }
    
    private func performScan() {
        guard level != .silent else { return }
        guard Date().timeIntervalSince(lastNudgeTime) >= minInterval else { return }
        
        // Scan is triggered by the screen streamer's frame callback
        // The coordinator wires frame -> scan
        print("🔔 Proactive scan...")
    }
    
    /// Analyze a screen frame and decide if a nudge is warranted
    func analyzeScreen(context: String) {
        guard level != .silent else { return }
        guard Date().timeIntervalSince(lastNudgeTime) >= minInterval else { return }
        guard let codex else { return }
        
        Task {
            do {
                // Create scan thread if needed
                if scanThreadId == nil {
                    let thread = try await codex.startThread(
                        cwd: NSHomeDirectory(),
                        instructions: """
                        You are Aura's proactive scanning system. You analyze screenshots and decide if the user needs help.
                        
                        Rules:
                        - Only flag things that are genuinely useful
                        - Never state the obvious ("you have a browser open")
                        - Prioritize: errors > questions > opportunities > info
                        - Be extremely concise (10 words max for the nudge text)
                        - If nothing is worth mentioning, respond with exactly: NONE
                        
                        Respond in this format:
                        NUDGE: <text>|PRIORITY: <low|medium|high|urgent>
                        or just: NONE
                        """
                    )
                    scanThreadId = thread.id
                }
                
                guard let threadId = scanThreadId else { return }
                
                try await codex.startTurn(threadId: threadId, message: context)
                
                // The response comes via onTurnEvent — coordinator routes it back
            } catch {
                print("🔔 Scan failed: \(error)")
            }
        }
    }
    
    /// Process scan result from Codex
    func handleScanResult(_ text: String) {
        guard text != "NONE" else { return }
        
        let parts = text.split(separator: "|")
        let nudgeText = parts.first.map { String($0.replacingOccurrences(of: "NUDGE: ", with: "")) } ?? text
        
        let priority: Nudge.Priority
        if parts.count > 1 {
            switch parts[1].replacingOccurrences(of: "PRIORITY: ", with: "").trimmingCharacters(in: .whitespaces) {
            case "urgent": priority = .urgent
            case "high": priority = .high
            case "medium": priority = .medium
            default: priority = .low
            }
        } else {
            priority = .medium
        }
        
        let nudge = Nudge(text: nudgeText, priority: priority, context: "screen scan")
        lastNudgeTime = Date()
        onNudge?(nudge)
        
        print("🔔 Nudge: \(nudgeText) [\(priority)]")
    }
}
