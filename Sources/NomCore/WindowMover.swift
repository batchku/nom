import Foundation
import ApplicationServices
import ColorSync
import os

/// Moves another app's window to a different space by synthesizing a title-bar
/// drag while the space switches underneath it — the classic Hammerspoon
/// moveWindowOneSpace technique, also used by Rectangle Pro. The direct APIs
/// (SLSMoveWindowsToManagedSpace / SLSSpaceAddWindowsAndRemoveFromSpaces)
/// stopped working for unprivileged processes around macOS 14.5 and now
/// require a SIP-disabled scripting addition (yabai-style) — off-limits per
/// CLAUDE.md.
///
/// Two hard-won rules encoded here:
/// - Never fire the space switch until the hold is PROVEN: drag a few pixels
///   and confirm via AX that the window followed. A blind switch strands the
///   user on the target space with the window left behind.
/// - A space on another display can't be reached by switching alone — the
///   held window must first be dragged onto that display, then its space
///   switched (per-display "Current Space", not SLSGetActiveSpace).
///
/// Requires the Accessibility permission (AX window lookup + posting events).
/// Side effect: the current space follows the window to the destination.
public enum WindowMover {
    private static let log = Logger(subsystem: "com.teambrilliant.nom", category: "WindowMover")
    /// How long to wait for the space switch to commit before giving up.
    private static let switchTimeout: Duration = .seconds(2)
    private static let switchPollInterval: Duration = .milliseconds(50)
    /// Vertical probe distance used to prove the window is actually held.
    private static let probeDrop: CGFloat = 10

    /// AX roles that are safe to press on: draggable window chrome, never a
    /// control that a mouse-down/up would activate (buttons, tabs, fields).
    private static let draggableRoles: Set<String> = [
        "AXWindow", "AXToolbar", "AXGroup", "AXStaticText",
        "AXSplitGroup", "AXLayoutArea", "AXUnknown",
    ]

    /// Move `pid`'s focused window to the space with the given global
    /// Mission Control index. Returns false — without switching spaces —
    /// if the window can't be found or can't be verifiably grabbed.
    ///
    /// Call only with our own UI dismissed — this synthesizes real mouse
    /// events at the target window's title bar.
    @discardableResult
    public static func moveFocusedWindow(
        ofPid pid: pid_t,
        toSpaceIndex index: Int,
        targetSpaceId: Int,
        targetDisplayId: String
    ) async -> Bool {
        guard index >= 1, index <= SpaceSwitcher.maxJumpIndex else {
            log.debug("abort: index \(index) out of hotkey range")
            return false
        }
        guard SpaceReader.currentSpaceId(forDisplay: targetDisplayId) != targetSpaceId else {
            log.debug("abort: target space \(targetSpaceId) already current on its display")
            return false
        }
        guard let window = focusedWindow(ofPid: pid),
              let windowFrame = frame(of: window)
        else {
            log.debug("abort: no movable focused window for pid \(pid)")
            return false
        }

        let source = CGEventSource(stateID: .hidSystemState)
        func post(_ type: CGEventType, at point: CGPoint) {
            guard let event = CGEvent(
                mouseEventSource: source,
                mouseType: type,
                mouseCursorPosition: point,
                mouseButton: .left
            ) else { return }
            // Always a single click — without this, re-grabbing the same
            // title-bar point twice in quick succession coalesces into a
            // double-click, which zooms the window instead of dragging it.
            event.setIntegerValueField(.mouseEventClickState, value: 1)
            event.post(tap: .cghidEventTap)
        }

        let restorePoint = CGEvent(source: nil)?.location
        defer {
            if let restorePoint { CGWarpMouseCursorPosition(restorePoint) }
        }

        // Find a grab point that provably holds the window. Button stays
        // down on success.
        guard var holdPoint = await engageDrag(
            on: window, ofPid: pid, frame: windowFrame, post: post
        ) else {
            log.debug("abort: no grab candidate engaged; window untouched, not switching")
            return false
        }
        log.debug("engaged at (\(holdPoint.x), \(holdPoint.y))")

        // A space on another display: carry the window there first.
        if let targetBounds = displayBounds(forDisplayId: targetDisplayId),
           !targetBounds.contains(holdPoint) {
            let destination = CGPoint(x: targetBounds.midX, y: targetBounds.midY)
            for step in 1...12 {
                let t = CGFloat(step) / 12
                post(.leftMouseDragged, at: CGPoint(
                    x: holdPoint.x + (destination.x - holdPoint.x) * t,
                    y: holdPoint.y + (destination.y - holdPoint.y) * t
                ))
                try? await Task.sleep(for: .milliseconds(25))
            }
            holdPoint = destination
            try? await Task.sleep(for: .milliseconds(150))
        }

        var switched = false
        if SpaceSwitcher.jump(toIndex: index) {
            var waited: Duration = .zero
            while waited < switchTimeout {
                try? await Task.sleep(for: switchPollInterval)
                waited += switchPollInterval
                if SpaceReader.currentSpaceId(forDisplay: targetDisplayId) == targetSpaceId {
                    switched = true
                    break
                }
            }
        }

        if switched {
            // Let the slide animation settle before dropping the window.
            try? await Task.sleep(for: .milliseconds(300))
        }
        post(.leftMouseUp, at: holdPoint)
        try? await Task.sleep(for: .milliseconds(50))
        log.debug("released; switch committed: \(switched)")
        return switched
    }

