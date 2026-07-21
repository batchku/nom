import Foundation

public enum SpaceReader {
    private static let cid = SLSMainConnectionID()

    public static func activeSpaceId() -> Int {
        SLSGetActiveSpace(cid)
    }

    /// True while the display is mid space-transition (swipe or animated switch).
    /// SLSGetActiveSpace only reflects the new space once the transition
    /// commits, so this is the earliest available "switch in progress" signal.
    public static func isDisplayAnimating(_ displayId: String) -> Bool {
        SLSManagedDisplayIsAnimating(cid, displayId as CFString)
    }

    /// All user-visible spaces with global Mission Control numbering.
    /// Primary display first, then secondary — matches Ctrl+N shortcuts.
    /// Fullscreen spaces (included on request) get index 0 — they have no
    /// Mission Control number.
    public static func allSpaces(includeFullscreen: Bool = false) -> [SpaceInfo] {
        guard let displaysArray = SLSCopyManagedDisplaySpaces(cid) as? [[String: Any]] else {
            return []
        }

        var result: [SpaceInfo] = []
        var globalIndex = 1

        for displayDict in displaysArray {
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

                if type == 0 {
                    result.append(SpaceInfo(
                        spaceId: spaceId,
                        index: globalIndex,
                        displayId: displayId,
                        type: type,
                        name: nil
                    ))
                    globalIndex += 1
                } else if includeFullscreen {
                    result.append(SpaceInfo(
                        spaceId: spaceId,
                        index: 0,
                        displayId: displayId,
                        type: type,
                        name: nil
                    ))
                }
            }
        }

        return result
    }
}
