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

    public func writeState(_ state: NomState) throws {
        try ensureDir()
        let data = try encoder.encode(state)
        try data.write(to: Self.statePath, options: .atomic)
    }

    public func readState() -> NomState? {
        guard let data = try? Data(contentsOf: Self.statePath) else { return nil }
        return try? decoder.decode(NomState.self, from: data)
    }

    private func ensureDir() throws {
        try FileManager.default.createDirectory(at: Self.configDir, withIntermediateDirectories: true)
    }
}
