import Foundation

public enum SpaceReader {
    private static let cid = SLSMainConnectionID()

    public static func activeSpaceId() -> Int {
        SLSGetActiveSpace(cid)
    }

    /// The current space of one display. SLSGetActiveSpace only reports the
    /// focused display, so per-display switches (e.g. moving a window to a
    /// space on another screen) must be observed here.
    public static func currentSpaceId(forDisplay displayId: String) -> Int? {
        guard let displaysArray = SLSCopyManagedDisplaySpaces(cid) as? [[String: Any]] else {
            return nil
        }
        for displayDict in displaysArray
        where displayDict["Display Identifier"] as? String == displayId {
            return (displayDict["Current Space"] as? [String: Any])?["id64"] as? Int
        }
        return nil
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
                    result.append(SpaceInfo(
                        spaceId: spaceId,
                        uuid: uuid,
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
