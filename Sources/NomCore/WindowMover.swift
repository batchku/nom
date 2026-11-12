import Foundation
import ApplicationServices
import AppKit
import os

/// Moves the captured window through a verified title-bar drag. Same-display
/// moves use Ctrl+Left/Right, whose registrations survive the macOS 27 failures
/// affecting Desktop N shortcuts. Cross-display moves prepare the destination
/// before grabbing, then carry the window onto that display.
///
/// Requires Accessibility permission. Success means the window belongs to the
/// destination space after mouse-up, with that space visible.
@MainActor
public enum WindowMover {
    private static let log = Logger(subsystem: "com.teambrilliant.nom", category: "WindowMover")
    private static var isMoving = false

    /// AX roles that are safe to press on: draggable window chrome, never a
    /// control that a mouse-down/up would activate (buttons, tabs, fields).
    private static let draggableRoles: Set<String> = [
        "AXWindow", "AXToolbar", "AXGroup", "AXStaticText",
        "AXSplitGroup", "AXLayoutArea", "AXUnknown",
    ]

    /// Call with the caller's UI dismissed. Captures the window before any
    /// space switch or app activation can change the app's focused window.
    @discardableResult
    public static func moveFocusedWindow(ofPid pid: pid_t, to space: SpaceInfo) async -> Bool {
        guard !isMoving else { return false }
        isMoving = true
        defer { isMoving = false }
        guard !Task.isCancelled, !space.isFullscreen,
              let target = SpaceReader.allSpaces().first(where: { $0.spaceId == space.spaceId }),
              let window = focusedWindow(ofPid: pid),
              let windowID = windowID(of: window),
              let memberships = SpaceReader.spaceIds(containingWindow: windowID),
              memberships.count == 1,
              let sourceSpace = SpaceReader.allSpaces().first(where: { $0.spaceId == memberships[0] })
        else {
            log.error("move aborted: cannot identify a movable window and its destination")
            return false
        }
        if sourceSpace.spaceId == target.spaceId { return true }
        let crossDisplay = sourceSpace.displayId != target.displayId
        let targetBounds = displayBounds(forDisplayId: target.displayId)
        guard !crossDisplay || targetBounds != nil else { return false }

        // A held window cannot be dropped into a fullscreen space. Prepare
        // the other display first, while this window is still on its source.
        if crossDisplay, !(await SpaceSwitcher.switchTo(target)) {
            log.error("move aborted: destination display did not switch")
            return false
        }
        guard !Task.isCancelled else { return false }
        if NSWorkspace.shared.frontmostApplication?.processIdentifier != pid {
            guard NSRunningApplication(processIdentifier: pid)?.activate(options: []) == true else {
                log.error("move aborted: could not activate the window's app")
                return false
            }
        }
        let raised = AXUIElementPerformAction(window, kAXRaiseAction as CFString)
        guard raised == .success else {
            log.error("move aborted: could not raise the captured window (AX error \(raised.rawValue))")
            return false
        }
        try? await Task.sleep(for: .milliseconds(150))
        guard !Task.isCancelled,
              SpaceReader.spaceIds(containingWindow: windowID) == [sourceSpace.spaceId],
              SpaceReader.currentSpaceId(forDisplay: sourceSpace.displayId) == sourceSpace.spaceId,
              !crossDisplay || SpaceReader.currentSpaceId(forDisplay: target.displayId) == target.spaceId,
              let windowFrame = frame(of: window)
        else {
            log.error("move aborted: window or display changed before the drag")
            return false
        }

        guard let source = CGEventSource(stateID: .privateState) else { return false }
        var previousPoint = CGEvent(source: nil)?.location
        func post(_ type: CGEventType, at point: CGPoint) {
            guard let event = CGEvent(
                mouseEventSource: source, mouseType: type,
                mouseCursorPosition: point, mouseButton: .left
            ) else { return }
            event.flags = []
            // Keep relative motion consistent with each absolute location.
            if let previousPoint {
                event.setIntegerValueField(.mouseEventDeltaX, value: Int64((point.x - previousPoint.x).rounded()))
                event.setIntegerValueField(.mouseEventDeltaY, value: Int64((point.y - previousPoint.y).rounded()))
            }
            previousPoint = point
            // Repeated grabs must not become a title-bar double-click.
            event.setIntegerValueField(.mouseEventClickState, value: 1)
            event.post(tap: .cgSessionEventTap)
        }

        let restorePoint = CGEvent(source: nil)?.location
        defer {
            if let restorePoint { CGWarpMouseCursorPosition(restorePoint) }
        }
        guard var holdPoint = await engageDrag(
            on: window, windowID: windowID, ofPid: pid, frame: windowFrame,
            displayBounds: displayBounds(forDisplayId: sourceSpace.displayId), post: post
        ) else {
            log.error("move aborted: could not grab the window's title bar")
            return false
        }
        let startPoint = holdPoint
        var holding = true
        defer {
            if holding { post(.leftMouseUp, at: holdPoint) }
        }

        let switched: Bool
        if crossDisplay, let targetBounds {
            let destination = CGPoint(x: targetBounds.midX, y: targetBounds.midY)
            for step in 1...12 {
                guard !Task.isCancelled else { return false }
                let t = CGFloat(step) / 12
                holdPoint = CGPoint(
                    x: startPoint.x + (destination.x - startPoint.x) * t,
                    y: startPoint.y + (destination.y - startPoint.y) * t
                )
                post(.leftMouseDragged, at: holdPoint)
                try? await Task.sleep(for: .milliseconds(25))
            }
            try? await Task.sleep(for: .milliseconds(300))
            switched = SpaceReader.currentSpaceId(forDisplay: target.displayId) == target.spaceId
        } else {
            switched = await switchWhileDragging(to: target, windowID: windowID, source: source)
        }
        guard !Task.isCancelled else { return false }
        if !switched {
            // If a transition stalls after earlier steps succeeded, try to
            // carry the held window back before releasing it.
            if crossDisplay {
                holdPoint = startPoint
                post(.leftMouseDragged, at: holdPoint)
                try? await Task.sleep(for: .milliseconds(150))
            } else if !(await switchWhileDragging(to: sourceSpace, windowID: windowID, source: source)) {
                log.error("move failed and the source space could not be restored")
            }
        }
        post(.leftMouseUp, at: holdPoint)
        holding = false

        // A display switch alone is insufficient: some macOS paths leave the
        // window behind or snap back to its source when the button is released.
        for _ in 0..<20 {
            try? await Task.sleep(for: .milliseconds(50))
            guard !Task.isCancelled else { return false }
            if switched,
               SpaceReader.currentSpaceId(forDisplay: target.displayId) == target.spaceId,
               SpaceReader.spaceIds(containingWindow: windowID) == [target.spaceId] {
                if !crossDisplay, !(await restoreFrame(of: window, windowID: windowID, to: windowFrame)) {
                    log.error("window moved, but its original frame could not be restored")
                }
                log.info("window \(windowID) moved to space \(target.spaceId)")
                return true
            }
        }
        if SpaceReader.spaceIds(containingWindow: windowID) == [sourceSpace.spaceId] {
            _ = await restoreFrame(of: window, windowID: windowID, to: windowFrame)
        }
        log.error("move failed: window \(windowID) did not arrive on space \(target.spaceId)")
        return false
    }

