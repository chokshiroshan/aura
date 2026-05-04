import SwiftUI

@main
struct AuraApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}

// MARK: - App Delegate

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let coordinator = AuraCoordinator()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Hide from dock — Aura lives as a floating companion + menu bar
        NSApp.setActivationPolicy(.accessory)
        
        // Spawn the floating orb companion on every screen
        CompanionWindowManager.shared.spawnCompanion(
            on: NSScreen.screens,
            coordinator: coordinator
        )
        
        // Menu bar item
        setupStatusBar()
        
        // Launch Codex binary and connect
        coordinator.startCodexAndConnect()
        
        print("🛰️ Aura launched")
    }
    
    func applicationWillTerminate(_ notification: Notification) {
        coordinator.shutdown()
    }
    
    // MARK: - Status Bar
    
    private func setupStatusBar() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        
        if let button = item.button {
            button.image = NSImage(systemSymbolName: "circle.circle", accessibilityDescription: "Aura")
            button.image?.size = NSSize(width: 18, height: 18)
        }
        
        let menu = NSMenu()
        menu.addItem(withTitle: "Toggle Conversation", action: #selector(toggleConversation), keyEquivalent: "")
        menu.addItem(withTitle: "Voice Mode", action: #selector(toggleVoice), keyEquivalent: "v")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Settings...", action: #selector(openSettings), keyEquivalent: ",")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Aura", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        
        item.menu = menu
    }
    
    @objc private func toggleConversation() {
        CompanionWindowManager.shared.toggleConversation()
    }
    
    @objc private func toggleVoice() {
        switch coordinator.orbState {
        case .listening:
            coordinator.stopVoiceConversation()
        default:
            coordinator.startVoiceConversation()
        }
    }
    
    @objc private func openSettings() {
        let settingsWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 450, height: 320),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        settingsWindow.title = "Aura Settings"
        settingsWindow.contentView = NSHostingView(rootView: SettingsView(coordinator: coordinator))
        settingsWindow.center()
        settingsWindow.makeKeyAndOrderFront(nil)
    }
}
