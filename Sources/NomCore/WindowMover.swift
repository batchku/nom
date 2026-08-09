import Foundation
import ApplicationServices

/// Moves another app's window to a different space by synthesizing a title-bar
/// drag while the space switches underneath it: mouse-down on the title bar,
/// post the Mission Control "Switch to Desktop N" hotkey via SpaceSwitcher,
/// wait for the switch to commit, mouse-up. macOS natively carries a held
/// window along with a space switch — the classic Hammerspoon
/// moveWindowOneSpace technique, also used by Rectangle Pro.
///
/// The direct APIs (SLSMoveWindowsToManagedSpace /
/// SLSSpaceAddWindowsAndRemoveFromSpaces) stopped working for unprivileged
/// processes around macOS 14.5 and now require a SIP-disabled scripting
/// addition (yabai-style) — off-limits per CLAUDE.md.
///
/// Requires the Accessibility permission (AX window lookup + posting events).
/// Side effect: the current space follows the window to the destination.
public enum WindowMover {
    /// How long to wait for the space switch to commit before giving up.
    private static let switchTimeout: Duration = .seconds(2)
    private static let switchPollInterval: Duration = .milliseconds(50)

    /// Move `pid`'s focused window to the space with the given global
    /// Mission Control index. Returns false if the window can't be found,
    /// isn't movable (fullscreen), or the switch never committed.
    ///
    /// Call only with our own UI dismissed — this synthesizes real mouse
    /// events at the target window's title bar.
    @discardableResult
    public static func moveFocusedWindow(
        ofPid pid: pid_t,
        toSpaceIndex index: Int,
        targetSpaceId: Int
    ) async -> Bool {
        guard index >= 1, index <= SpaceSwitcher.maxJumpIndex else { return false }
        guard SpaceReader.activeSpaceId() != targetSpaceId else { return false }
        guard let grabPoint = titleBarGrabPoint(forPid: pid) else { return false }

        let source = CGEventSource(stateID: .hidSystemState)
        func post(_ type: CGEventType, at point: CGPoint) {
            CGEvent(
                mouseEventSource: source,
                mouseType: type,
                mouseCursorPosition: point,
                mouseButton: .left
            )?.post(tap: .cghidEventTap)
        }

        let restorePoint = CGEvent(source: nil)?.location

        // Hold the title bar. No drag movement needed — WindowServer carries
        // any window whose title bar is held through a space switch; a
        // horizontal jiggle can instead start a tab drag in tabbed apps.
        post(.leftMouseDown, at: grabPoint)
        try? await Task.sleep(for: .milliseconds(150))

        var switched = false
        if SpaceSwitcher.jump(toIndex: index) {
            var waited: Duration = .zero
            while waited < switchTimeout {
                try? await Task.sleep(for: switchPollInterval)
                waited += switchPollInterval
                if SpaceReader.activeSpaceId() == targetSpaceId {
                    switched = true
                    break
                }
            }
        }

        if switched {
            // Let the slide animation settle before dropping the window.
            try? await Task.sleep(for: .milliseconds(300))
        }
        post(.leftMouseUp, at: grabPoint)

        if let restorePoint {
            try? await Task.sleep(for: .milliseconds(50))
            CGWarpMouseCursorPosition(restorePoint)
        }
        return switched
    }

    /// A point on the focused window's draggable title bar in global (CG,
    /// top-left origin) coordinates: just right of the zoom button, vertically
    /// centered on it. Mid-width is NOT safe — in tabbed/unified-toolbar apps
    /// (browsers, terminals) it lands on a tab or URL field, which won't drag
    /// the window. Returns nil if the app has no draggable focused window.
    private static func titleBarGrabPoint(forPid pid: pid_t) -> CGPoint? {
        let app = AXUIElementCreateApplication(pid)

        var windowRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &windowRef) == .success,
              let windowRef, CFGetTypeID(windowRef) == AXUIElementGetTypeID()
        else { return nil }
        let window = windowRef as! AXUIElement

        // Fullscreen windows live on their own space and can't be dragged.
        var fullscreenRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(window, "AXFullScreen" as CFString, &fullscreenRef) == .success,
           let isFullscreen = fullscreenRef as? Bool, isFullscreen {
            return nil
        }

        var zoomRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(window, kAXZoomButtonAttribute as CFString, &zoomRef) == .success,
           let zoomRef, CFGetTypeID(zoomRef) == AXUIElementGetTypeID(),
           let zoomFrame = frame(of: zoomRef as! AXUIElement) {
            return CGPoint(x: zoomFrame.maxX + 6, y: zoomFrame.midY)
        }

        // No zoom button (some utility windows): just right of where the
        // traffic lights would sit.
        guard let windowFrame = frame(of: window), windowFrame.width > 90 else { return nil }
        return CGPoint(x: windowFrame.minX + 76, y: windowFrame.minY + 12)
    }

    private static func frame(of element: AXUIElement) -> CGRect? {
        var positionRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        var position = CGPoint.zero
        var size = CGSize.zero
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &positionRef) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeRef) == .success,
              let positionRef, CFGetTypeID(positionRef) == AXValueGetTypeID(),
              let sizeRef, CFGetTypeID(sizeRef) == AXValueGetTypeID(),
              AXValueGetValue(positionRef as! AXValue, .cgPoint, &position),
              AXValueGetValue(sizeRef as! AXValue, .cgSize, &size)
        else { return nil }
        return CGRect(origin: position, size: size)
    }
}
