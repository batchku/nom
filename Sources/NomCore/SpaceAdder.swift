import Foundation
import os

/// Creates a desktop the way a user would from Mission Control's spaces
/// bar: press the bar's "+" button (via MissionControlBar). The write-side
/// SLSSpaceCreate route needs a SIP-disabled scripting addition — off-limits
/// per CLAUDE.md.
///
/// The new desktop is appended at the end of the display's desktops (before
/// any fullscreen spaces), exactly as when clicking "+" by hand.
///
/// Requires the Accessibility permission.
public enum SpaceAdder {
    private static let log = Logger(subsystem: "com.teambrilliant.nom", category: "SpaceAdder")

    /// Add a desktop on the given display. Returns the new space's runtime
    /// id once it has appeared in the display layout, or nil on failure.
    public static func add(onDisplay displayId: String) async -> Int? {
        let created = await MissionControlBar.addDesktop(onDisplay: displayId)
        log.debug("desktop added on \(displayId): \(created.map(String.init) ?? "failed")")
        return created
    }
}
