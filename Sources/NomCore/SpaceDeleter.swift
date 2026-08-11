import AppKit
import ApplicationServices
import os

/// Deletes a space the way a user would from Mission Control's spaces bar:
/// open Mission Control, find the space's thumbnail button in the Dock's
/// accessibility tree, and perform its AXRemoveDesktop action — the same
/// route Hammerspoon's hs.spaces takes. SLSSpaceDestroy would need a
/// SIP-disabled scripting addition (yabai-style) — off-limits per CLAUDE.md.
///
/// Windows on the deleted space migrate to a neighboring desktop (standard
/// macOS behavior), and macOS itself refuses to remove the last desktop on
/// a display (its thumbnail simply has no AXRemoveDesktop action).
///
/// Requires the Accessibility permission.
public enum SpaceDeleter {
    private static let log = Logger(subsystem: "com.teambrilliant.nom", category: "SpaceDeleter")
    /// macOS symbolic hotkey ID for Mission Control.
    private static let missionControlHotKey: Int32 = 32
    private static let escapeKey: CGKeyCode = 53

    /// True when the space can be deleted at all: a regular desktop that is
    /// not the only desktop on its display.
    public static func canDelete(_ space: SpaceInfo, among all: [SpaceInfo]) -> Bool {
        !space.isFullscreen
            && all.filter { $0.displayId == space.displayId && !$0.isFullscreen }.count > 1
    }

    /// Delete the given space. Returns false — leaving the world untouched
    /// where possible — if Mission Control's UI can't be reached or the
    /// space's thumbnail refuses the action.
    @discardableResult
    public static func delete(space: SpaceInfo) async -> Bool {
        // Locate the space in the per-display layout before opening
        // Mission Control; the thumbnail order matches this order.
        let layout = SpaceReader.displaySpaceIds()
        guard let displayOrdinal = layout.firstIndex(where: { $0.displayId == space.displayId }),
              let spaceOrdinal = layout[displayOrdinal].spaceIds.firstIndex(of: space.spaceId)
        else {
            log.debug("abort: space \(space.spaceId) not found in display layout")
            return false
        }

        guard let dock = NSWorkspace.shared.runningApplications.first(
            where: { $0.bundleIdentifier == "com.apple.dock" }
        ) else {
            log.debug("abort: no Dock process")
            return false
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
            return false
        }

        // Wait for the spaces bar to materialize in the Dock's AX tree.
        var button: AXUIElement?
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
                await closeMissionControl()
                return false
            }
            button = buttons[spaceOrdinal]
            break
        }
        guard let button else {
            log.debug("abort: Mission Control spaces bar never appeared")
            await closeMissionControl()
            return false
        }

        // Don't pre-check the advertised action names — the Dock registers
        // AXRemoveDesktop lazily and often reports only AXPress right after
        // Mission Control opens, even though performing the action works.
        // The disappeared-from-layout check below is the real verification.
        guard AXUIElementPerformAction(button, "AXRemoveDesktop" as CFString) == .success else {
            log.debug("abort: AXRemoveDesktop failed")
            await closeMissionControl()
            return false
        }

        // Confirm the space is actually gone before reporting success.
        var gone = false
        for _ in 0..<20 {
            try? await Task.sleep(for: .milliseconds(100))
            let stillThere = SpaceReader.displaySpaceIds()
                .contains { $0.spaceIds.contains(space.spaceId) }
            if !stillThere { gone = true; break }
        }
        await closeMissionControl()
        log.debug("space \(space.spaceId) deleted: \(gone)")
        return gone
    }

    private static func closeMissionControl() async {
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
