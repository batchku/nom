import Foundation
import ApplicationServices

/// Jumps to a space by posting its Mission Control "Switch to Desktop N"
/// keyboard shortcut. If the shortcut is disabled in System Settings (the
/// default), it is enabled just long enough to deliver the event, then
/// restored — the same technique Hammerspoon's hs.spaces.gotoSpace uses.
///
/// Requires the Accessibility permission (posting keyboard events).
public enum SpaceSwitcher {
    /// macOS defines "Switch to Desktop N" hotkeys for desktops 1–16.
    public static let maxJumpIndex = 16

    private static let desktop1HotKey: Int32 = 118

    public static var hasAccessibilityPermission: Bool {
        AXIsProcessTrusted()
    }

    /// Shows the system Accessibility prompt if not yet trusted.
    public static func requestAccessibilityPermission() {
        // Literal key: kAXTrustedCheckOptionPrompt is a global var, which Swift 6
        // strict concurrency rejects.
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
    }

    /// Jump to the space with the given global Mission Control index (1-based).
    /// Returns false if the index is out of hotkey range or the event could
    /// not be constructed.
    @discardableResult
    public static func jump(toIndex index: Int) -> Bool {
        guard index >= 1, index <= maxJumpIndex else { return false }
        return postSymbolicHotKey(desktop1HotKey + Int32(index - 1))
    }

    /// Post any macOS symbolic hotkey (e.g. 32 = Mission Control) through the
    /// enable-post-restore dance described above.
    @discardableResult
    public static func postSymbolicHotKey(_ hotKey: Int32) -> Bool {
        var keyEquivalent: UInt16 = 0
        var virtualKey: UInt16 = 0
        var modifiers: UInt64 = 0
        guard SLSGetSymbolicHotKeyValue(hotKey, &keyEquivalent, &virtualKey, &modifiers) == 0 else {
            return false
        }

        let wasEnabled = SLSIsSymbolicHotKeyEnabled(hotKey)
        if !wasEnabled {
            _ = SLSSetSymbolicHotKeyEnabled(hotKey, true)
        }

        let source = CGEventSource(stateID: .hidSystemState)
        let flags = CGEventFlags(rawValue: modifiers)
        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(virtualKey), keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(virtualKey), keyDown: false)
        else {
            if !wasEnabled { _ = SLSSetSymbolicHotKeyEnabled(hotKey, false) }
            return false
        }
        keyDown.flags = flags
        keyUp.flags = flags
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)

        if !wasEnabled {
            // Restore only after WindowManager has processed the event.
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) {
                _ = SLSSetSymbolicHotKeyEnabled(hotKey, false)
            }
        }
        return true
    }
}