    /// Walk the display's actual layout, verifying progress after each key.
    /// Observe the resulting ID because macOS may skip fullscreen spaces
    /// while dragging. Never infer adjacency from global desktop numbers.
    private static func switchWhileDragging(to target: SpaceInfo, windowID: CGWindowID, source: CGEventSource) async -> Bool {
        guard let ids = SpaceReader.displaySpaceIds().first(where: { $0.displayId == target.displayId })?.spaceIds,
              var current = SpaceReader.currentSpaceId(forDisplay: target.displayId),
              let route = SpaceMoveRoute(spaceIds: ids, source: current, destination: target.spaceId)
        else { return false }
        if current == target.spaceId { return true }
        for _ in 0..<route.maxTransitions {
            guard !Task.isCancelled, SpaceSwitcher.postSymbolicHotKey(route.hotKey, source: source, tap: .cgSessionEventTap) else { return false }
            var arrived: Int?
            for _ in 0..<30 {
                try? await Task.sleep(for: .milliseconds(50))
                guard !Task.isCancelled else { return false }
                if let observed = SpaceReader.currentSpaceId(forDisplay: target.displayId), observed != current {
                    arrived = observed
                    break
                }
            }
            guard let arrived, route.allowsProgress(from: current, to: arrived) else {
                log.error("move stopped: directional shortcut did not advance toward space \(target.spaceId)")
                return false
            }
            // Do not post the next key while the previous animation settles.
            try? await Task.sleep(for: .milliseconds(300))
            if SpaceReader.allSpaces().contains(where: { $0.spaceId == arrived }),
               SpaceReader.spaceIds(containingWindow: windowID) != [arrived] {
                log.error("move stopped: the desktop changed without the held window")
                return false
            }
            current = arrived
            if current == target.spaceId { return !Task.isCancelled }
        }
        return false
    }

    // MARK: - Grab engagement

    /// Full-height windows can refuse a vertical drag. Probe horizontally,
    /// preserving the original frame even if macOS first restores a tiled
    /// window to a smaller size. A resize alone never proves a title-bar hold.
    private static func engageDrag(
        on window: AXUIElement,
        windowID: CGWindowID,
        ofPid pid: pid_t,
        frame windowFrame: CGRect,
        displayBounds: CGRect?,
        post: (CGEventType, CGPoint) -> Void
    ) async -> CGPoint? {
        let offset = WindowDragProbe.offset(for: windowFrame, within: displayBounds)
        for candidate in grabCandidates(for: window, frame: windowFrame) {
            guard !Task.isCancelled else { return nil }
            guard isDraggableChrome(at: candidate, expectedPid: pid, window: window) else {
                log.debug("candidate (\(candidate.x), \(candidate.y)) rejected by hit-test")
                continue
            }
            if let held = await probeDrag(
                at: candidate, on: window, windowID: windowID, offset: offset, post: post
            ) { return held }

            // probeDrag releases before returning nil. Wait out any native
            // untile animation and verify restoration before reusing points.
            guard await restoreFrame(of: window, windowID: windowID, to: windowFrame) else {
                log.error("move aborted: failed probe's original frame could not be restored")
                return nil
            }
        }
        return nil
    }

