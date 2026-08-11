import AppKit
import ApplicationServices
import os

/// Drives Mission Control's spaces bar through the Dock's accessibility
/// tree: open Mission Control, find a space's thumbnail button, perform an
/// AX action on it. "AXPress" exits to that space (the only way to reach a
/// fullscreen space — they have no Ctrl+N hotkey); "AXRemoveDesktop"
/// deletes it (see SpaceDeleter).
///
/// Requires the Accessibility permission.
public enum MissionControlBar {
    private static let log = Logger(subsystem: "com.teambrilliant.nom", category: "MissionControlBar")
    /// macOS symbolic hotkey ID for Mission Control.
    private static let missionControlHotKey: Int32 = 32
    private static let escapeKey: CGKeyCode = 53

    /// Open Mission Control, find `space`'s thumbnail, and perform `action`
    /// on it. When `closeAfter` is true, Mission Control is dismissed with
    /// Escape afterwards. On failure Mission Control is always dismissed
    /// before returning.
    @discardableResult
    public static func perform(_ action: String, on space: SpaceInfo, closeAfter: Bool) async -> Bool {
        guard let button = await openAndFindThumbnail(for: space) else { return false }

        // Don't pre-check the advertised action names — the Dock registers
        // actions like AXRemoveDesktop lazily and often reports only AXPress
        // right after Mission Control opens, even though performing works.
        guard AXUIElementPerformAction(button, action as CFString) == .success else {
            log.debug("abort: \(action) failed on space \(space.spaceId)")
            await close()
            return false
        }
        if closeAfter {
            await close()
        }
        log.debug("\(action) performed on space \(space.spaceId)")
        return true
    }

    /// Switch to a space by clicking its Mission Control thumbnail — the
    /// only route to fullscreen spaces, which have no Ctrl+N hotkey. An
    /// AXPress on the thumbnail just dismisses Mission Control without
    /// switching, and a teleported click is ignored too: the bar only
    /// honors a click after the cursor has actually hovered it, so this
    /// moves the cursor there, dwells, then clicks — and verifies the
    /// display's current space changed before reporting success.
    @discardableResult
    public static func switchTo(_ space: SpaceInfo) async -> Bool {
        guard SpaceReader.currentSpaceId(forDisplay: space.displayId) != space.spaceId else {
            return true
        }
        guard let button = await openAndFindThumbnail(for: space) else { return false }
        let thumbFrame = frame(of: button)
        guard thumbFrame.width > 0 else {
            log.debug("abort: thumbnail has no frame")
            await close()
            return false
        }

        let restorePoint = CGEvent(source: nil)?.location
        let point = CGPoint(x: thumbFrame.midX, y: thumbFrame.midY)
        let source = CGEventSource(stateID: .hidSystemState)
        func post(_ type: CGEventType, at p: CGPoint) {
            let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: p, mouseButton: .left)
            event?.setIntegerValueField(.mouseEventClickState, value: 1)
            event?.post(tap: .cghidEventTap)
        }
        post(.mouseMoved, at: point)
        try? await Task.sleep(for: .milliseconds(400))
        post(.mouseMoved, at: CGPoint(x: point.x + 2, y: point.y))
        try? await Task.sleep(for: .milliseconds(200))
        post(.leftMouseDown, at: point)
        post(.leftMouseUp, at: point)

