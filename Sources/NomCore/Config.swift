import Foundation

public struct NomConfig: Codable, Sendable {
    public var version: Int = 1
    public var spaces: [String: SpaceEntry] = [:]

    public struct SpaceEntry: Codable, Sendable {
        public var name: String

        public init(name: String) {
            self.name = name
        }
    }

    public init() {}
}

public struct NomState: Codable, Sendable {
    public var currentSpaceId: String
    public var spaces: [SpaceInfo]

    public init(currentSpaceId: String, spaces: [SpaceInfo]) {
        self.currentSpaceId = currentSpaceId
        self.spaces = spaces
    }
}
