import SwiftUI
import Combine

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
    private var statusItem: NSStatusItem?
    private var settingsWindow: NSWindow?
    private var cancellables = Set<AnyCancellable>()

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
        observeCoordinator()
        
        // Launch Codex binary and connect
        coordinator.startCodexAndConnect()
        
        print("🛰️ Aura launched")
    }
    
    func applicationWillTerminate(_ notification: Notification) {
        coordinator.shutdown()
    }
    
    // MARK: - Status Bar
    
    private func setupStatusBar() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem = item
        
        if let button = item.button {
            button.image = NSImage(systemSymbolName: "circle.circle.fill", accessibilityDescription: "Aura")
            button.image?.size = NSSize(width: 18, height: 18)
        }
        
        rebuildStatusMenu()
    }

    private func rebuildStatusMenu() {
        guard let item = statusItem else { return }
        let menu = NSMenu()

        if let email = coordinator.accountEmail {
            let accountItem = NSMenuItem(title: email, action: nil, keyEquivalent: "")
            accountItem.isEnabled = false
            menu.addItem(accountItem)
            if let plan = coordinator.accountPlan {
                let planItem = NSMenuItem(title: plan, action: nil, keyEquivalent: "")
                planItem.isEnabled = false
                menu.addItem(planItem)
            }
            menu.addItem(.separator())
        }

        addMenuItem("Show / Hide Conversation", action: #selector(toggleConversation), key: "", to: menu)
        addMenuItem("Start / Stop Voice", action: #selector(toggleVoice), key: "v", to: menu)
        menu.addItem(.separator())
        addMenuItem("Sign In with ChatGPT...", action: #selector(loginWithChatGPT), key: "", to: menu)
        addMenuItem("Switch ChatGPT Account...", action: #selector(switchChatGPTAccount), key: "", to: menu)
        let signOutItem = addMenuItem("Sign Out", action: #selector(signOut), key: "", to: menu)
        signOutItem.isEnabled = coordinator.accountEmail != nil
        menu.addItem(.separator())
        addMenuItem("Reconnect Codex", action: #selector(reconnectCodex), key: "", to: menu)
        addMenuItem("Settings...", action: #selector(openSettings), key: ",", to: menu)
        menu.addItem(.separator())
        addMenuItem("Quit Aura", action: #selector(quitAura), key: "q", to: menu)
        
        item.menu = menu
    }

    @discardableResult
    private func addMenuItem(_ title: String, action: Selector, key: String, to menu: NSMenu) -> NSMenuItem {
        let menuItem = NSMenuItem(title: title, action: action, keyEquivalent: key)
        menuItem.target = self
        menu.addItem(menuItem)
        return menuItem
    }

    private func observeCoordinator() {
        coordinator.$accountEmail
            .combineLatest(coordinator.$accountPlan)
            .sink { [weak self] _ in
                self?.rebuildStatusMenu()
            }
            .store(in: &cancellables)
    }
    
    @objc private func toggleConversation() {
        CompanionWindowManager.shared.toggleConversation()
    }
    
    @objc private func toggleVoice() {
        if coordinator.isVoiceSessionActive {
            coordinator.stopVoiceConversation()
        } else {
            coordinator.startVoiceConversation()
        }
    }

    @objc private func loginWithChatGPT() {
        coordinator.loginWithChatGPT()
    }

    @objc private func switchChatGPTAccount() {
        coordinator.switchChatGPTAccount()
    }

    @objc private func signOut() {
        coordinator.signOut()
    }

    @objc private func reconnectCodex() {
        coordinator.reconnect()
    }
    
    @objc private func openSettings() {
        if let settingsWindow {
            settingsWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 450, height: 320),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Aura Settings"
        window.contentView = NSHostingView(rootView: SettingsView(coordinator: coordinator))
        window.center()
        window.isReleasedWhenClosed = false
        settingsWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func quitAura() {
        NSApp.terminate(nil)
    }
}
