import SwiftUI

/// The floating companion window — glowing orb on top of everything.
final class CompanionWindowController {
    private var panels: [CompanionPanel] = []

    func spawn(on screens: [NSScreen]) {
        panels.forEach { $0.close() }
        panels.removeAll()

        for screen in screens {
            let panel = CompanionPanel(for: screen)
            panels.append(panel)
        }
    }
}

private final class CompanionPanel: NSPanel {
    private let hostingView: NSHostingView<AuraCompanionView>

    init(for screen: NSScreen) {
        let size = CGSize(width: 100, height: 100)
        let origin = CGPoint(
            x: screen.visibleFrame.maxX - size.width - 16,
            y: screen.visibleFrame.minY + 16
        )

        self.hostingView = NSHostingView(rootView: AuraCompanionView())

        super.init(
            contentRect: NSRect(origin: origin, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = false
        isMovableByWindowBackground = true

        contentView = hostingView
        makeKeyAndOrderFront(nil)
    }

    override var canBecomeKey: Bool { true }
}

final class CompanionWindowManager {
    static let shared = CompanionWindowManager()
    private let controller = CompanionWindowController()

    func spawnCompanion(on screens: [NSScreen]) {
        controller.spawn(on: screens)
    }
}
