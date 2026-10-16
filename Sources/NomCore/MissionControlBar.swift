import AppKit
import ApplicationServices
import os

/// Drives Mission Control's spaces bar through its accessibility tree:
/// open Mission Control, find a space's thumbnail button, perform an AX
/// action on it. "AXPress" exits to that space (the only way to reach a
/// fullscreen space — they have no Ctrl+N hotkey — and the fallback when a
/// Ctrl+N hotkey is dead, see SpaceSwitcher.switchTo); "AXRemoveDesktop"
/// deletes it (see SpaceDeleter). The bar's "+" button (mc.spaces.add)
/// creates a desktop (see SpaceAdder).
///
/// The tree is hosted by the Dock process up to macOS 26 and by the
/// WindowManager process from macOS 27 (the Dock keeps an empty `mc`
/// group). Identifiers are the same in both; `hosts()` scans both.
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

    /// Switch to a space from its Mission Control thumbnail and verify the
    /// display's current space changed before reporting success.
    ///
    /// On macOS 27 (WindowManager-hosted bar) an AXPress exits to the space
    /// and dismisses Mission Control itself, ~100 ms, no cursor movement —
    /// which also keeps a window held by WindowMover attached. On the
    /// Dock-hosted bar AXPress only dismisses Mission Control, and a
    /// teleported click is ignored too: the bar only honors a click after
    /// the cursor has actually hovered it, so the fallback reopens, moves
    /// the cursor there, dwells, then clicks.
    @discardableResult
    public static func switchTo(_ space: SpaceInfo) async -> Bool {
        guard SpaceReader.currentSpaceId(forDisplay: space.displayId) != space.spaceId else {
            return true
        }
        guard let pressed = await openAndFindThumbnail(for: space) else { return false }

        if AXUIElementPerformAction(pressed, kAXPressAction as CFString) == .success,
           await SpaceSwitcher.waitForSwitch(to: space, timeout: .milliseconds(800)) {
            await close()
            log.debug("switchTo space \(space.spaceId) via AXPress")
            return true
        }

        var button = pressed
        if !isOpen() {
            guard let reopened = await openAndFindThumbnail(for: space) else { return false }
            button = reopened
        }
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
        log.debug("switchTo space \(space.spaceId) via hover+click: \(switched)")
        return switched
    }

    /// Press the "+" button of `displayId`'s spaces bar and return the id
    /// of the desktop that appeared. Mission Control stays open after the
    /// press (as it does for a user), so it is dismissed here either way.
    package static func addDesktop(onDisplay displayId: String) async -> Int? {
        guard let layout = SpaceReader.displaySpaceIds().first(where: { $0.displayId == displayId }) else {
            log.debug("abort: display \(displayId) not found in display layout")
            return nil
        }
        let before = Set(layout.spaceIds)

        guard let display = await openSpacesBar(
            forDisplay: displayId, expectedSpaceCount: before.count
        ) else { return nil }
        guard let button = addButton(in: display) else {
            log.debug("abort: no mc.spaces.add button on display \(displayId)")
            await close()
            return nil
        }
        guard AXUIElementPerformAction(button, kAXPressAction as CFString) == .success else {
            log.debug("abort: AXPress failed on mc.spaces.add")
            await close()
            return nil
        }

        var created: Int?
        for _ in 0..<20 {
            try? await Task.sleep(for: .milliseconds(100))
            let now = SpaceReader.displaySpaceIds()
                .first { $0.displayId == displayId }?.spaceIds ?? []
            if let fresh = now.first(where: { !before.contains($0) }) {
                created = fresh
                break
            }
        }
        await close()
        log.debug("addDesktop on \(displayId): \(created.map(String.init) ?? "none")")
        return created
    }

    /// Open Mission Control (if it isn't already up) and locate `space`'s
    /// thumbnail button. On any failure, Mission Control is dismissed and
    /// nil returned.
    private static func openAndFindThumbnail(for space: SpaceInfo) async -> AXUIElement? {
        // Locate the space in its display's layout before opening Mission
        // Control; the thumbnail order within a bar matches this order.
        guard let layout = SpaceReader.displaySpaceIds().first(where: { $0.displayId == space.displayId }),
              let spaceOrdinal = layout.spaceIds.firstIndex(of: space.spaceId)
        else {
            log.debug("abort: space \(space.spaceId) not found in display layout")
            return nil
        }
        guard let display = await openSpacesBar(
            forDisplay: space.displayId, expectedSpaceCount: layout.spaceIds.count
        ) else { return nil }
        return spaceButtons(in: display)[spaceOrdinal]
    }

    /// Open Mission Control and return the mc.display group of `displayId`
    /// once its spaces bar shows exactly `expectedSpaceCount` thumbnails.
    /// On any failure, Mission Control is dismissed and nil returned.
    ///
    /// Groups are matched to displays by geometry (the group's frame lies
    /// on the display): their order is NOT the SLSCopyManagedDisplaySpaces
    /// order on macOS 27. A unique thumbnail count is the fallback when no
    /// frame is exposed.
    private static func openSpacesBar(forDisplay displayId: String, expectedSpaceCount: Int) async -> AXUIElement? {
        guard !hosts().isEmpty else {
            log.debug("abort: no Dock or WindowManager process")
            return nil
        }

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

        // The hotkey toggles: posting it while Mission Control is already
        // up (e.g. after a window was dropped on a thumbnail) would close it.
        if !isOpen() {
            guard SpaceSwitcher.postSymbolicHotKey(missionControlHotKey) else {
                log.debug("abort: could not post Mission Control hotkey")
                return nil
            }
        }

        // Wait for every display's spaces bar to materialize in the AX tree.
        let displayBounds = Displays.directDisplayID(forDisplayId: displayId).map(CGDisplayBounds)
        for _ in 0..<30 {
            try? await Task.sleep(for: .milliseconds(100))
            let displays = missionControlDisplays()
            guard !displays.isEmpty, displays.allSatisfy({ !spaceButtons(in: $0).isEmpty }) else { continue }
            guard let display = spacesBarDisplay(
                among: displays, bounds: displayBounds, expectedSpaceCount: expectedSpaceCount
            ) else {
                log.debug("abort: no spaces bar matches display \(displayId) (\(expectedSpaceCount) spaces)")
                await close()
                return nil
            }
            // The bar must mirror the SkyLight layout exactly, or an
            // ordinal-based match could hit the wrong thumbnail.
            let count = spaceButtons(in: display).count
            guard count == expectedSpaceCount else {
                log.debug("abort: thumbnail count \(count) != space count \(expectedSpaceCount)")
                await close()
                return nil
            }
            return display
        }
        log.debug("abort: Mission Control spaces bar never appeared")
        await close()
        return nil
    }

    /// The mc.display group belonging to the display with `bounds`: the one
    /// whose frame center lies on it, else the only one with
    /// `expectedSpaceCount` thumbnails.
    private static func spacesBarDisplay(
        among displays: [AXUIElement], bounds: CGRect?, expectedSpaceCount: Int
    ) -> AXUIElement? {
        if let bounds {
            let onDisplay = displays.filter {
                let f = frame(of: $0)
                return f.width > 0 && bounds.contains(CGPoint(x: f.midX, y: f.midY))
            }
            if onDisplay.count == 1 { return onDisplay[0] }
        }
        let byCount = displays.filter { spaceButtons(in: $0).count == expectedSpaceCount }
        return byCount.count == 1 ? byCount[0] : nil
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

    /// True while Mission Control's spaces bar is exposed in some host.
    package static func isOpen() -> Bool {
        !missionControlDisplays().isEmpty
    }

    /// Dismiss Mission Control with Escape — only if it is still up. On
    /// macOS 27 a thumbnail AXPress already dismissed it, and a stray
    /// Escape would land in whatever app is frontmost.
    package static func close() async {
        try? await Task.sleep(for: .milliseconds(200))
        guard isOpen() else { return }
        let source = CGEventSource(stateID: .hidSystemState)
        CGEvent(keyboardEventSource: source, virtualKey: escapeKey, keyDown: true)?.post(tap: .cghidEventTap)
        CGEvent(keyboardEventSource: source, virtualKey: escapeKey, keyDown: false)?.post(tap: .cghidEventTap)
    }

    // MARK: - Dock AX navigation

    /// Processes that may host Mission Control's accessibility tree:
    /// WindowManager (macOS 27+) first, then the Dock (earlier releases).
    private static func hosts() -> [AXUIElement] {
        let apps = NSWorkspace.shared.runningApplications
        let ids = ["com.apple.WindowManager", "com.apple.dock"]
        return ids.compactMap { id in
            apps.first { $0.bundleIdentifier == id }
                .map { AXUIElementCreateApplication($0.processIdentifier) }
        }
    }

    /// The mc.display groups of whichever host currently exposes them, in
    /// the same display order as SLSCopyManagedDisplaySpaces.
    private static func missionControlDisplays() -> [AXUIElement] {
        for host in hosts() {
            let displays = missionControlDisplays(in: host)
            if !displays.isEmpty { return displays }
        }
        return []
    }

    /// Depending on macOS build the groups sit at the host's top level or
    /// under a wrapper group with identifier "mc".
    private static func missionControlDisplays(in host: AXUIElement) -> [AXUIElement] {
        var result: [AXUIElement] = []
        for child in children(of: host) {
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

    /// The "+" (add desktop) button of a display's spaces bar.
    private static func addButton(in display: AXUIElement) -> AXUIElement? {
        for group in children(of: display) where identifier(of: group) == "mc.spaces" {
            return children(of: group).first { identifier(of: $0) == "mc.spaces.add" }
        }
        return nil
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
