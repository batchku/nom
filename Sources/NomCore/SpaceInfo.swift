import Foundation

public struct SpaceInfo: Sendable, Identifiable, Codable {
    /// Runtime identifier: id64 from macOS. Per-boot only — use persistentKey
    /// for anything that must survive a reboot.
    public var id: String
    /// The macOS-internal 64-bit space ID (same as id64)
    public let spaceId: Int
    /// Space UUID from SLSCopyManagedDisplaySpaces — persists across reboots.
    /// Empty for the built-in Desktop 1.
    public let uuid: String
    /// 1-based global index across all displays (matches Mission Control / Ctrl+N)
    public let index: Int
    public let displayId: String
    public let type: Int32
    public var name: String?

    public var isFullscreen: Bool { type != 0 }

    /// Reboot-stable identity used to key stored names.
    public var persistentKey: String {
        if !uuid.isEmpty { return uuid }
        // Desktop 1 is the only space macOS leaves without a UUID. Guard
        // against a second empty-uuid space colliding on the same key.
        return spaceId == 1 ? "desktop-1" : "space-\(spaceId)"
    }

    public var displayName: String {
        if isFullscreen { return name ?? "Fullscreen" }
        return name ?? "Desktop \(index)"
    }

    public init(spaceId: Int, uuid: String, index: Int, displayId: String, type: Int32, name: String?) {
        self.id = "\(spaceId)"
        self.spaceId = spaceId
        self.uuid = uuid
        self.index = index
        self.displayId = displayId
        self.type = type
        self.name = name
    }

    enum CodingKeys: String, CodingKey {
        case id, spaceId, uuid, index, displayId, type, name
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        spaceId = try c.decode(Int.self, forKey: .spaceId)
        // Tolerate a pre-uuid state.json so `nom current` keeps working
        // across the upgrade.
        uuid = try c.decodeIfPresent(String.self, forKey: .uuid) ?? ""
        index = try c.decode(Int.self, forKey: .index)
        displayId = try c.decode(String.self, forKey: .displayId)
        type = try c.decode(Int32.self, forKey: .type)
        name = try c.decodeIfPresent(String.self, forKey: .name)
    }
}