    // MARK: - Grab engagement

    /// Try candidate title-bar points until one provably drags the window:
    /// mouse-down, pull down a few pixels, confirm the AX position followed,
    /// pull back. Returns the held point with the button still down, or nil
    /// (button up) if nothing engaged.
    private static func engageDrag(
        on window: AXUIElement,
        ofPid pid: pid_t,
        frame windowFrame: CGRect,
        post: (CGEventType, CGPoint) -> Void
    ) async -> CGPoint? {
        for candidate in grabCandidates(for: window, frame: windowFrame) {
            guard isDraggableChrome(at: candidate, expectedPid: pid) else {
                log.debug("candidate (\(candidate.x), \(candidate.y)) rejected by hit-test")
                continue
            }
            post(.leftMouseDown, candidate)
            try? await Task.sleep(for: .milliseconds(80))
            guard let before = frame(of: window)?.origin else {
                post(.leftMouseUp, candidate)
                return nil
            }

            let probe = CGPoint(x: candidate.x, y: candidate.y + probeDrop)
            post(.leftMouseDragged, CGPoint(x: candidate.x, y: candidate.y + probeDrop / 2))
            post(.leftMouseDragged, probe)
            try? await Task.sleep(for: .milliseconds(120))

            if let after = frame(of: window)?.origin, after.y - before.y > probeDrop / 2 {
                // Held. Pull back so the window ends up where it started.
                post(.leftMouseDragged, CGPoint(x: candidate.x, y: candidate.y + probeDrop / 2))
                post(.leftMouseDragged, candidate)
                try? await Task.sleep(for: .milliseconds(80))
                return candidate
            }

            log.debug("candidate (\(candidate.x), \(candidate.y)) held but window did not follow probe")
            post(.leftMouseUp, probe)
            try? await Task.sleep(for: .milliseconds(80))
        }
        return nil
    }

    /// Points likely to be draggable chrome, best first: right of the zoom
    /// button, then farther right, then the title area. Mid-width alone is
    /// NOT safe — in tabbed/unified-toolbar apps it lands on a tab or URL
    /// field, which won't drag the window.
    private static func grabCandidates(for window: AXUIElement, frame windowFrame: CGRect) -> [CGPoint] {
        var xs: [CGFloat] = []
        let y: CGFloat

        var zoomRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(window, kAXZoomButtonAttribute as CFString, &zoomRef) == .success,
           let zoomRef, CFGetTypeID(zoomRef) == AXUIElementGetTypeID(),
           let zoomFrame = frame(of: zoomRef as! AXUIElement) {
            y = zoomFrame.midY
            xs = [zoomFrame.maxX + 8, zoomFrame.maxX + 40, zoomFrame.maxX + 90]
        } else {
            y = windowFrame.minY + 12
            xs = [windowFrame.minX + 76]
        }
        xs.append(windowFrame.midX)
        xs.append(windowFrame.minX + windowFrame.width * 0.72)

        return xs
            .filter { $0 > windowFrame.minX + 4 && $0 < windowFrame.maxX - 30 }
            .map { CGPoint(x: $0, y: y) }
    }

    /// True when the AX element under the point belongs to the target app
    /// (not some overlapping window) and is inert chrome, not a control a
    /// click would activate.
    private static func isDraggableChrome(at point: CGPoint, expectedPid pid: pid_t) -> Bool {
        var elementRef: AXUIElement?
        guard AXUIElementCopyElementAtPosition(
            AXUIElementCreateSystemWide(), Float(point.x), Float(point.y), &elementRef
        ) == .success, let element = elementRef else { return false }

        var elementPid: pid_t = 0
        guard AXUIElementGetPid(element, &elementPid) == .success, elementPid == pid else {
            return false
        }

        var roleRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleRef) == .success,
              let role = roleRef as? String
        else { return false }
        return draggableRoles.contains(role)
    }

    // MARK: - AX / display helpers

    private static func focusedWindow(ofPid pid: pid_t) -> AXUIElement? {
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
        return window
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

    /// Global bounds of the display whose ColorSync UUID matches the
    /// SkyLight "Display Identifier".
    private static func displayBounds(forDisplayId displayId: String) -> CGRect? {
        var count: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &count)
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetActiveDisplayList(count, &ids, &count)

        for id in ids {
            guard let uuid = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue() else { continue }
            if (CFUUIDCreateString(nil, uuid) as String).caseInsensitiveCompare(displayId) == .orderedSame {
                return CGDisplayBounds(id)
            }
        }
        return nil
    }
}
