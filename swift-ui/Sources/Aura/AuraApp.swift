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

final class AppDelegate: NSObject, NSApplicationHandler {
    let coordinator = AuraCoordinator()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Spawn the floating companion on every screen
        CompanionWindowManager.shared.spawnCompanion(on: NSScreen.screens)
        
        // Launch Codex binary and connect
        coordinator.startCodexAndConnect()
    }
    
    func applicationWillTerminate(_ notification: Notification) {
        coordinator.shutdown()
    }
}
