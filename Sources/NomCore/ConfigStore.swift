import Foundation

public actor ConfigStore {
    public static let configDir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".nom")
    public static let configPath = configDir.appendingPathComponent("config.json")
    public static let statePath = configDir.appendingPathComponent("state.json")

    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()
    private let decoder = JSONDecoder()

    public init() {}

    public func loadConfig() -> NomConfig {
        guard let data = try? Data(contentsOf: Self.configPath) else {
            return NomConfig()
        }
        return (try? decoder.decode(NomConfig.self, from: data)) ?? NomConfig()
    }

    public func saveConfig(_ config: NomConfig) throws {
        try ensureDir()
        let data = try encoder.encode(config)
        try data.write(to: Self.configPath, options: .atomic)
    }

    public func writeState(_ state: NomState) throws {
        try ensureDir()
        let data = try encoder.encode(state)
        try data.write(to: Self.statePath, options: .atomic)
    }

    public func readState() -> NomState? {
        guard let data = try? Data(contentsOf: Self.statePath) else { return nil }
        return try? decoder.decode(NomState.self, from: data)
    }

    public func applyNames(to spaces: [SpaceInfo], using config: NomConfig) -> [SpaceInfo] {
        spaces.map { space in
            var s = space
            s.name = config.spaces[space.id]?.name
            return s
        }
    }

    private func ensureDir() throws {
        try FileManager.default.createDirectory(at: Self.configDir, withIntermediateDirectories: true)
    }
}
