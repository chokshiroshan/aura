import SwiftUI

/// The floating companion — orb with expandable conversation.
///
/// Two states:
/// - **Collapsed**: Just the glowing orb, always on screen
/// - **Expanded**: Orb + conversation bubble, click to toggle
///
/// The orb is a presence. The conversation is temporary.
final class CompanionWindowController {
    private var panels: [CompanionPanel] = []
    weak var coordinator: AuraCoordinator?

    func spawn(on screens: [NSScreen], coordinator: AuraCoordinator) {
        panels.forEach { $0.close() }
        panels.removeAll()
        self.coordinator = coordinator

        for screen in screens {
            let panel = CompanionPanel(for: screen, coordinator: coordinator)
            panels.append(panel)
        }
    }

    func closeConversations() {
        panels.forEach { $0.collapse() }
    }
}

// MARK: - Panel

final class CompanionPanel: NSPanel {
    private let orbSize: CGFloat = 100
    private let bubbleWidth: CGFloat = 340
    private let maxBubbleHeight: CGFloat = 420
    
    private let coordinator: AuraCoordinator
    private var isExpanded = false
    
    // Orb
    private let orbHosting: NSHostingView<AuraCompanionView>
    
    // Conversation bubble
    private let bubblePanel: NSPanel
    
    init(for screen: NSScreen, coordinator: AuraCoordinator) {
        self.coordinator = coordinator
        
        let size = CGSize(width: orbSize, height: orbSize)
        let origin = CGPoint(
            x: screen.visibleFrame.maxX - size.width - 20,
            y: screen.visibleFrame.minY + 20
        )
        
        self.orbHosting = NSHostingView(rootView: AuraCompanionView(coordinator: coordinator))
        
        // Conversation bubble — separate panel so it can be positioned independently
        let bubbleFrame = NSRect(x: 0, y: 0, width: bubbleWidth, height: maxBubbleHeight)
        self.bubblePanel = NSPanel(
            contentRect: bubbleFrame,
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        bubblePanel.isOpaque = false
        bubblePanel.backgroundColor = .clear
        bubblePanel.hasShadow = true
        bubblePanel.level = .floating
        bubblePanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        bubblePanel.titlebarAppearsTransparent = true
        bubblePanel.titleVisibility = .hidden
        
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
        
        contentView = orbHosting
        makeKeyAndOrderFront(nil)
    }
    
    override func mouseDown(with event: NSEvent) {
        toggleConversation()
    }
    
    func collapse() {
        guard isExpanded else { return }
        isExpanded = false
        bubblePanel.orderOut(nil)
    }
    
    private func toggleConversation() {
        if isExpanded {
            collapse()
        } else {
            expandConversation()
        }
    }
    
    private func expandConversation() {
        isExpanded = true
        
        // Position bubble above the orb
        let orbFrame = frame
        let bubbleX = orbFrame.midX - bubbleWidth / 2
        let bubbleY = orbFrame.maxY + 12
        
        // Keep on screen
        let screenFrame = NSScreen.main?.visibleFrame ?? NSRect.zero
        let clampedX = max(screenFrame.minX + 8, min(bubbleX, screenFrame.maxX - bubbleWidth - 8))
        
        bubblePanel.setFrame(NSRect(x: clampedX, y: bubbleY, width: bubbleWidth, height: maxBubbleHeight), display: false)
        bubblePanel.contentView = NSHostingView(rootView: ConversationBubble(coordinator: coordinator))
        bubblePanel.makeKeyAndOrderFront(nil)
    }
    
    override var canBecomeKey: Bool { true }
}

// MARK: - Manager

final class CompanionWindowManager {
    static let shared = CompanionWindowManager()
    private let controller = CompanionWindowController()

    func spawnCompanion(on screens: [NSScreen], coordinator: AuraCoordinator) {
        controller.spawn(on: screens, coordinator: coordinator)
    }
    
    func closeConversations() {
        controller.closeConversations()
    }
}