        var switched = false
        for _ in 0..<25 {
            try? await Task.sleep(for: .milliseconds(100))
            if SpaceReader.currentSpaceId(forDisplay: space.displayId) == space.spaceId {
                switched = true
                break
            }
        }
        if let restorePoint { CGWarpMouseCursorPosition(restorePoint) }
        if !switched {
            // The click was ignored — Mission Control may still be up.
            await close()
        }
        log.debug("switchTo space \(space.spaceId): \(switched)")
        return switched
    }

    /// Open Mission Control and locate `space`'s thumbnail button. On any
    /// failure, Mission Control is dismissed and nil returned.
    private static func openAndFindThumbnail(for space: SpaceInfo) async -> AXUIElement? {
        // Locate the space in the per-display layout before opening
        // Mission Control; the thumbnail order matches this order.
        let layout = SpaceReader.displaySpaceIds()
        guard let displayOrdinal = layout.firstIndex(where: { $0.displayId == space.displayId }),
              let spaceOrdinal = layout[displayOrdinal].spaceIds.firstIndex(of: space.spaceId)
        else {
            log.debug("abort: space \(space.spaceId) not found in display layout")
            return nil
        }

        guard let dock = NSWorkspace.shared.runningApplications.first(
            where: { $0.bundleIdentifier == "com.apple.dock" }
        ) else {
            log.debug("abort: no Dock process")
            return nil
        }
        let dockAX = AXUIElementCreateApplication(dock.processIdentifier)

        // Any real click or key press dismisses Mission Control while we
        // work — wait briefly for an input-quiet moment.
        if let anyInput = CGEventType(rawValue: ~UInt32(0)) {
            for _ in 0..<16 {
                if CGEventSource.secondsSinceLastEventType(
                    .combinedSessionState, eventType: anyInput
                ) > 0.75 { break }
                try? await Task.sleep(for: .milliseconds(250))
            }
        }

        guard SpaceSwitcher.postSymbolicHotKey(missionControlHotKey) else {
            log.debug("abort: could not post Mission Control hotkey")
            return nil
        }

        // Wait for the spaces bar to materialize in the Dock's AX tree.
        for _ in 0..<30 {
            try? await Task.sleep(for: .milliseconds(100))
            let displays = missionControlDisplays(dockAX)
            guard displays.count > displayOrdinal else { continue }
            let buttons = spaceButtons(in: displays[displayOrdinal])
            guard !buttons.isEmpty else { continue }
            // The bar must mirror the SkyLight layout exactly, or the
            // ordinal-based match could hit the wrong thumbnail.
            guard buttons.count == layout[displayOrdinal].spaceIds.count else {
                log.debug("abort: thumbnail count \(buttons.count) != space count \(layout[displayOrdinal].spaceIds.count)")
                await close()
                return nil
            }
            return buttons[spaceOrdinal]
        }
        log.debug("abort: Mission Control spaces bar never appeared")
        await close()
        return nil
    }

    private static func frame(of element: AXUIElement) -> CGRect {
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
        else { return .zero }
        return CGRect(origin: position, size: size)
    }

    /// Dismiss Mission Control with Escape.
    package static func close() async {
        try? await Task.sleep(for: .milliseconds(200))
        let source = CGEventSource(stateID: .hidSystemState)
        CGEvent(keyboardEventSource: source, virtualKey: escapeKey, keyDown: true)?.post(tap: .cghidEventTap)
        CGEvent(keyboardEventSource: source, virtualKey: escapeKey, keyDown: false)?.post(tap: .cghidEventTap)
    }

    // MARK: - Dock AX navigation

    /// The mc.display groups, in the same display order as
    /// SLSCopyManagedDisplaySpaces. Depending on macOS build they sit at the
    /// Dock's top level or under a wrapper group with identifier "mc".
    private static func missionControlDisplays(_ dockAX: AXUIElement) -> [AXUIElement] {
        var result: [AXUIElement] = []
        for child in children(of: dockAX) {
            switch identifier(of: child) {
            case "mc.display":
                result.append(child)
            case "mc":
                result.append(contentsOf: children(of: child).filter { identifier(of: $0) == "mc.display" })
            default:
                continue
            }
        }
        return result
    }

    private static func spaceButtons(in display: AXUIElement) -> [AXUIElement] {
        for group in children(of: display) where identifier(of: group) == "mc.spaces" {
            for list in children(of: group) where identifier(of: list) == "mc.spaces.list" {
                return children(of: list)
            }
        }
        return []
    }

    private static func children(of element: AXUIElement) -> [AXUIElement] {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &ref) == .success,
              let array = ref as? [AXUIElement]
        else { return [] }
        return array
    }

    private static func identifier(of element: AXUIElement) -> String {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, "AXIdentifier" as CFString, &ref) == .success else {
            return ""
        }
        return ref as? String ?? ""
    }
}
