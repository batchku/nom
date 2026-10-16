import Foundation
import ApplicationServices
import os

/// Jumps to a space by posting its Mission Control "Switch to Desktop N"
/// keyboard shortcut. If the shortcut is disabled in System Settings (the
/// default), it is enabled just long enough to deliver the event, then
/// restored — the same technique Hammerspoon's hs.spaces.gotoSpace uses.
///
/// `switchTo` wraps that in a verified switch with a Mission Control
/// fallback, because macOS 27 silently drops the Desktop N hotkey
/// registrations (observed 27.0.1: everything past Desktop 3 while a
/// secondary display had a single space; adding and deleting a desktop
/// re-registered them). `SLSSetSymbolicHotKeyEnabled` still reads back
/// true in that state, so "the display did not switch" is the only signal.
///
/// Requires the Accessibility permission (posting keyboard events).
public enum SpaceSwitcher {
    private static let log = Logger(subsystem: "com.teambrilliant.nom", category: "SpaceSwitcher")

    /// macOS defines "Switch to Desktop N" hotkeys for desktops 1–16.
    public static let maxJumpIndex = 16

    /// How long a posted hotkey gets to commit before the Mission Control
    /// route takes over. Measured commits on macOS 26/27: 300–500 ms.
    public static let hotKeyTimeout: Duration = .milliseconds(1200)

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

    /// Whether a Ctrl+N hotkey exists for `space` at all: fullscreen spaces
    /// have no Mission Control number, and desktops past the 16th have no
    /// shortcut.
    public static func hasHotKey(_ space: SpaceInfo) -> Bool {
        !space.isFullscreen && space.index >= 1 && space.index <= maxJumpIndex
    }

    /// Switch to `space` and return once its display shows it. Posts the
    /// hotkey first; if the switch has not committed within `hotKeyTimeout`
    /// (or the space has no hotkey), exits to the space from Mission
    /// Control's spaces bar after `fallbackDelay` — callers whose own UI is
    /// still closing pass a delay, since any input dismisses Mission Control.
    @discardableResult
    public static func switchTo(_ space: SpaceInfo, fallbackDelay: Duration = .zero) async -> Bool {
        if SpaceReader.currentSpaceId(forDisplay: space.displayId) == space.spaceId {
            return true
        }
        if hasHotKey(space), jump(toIndex: space.index) {
            if await waitForSwitch(to: space, timeout: hotKeyTimeout) {
                return true
            }
            log.debug("hotkey for desktop \(space.index) did not commit; using Mission Control")
        }
        if fallbackDelay > .zero {
            try? await Task.sleep(for: fallbackDelay)
        }
        return await MissionControlBar.switchTo(space)
    }

    /// Poll `space`'s display until it shows `space` or `timeout` passes.
    package static func waitForSwitch(to space: SpaceInfo, timeout: Duration) async -> Bool {
        let interval: Duration = .milliseconds(50)
        var waited: Duration = .zero
        while waited < timeout {
            try? await Task.sleep(for: interval)
            waited += interval
            if SpaceReader.currentSpaceId(forDisplay: space.displayId) == space.spaceId {
                return true
            }
        }
        return false
    }

    /// Post the hotkey for the space with the given global Mission Control
    /// index (1-based). Returns false if the index is out of hotkey range or
    /// the event could not be constructed. Does not wait for the switch —
    /// see `switchTo`.
    @discardableResult
    public static func jump(toIndex index: Int) -> Bool {
        guard index >= 1, index <= maxJumpIndex else { return false }
        return postSymbolicHotKey(desktop1HotKey + Int32(index - 1))
    }

    /// Post any macOS symbolic hotkey (e.g. 32 = Mission Control) through the
    /// enable-post-restore dance described above. The previous enabled state
    /// is restored exactly: hotkeys that are on by default (Mission Control,
    /// Ctrl+arrows) stay on.
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
