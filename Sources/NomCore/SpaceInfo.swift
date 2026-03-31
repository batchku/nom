import Foundation

public struct SpaceInfo: Sendable, Identifiable, Codable {
    /// Stable identifier: id64 from macOS (persists across reboot, unaffected by SLSSpaceSetName)
    public var id: String
    /// The macOS-internal 64-bit space ID (same as id64)
    public let spaceId: Int
    /// 1-based global index across all displays (matches Mission Control / Ctrl+N)
    public let index: Int
    public let displayId: String
    public let type: Int32
    public var name: String?

    public var displayName: String {
        name ?? "Desktop \(index)"
    }

    public init(spaceId: Int, index: Int, displayId: String, type: Int32, name: String?) {
        self.id = "\(spaceId)"
        self.spaceId = spaceId
        self.index = index
        self.displayId = displayId
        self.type = type
        self.name = name
    }
}
