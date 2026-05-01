import Foundation
import AppKit
import ApplicationServices
import AVFoundation

/// Checks and requests the three macOS permissions Flow needs.
///
/// 1. Microphone — for audio capture
/// 2. Accessibility — for global hotkey (CGEventTap) + text injection
/// 3. Input Monitoring — for keystroke detection
final class PermissionsManager {
    static let shared = PermissionsManager()

    private init() {}

    struct PermissionStatus {
        let microphone: Bool
        let accessibility: Bool
        let inputMonitoring: Bool

        var allGranted: Bool {
            microphone && accessibility && inputMonitoring
        }

        var missing: [String] {
            var list: [String] = []
            if !microphone { list.append("Microphone") }
            if !accessibility { list.append("Accessibility") }
            if !inputMonitoring { list.append("Input Monitoring") }
            return list
        }
    }

    /// Check all permission statuses.
    func checkAll() -> PermissionStatus {
        PermissionStatus(
            microphone: checkMicrophone(),
            accessibility: checkAccessibility(),
            inputMonitoring: checkInputMonitoring()
        )
    }

    /// Check microphone permission.
    func checkMicrophone() -> Bool {
        if #available(macOS 14.0, *) {
            return AVAudioApplication.shared.recordPermission == .granted
        } else {
            return AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        }
    }

    /// Request microphone permission.
    func requestMicrophone() async -> Bool {
        await withCheckedContinuation { cont in
            AVAudioApplication.requestRecordPermission { granted in
                cont.resume(returning: granted)
            }
        }
    }

    /// Check accessibility permission.
    func checkAccessibility() -> Bool {
        AXIsProcessTrustedWithOptions(nil)
    }

    /// Request accessibility permission (opens System Settings).
    func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
    }

    /// Check input monitoring permission.
    /// There's no direct API — we check if CGEventTap can be created.
    func checkInputMonitoring() -> Bool {
        // Try to create a temporary event tap
        let eventMask: CGEventMask = (1 << CGEventType.keyDown.rawValue)
        let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: eventMask,
            callback: { _, _, event, _ in return Unmanaged.passUnretained(event) },
            userInfo: nil
        )

        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            return true
        }
        return false
    }

    /// Open System Settings to the Accessibility pane.
    func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Open System Settings to the Input Monitoring pane.
    func openInputMonitoringSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent") {
            NSWorkspace.shared.open(url)
        }
    }
}
