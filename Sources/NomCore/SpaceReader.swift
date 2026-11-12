import AppKit

public enum SpaceReader {
    private static let cid = SLSMainConnectionID()

    /// Membership of one captured window, including spaces on other displays.
    /// A nil result is a failed read, not evidence that the window moved.
    package static func spaceIds(containingWindow windowID: CGWindowID) -> [Int]? {
        SLSCopySpacesForWindows(cid, 7, [NSNumber(value: windowID)] as CFArray) as? [Int]
    }

    /// Read order, identity, and each display's current desktop from the same
    /// WindowServer result so a reorder can be detected without a space switch.
    public static func snapshot() -> SpaceSnapshot {
        let displays = managedDisplays()
        return SpaceSnapshot(
            spaces: spaces(in: displays, includeFullscreen: true),
            activeSpaceId: activeSpaceId(),
            currentSpaceIds: currentSpaceIds(in: displays)
        )
    }

    private static func managedDisplays() -> [[String: Any]] {
        SLSCopyManagedDisplaySpaces(cid) as? [[String: Any]] ?? []
    }

    public static func activeSpaceId() -> Int {
        SLSGetActiveSpace(cid)
    }

    /// The current space of one display. SLSGetActiveSpace only reports the
    /// focused display, so per-display switches (e.g. moving a window to a
    /// space on another screen) must be observed here.
    public static func currentSpaceId(forDisplay displayId: String) -> Int? {
        currentSpaceIds()[displayId]
    }

    /// Current space id of every display, keyed by display identifier.
    /// A change in this map is the only reliable "a space switched" signal:
    /// SLSGetActiveSpace also changes when focus merely moves between
    /// displays (clicking a window on another screen), which is not a switch.
    public static func currentSpaceIds() -> [String: Int] {
        currentSpaceIds(in: managedDisplays())
    }

    private static func currentSpaceIds(in displays: [[String: Any]]) -> [String: Int] {
        var result: [String: Int] = [:]
        for displayDict in displays {
            guard let displayId = displayDict["Display Identifier"] as? String,
                  let spaceId = (displayDict["Current Space"] as? [String: Any])?["id64"] as? Int
            else { continue }
            result[displayId] = spaceId
        }
        return result
    }

    /// Ordered per-display space ids (including fullscreen), matching the
    /// left-to-right order of Mission Control's spaces-bar thumbnails.
    public static func displaySpaceIds() -> [(displayId: String, spaceIds: [Int])] {
        managedDisplays().map { displayDict in
            let displayId = displayDict["Display Identifier"] as? String ?? "Unknown"
            let ids = (displayDict["Spaces"] as? [[String: Any]])?.compactMap {
                $0["id64"] as? Int ?? $0["ManagedSpaceID"] as? Int
            } ?? []
            return (displayId, ids)
        }
    }

    /// All user-visible spaces with global Mission Control numbering.
    /// Primary display first, then secondary — matches Ctrl+N shortcuts.
    /// Fullscreen spaces (included on request) get index 0 — they have no
    /// Mission Control number.
    public static func allSpaces(includeFullscreen: Bool = false) -> [SpaceInfo] {
        spaces(in: managedDisplays(), includeFullscreen: includeFullscreen)
    }

    private static func spaces(in displays: [[String: Any]], includeFullscreen: Bool) -> [SpaceInfo] {
        var result: [SpaceInfo] = []
        var globalIndex = 1

        for displayDict in displays {
            let displayId = displayDict["Display Identifier"] as? String ?? "Unknown"

            guard let spaces = displayDict["Spaces"] as? [[String: Any]] else {
                continue
            }

            for spaceDict in spaces {
                let spaceId = spaceDict["id64"] as? Int
                    ?? spaceDict["ManagedSpaceID"] as? Int
                    ?? 0
                let type = spaceDict["type"] as? Int32
                    ?? SLSSpaceGetType(cid, spaceId)
                let uuid = spaceDict["uuid"] as? String ?? ""

                if type == 0 {
                    result.append(SpaceInfo(
                        spaceId: spaceId,
                        uuid: uuid,
                        index: globalIndex,
                        displayId: displayId,
                        type: type,
                        name: nil
                    ))
                    globalIndex += 1
                } else if includeFullscreen {
                    // Fullscreen space dicts carry the owning app's pid —
                    // resolve it so the space can be labeled by app.
                    var appName: String?
                    if let pid = spaceDict["pid"] as? Int32 {
                        appName = NSRunningApplication(processIdentifier: pid)?.localizedName
                    }
                    result.append(SpaceInfo(
                        spaceId: spaceId,
                        uuid: uuid,
                        index: 0,
                        displayId: displayId,
                        type: type,
                        name: nil,
                        appName: appName
                    ))
                }
            }
        }

        return result
    }
}