    private static func probeDrag(
        at candidate: CGPoint, on window: AXUIElement, windowID: CGWindowID,
        offset: CGVector, post: (CGEventType, CGPoint) -> Void
    ) async -> CGPoint? {
        post(.mouseMoved, candidate)
        try? await Task.sleep(for: .milliseconds(40))
        guard !Task.isCancelled else { return nil }
        post(.leftMouseDown, candidate)
        var point = candidate
        var engaged = false
        defer {
            if !engaged { post(.leftMouseUp, point) }
        }
        try? await Task.sleep(for: .milliseconds(80))
        // Establish native drag tracking before measuring translation. A
        // tiled window can restore its saved size during this first pixel.
        point = CGPoint(x: candidate.x + offset.dx / 10, y: candidate.y + offset.dy / 10)
        post(.leftMouseDragged, point)
        guard var before = await settledFrame(of: window, windowID: windowID) else { return nil }

        // One retry allows macOS to finish restoring a tiled/zoomed window.
        // A resize edge will resize again on that retry and be rejected.
        for attempt in 0..<2 {
            guard !Task.isCancelled else { return nil }
            let start = point
            point = CGPoint(x: start.x + offset.dx, y: start.y + offset.dy)
            post(.leftMouseDragged, point)
            guard let after = await settledFrame(of: window, windowID: windowID) else { return nil }

            if WindowDragProbe.isWindowDrag(before: before, after: after, expectedOffset: offset) {
                engaged = true
                return point
            }
            guard attempt == 0,
                  abs(after.width - before.width) > 1 || abs(after.height - before.height) > 1
            else {
                log.debug("candidate did not translate the window in the probe direction")
                return nil
            }
            log.debug("window resized during grab; verifying translation after it settled")
            before = after
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
    private static func isDraggableChrome(at point: CGPoint, expectedPid pid: pid_t, window: AXUIElement) -> Bool {
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
        guard draggableRoles.contains(role) else { return false }
        if CFEqual(element, window) { return true }
        var containingWindow: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXWindowAttribute as CFString, &containingWindow) == .success,
              let containingWindow, CFGetTypeID(containingWindow) == AXUIElementGetTypeID()
        else { return false }
        return CFEqual(containingWindow, window)
    }

    // MARK: - AX / display helpers

    /// AX geometry can lead WindowServer during the native untile animation.
    /// Require both readings to agree and stay stable for three polls.
    private static func settledFrame(of window: AXUIElement, windowID: CGWindowID) async -> CGRect? {
        var previous: CGRect?
        var stableSamples = 0
        for _ in 0..<20 {
            guard !Task.isCancelled else { return nil }
            try? await Task.sleep(for: .milliseconds(50))
            guard let axFrame = frame(of: window), let serverFrame = windowServerFrame(windowID),
                  framesMatch(axFrame, serverFrame)
            else {
                previous = nil
                stableSamples = 0
                continue
            }
            if let previous, framesMatch(previous, serverFrame) {
                stableSamples += 1
            } else {
                stableSamples = 1
            }
            previous = serverFrame
            if stableSamples >= 3 { return serverFrame }
        }
        log.error("window geometry did not settle within one second")
        return nil
    }

    private static func windowServerFrame(_ windowID: CGWindowID) -> CGRect? {
        guard let windows = CGWindowListCopyWindowInfo(.optionIncludingWindow, windowID) as? [NSDictionary],
              let bounds = windows.first?[kCGWindowBounds] as? NSDictionary
        else { return nil }
        return CGRect(dictionaryRepresentation: bounds as CFDictionary)
    }

    private static func framesMatch(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
        abs(lhs.minX - rhs.minX) <= 1 && abs(lhs.minY - rhs.minY) <= 1
            && abs(lhs.width - rhs.width) <= 1 && abs(lhs.height - rhs.height) <= 1
    }

    private static func restoreFrame(of window: AXUIElement, windowID: CGWindowID, to original: CGRect) async -> Bool {
        guard let current = await settledFrame(of: window, windowID: windowID) else { return false }
        if framesMatch(current, original) { return true }
        if current.size != original.size {
            var size = original.size
            guard let value = AXValueCreate(.cgSize, &size),
                  AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, value) == .success
            else { return false }
        }
        var position = original.origin
        guard let value = AXValueCreate(.cgPoint, &position),
              AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, value) == .success,
              let restored = await settledFrame(of: window, windowID: windowID)
        else { return false }
        return framesMatch(restored, original)
    }

    private static func windowID(of window: AXUIElement) -> CGWindowID? {
        var id: CGWindowID = 0
        guard _AXUIElementGetWindow(window, &id) == .success, id != 0 else { return nil }
        return id
    }

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
        Displays.directDisplayID(forDisplayId: displayId).map(CGDisplayBounds)
    }
}
