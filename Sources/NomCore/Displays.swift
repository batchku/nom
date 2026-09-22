import AppKit

public enum Displays {
    /// The CoreGraphics display whose ColorSync UUID matches a SkyLight
    /// "Display Identifier" (the `displayId` carried by SpaceInfo).
    public static func directDisplayID(forDisplayId displayId: String) -> CGDirectDisplayID? {
        var count: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &count)
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetActiveDisplayList(count, &ids, &count)

        for id in ids {
            guard let uuid = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue() else { continue }
            if (CFUUIDCreateString(nil, uuid) as String).caseInsensitiveCompare(displayId) == .orderedSame {
                return id
            }
        }
        return nil
    }
}
