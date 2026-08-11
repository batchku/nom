import Foundation
import os

/// Deletes a space the way a user would from Mission Control's spaces bar:
/// perform the thumbnail's AXRemoveDesktop action (via MissionControlBar) —
/// the same route Hammerspoon's hs.spaces takes. SLSSpaceDestroy would need
/// a SIP-disabled scripting addition (yabai-style) — off-limits per CLAUDE.md.
///
/// Windows on the deleted space migrate to a neighboring desktop (standard
/// macOS behavior), and macOS itself refuses to remove the last desktop on
/// a display.
///
/// Requires the Accessibility permission.
public enum SpaceDeleter {
    private static let log = Logger(subsystem: "com.teambrilliant.nom", category: "SpaceDeleter")

    /// True when the space can be deleted at all: a regular desktop that is
    /// not the only desktop on its display.
    public static func canDelete(_ space: SpaceInfo, among all: [SpaceInfo]) -> Bool {
        !space.isFullscreen
            && all.filter { $0.displayId == space.displayId && !$0.isFullscreen }.count > 1
    }

    /// Delete the given space. Returns true only once the space has actually
    /// vanished from the display layout.
    @discardableResult
    public static func delete(space: SpaceInfo) async -> Bool {
        guard await MissionControlBar.perform("AXRemoveDesktop", on: space, closeAfter: false) else {
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
        await MissionControlBar.close()
        log.debug("space \(space.spaceId) deleted: \(gone)")
        return gone
    }
}
