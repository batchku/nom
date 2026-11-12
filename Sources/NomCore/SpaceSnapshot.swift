/// One read of workspace order, visible desktops, and display focus.
public struct SpaceSnapshot: Sendable {
    public let spaces: [SpaceInfo]
    public let activeSpaceId: Int
    public let currentSpaceIds: [String: Int]

    public enum Change: Sendable, Equatable {
        case none
        case focus
        case layout
        case space
    }

    public init(spaces: [SpaceInfo], activeSpaceId: Int, currentSpaceIds: [String: Int]) {
        self.spaces = spaces
        self.activeSpaceId = activeSpaceId
        self.currentSpaceIds = currentSpaceIds
    }

    /// Only a changed visible desktop is a space switch. Reordering and
    /// display focus changes refresh the list without triggering the HUD.
    public func change(since previous: SpaceSnapshot) -> Change {
        if currentSpaceIds != previous.currentSpaceIds { return .space }
        let sameLayout = spaces.elementsEqual(previous.spaces) { current, previous in
            current.spaceId == previous.spaceId
                && current.uuid == previous.uuid
                && current.index == previous.index
                && current.displayId == previous.displayId
                && current.type == previous.type
                && current.appName == previous.appName
        }
        if !sameLayout { return .layout }
        if activeSpaceId != previous.activeSpaceId { return .focus }
        return .none
    }

    /// Names follow workspace identity when Mission Control changes order.
    public func namedSpaces(using names: [String: String]) -> [SpaceInfo] {
        spaces.map { space in
            var named = space
            named.name = names[space.persistentKey]
            return named
        }
    }

    public func space(withID id: Int) -> SpaceInfo? {
        spaces.first { $0.spaceId == id }
    }
}
