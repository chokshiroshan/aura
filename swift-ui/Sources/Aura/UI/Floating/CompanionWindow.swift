import SwiftUI
import AppKit

/// Tracks cursor position relative to the companion panel so the mascot can
/// "lean" toward the cursor when it's nearby. Vector is normalized into
/// -1..1 (clamped at 300pt screen distance).
@MainActor
final class CursorTracker: ObservableObject {
    @Published var vector: CGVector = .zero

    private var monitor: Any?
    private var anchor: CGPoint = .zero
    private let radius: CGFloat = 300
    private var lastUpdate: TimeInterval = 0

    func start(anchor: CGPoint) {
        self.anchor = anchor
        if monitor != nil { return }
        monitor = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved) { [weak self] event in
            self?.handle(event)
        }
    }

    func updateAnchor(_ anchor: CGPoint) {
        self.anchor = anchor
    }

    func stop() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
        monitor = nil
    }

    private func handle(_ event: NSEvent) {
        // Throttle ~30 Hz
        let now = ProcessInfo.processInfo.systemUptime
        if now - lastUpdate < 0.033 { return }
        lastUpdate = now

        let mouse = NSEvent.mouseLocation  // screen coords
        let dx = mouse.x - anchor.x
        let dy = mouse.y - anchor.y
        let dist = sqrt(dx * dx + dy * dy)
        if dist > radius {
            Task { @MainActor [weak self] in self?.vector = .zero }
            return
        }
        // Normalize to -1..1
        let nx = max(-1, min(1, dx / radius))
        let ny = max(-1, min(1, dy / radius))
        Task { @MainActor [weak self] in
            self?.vector = CGVector(dx: nx, dy: ny)
        }
    }

    deinit {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
    }
}

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

    func toggleConversation() {
        if panels.contains(where: { $0.isConversationExpanded }) {
            closeConversations()
        } else {
            panelNearestMouse()?.expandConversation()
        }
    }

    private func panelNearestMouse() -> CompanionPanel? {
        let mouse = NSEvent.mouseLocation
        return panels.first { NSMouseInRect(mouse, $0.screenFrame, false) } ?? panels.first
    }
}

// MARK: - Panel

final class CompanionPanel: NSPanel {
    private let orbSize: CGFloat = 140
    private let bubbleWidth: CGFloat = 340
    private let maxBubbleHeight: CGFloat = 420

    private let coordinator: AuraCoordinator
    let screenFrame: NSRect
    private var isExpanded = false
    private let cursorTracker = CursorTracker()

    // Orb
    private let orbHosting: ClickableHostingView<AuraCompanionView>

    // Conversation bubble
    private let bubblePanel: NSPanel

    init(for screen: NSScreen, coordinator: AuraCoordinator) {
        self.coordinator = coordinator
        self.screenFrame = screen.visibleFrame

        let size = CGSize(width: 140, height: 140)
        let origin = CGPoint(
            x: screen.visibleFrame.maxX - size.width - 20,
            y: screen.visibleFrame.minY + 20
        )

        let tracker = self.cursorTracker
        self.orbHosting = ClickableHostingView(
            rootView: AuraCompanionView(coordinator: coordinator, cursorTracker: tracker)
        )
        
        // Conversation bubble — separate panel so it can be positioned independently
        let bubbleFrame = NSRect(x: 0, y: 0, width: bubbleWidth, height: maxBubbleHeight)
        self.bubblePanel = ConversationPanel(
            contentRect: bubbleFrame,
            styleMask: [.borderless, .fullSizeContentView],
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
        isMovableByWindowBackground = false
        
        contentView = orbHosting
        orbHosting.onClick = { [weak self] in
            self?.toggleConversation()
        }
        makeKeyAndOrderFront(nil)
        orderFrontRegardless()

        // Cursor tracker: anchor at panel center
        let center = CGPoint(x: origin.x + size.width / 2, y: origin.y + size.height / 2)
        cursorTracker.start(anchor: center)
    }

    var isConversationExpanded: Bool { isExpanded }
    
    override func mouseDown(with event: NSEvent) {
        toggleConversation()
    }

    func collapse() {
        guard isExpanded else { return }
        isExpanded = false
        bubblePanel.orderOut(nil)
    }

    func toggleConversation() {
        if isExpanded {
            collapse()
        } else {
            expandConversation()
        }
    }
    
    func expandConversation() {
        isExpanded = true
        
        // Position bubble above the orb
        let orbFrame = frame
        let bubbleX = orbFrame.midX - bubbleWidth / 2
        let bubbleY = orbFrame.maxY + 12
        
        // Keep on screen
        let clampedX = max(screenFrame.minX + 8, min(bubbleX, screenFrame.maxX - bubbleWidth - 8))
        let clampedY = max(screenFrame.minY + 8, min(bubbleY, screenFrame.maxY - maxBubbleHeight - 8))
        
        bubblePanel.setFrame(NSRect(x: clampedX, y: clampedY, width: bubbleWidth, height: maxBubbleHeight), display: false)
        bubblePanel.contentView = NSHostingView(rootView: ConversationBubble(coordinator: coordinator))
        NSApp.activate(ignoringOtherApps: true)
        bubblePanel.makeKeyAndOrderFront(nil)
        bubblePanel.orderFrontRegardless()
    }
    
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
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

    func toggleConversation() {
        controller.toggleConversation()
    }
}

private final class ConversationPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

private final class ClickableHostingView<Content: View>: NSHostingView<Content> {
    var onClick: (() -> Void)?

    override func mouseDown(with event: NSEvent) {
        onClick?()
    }
}
