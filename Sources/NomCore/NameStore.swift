import Foundation

/// Space names stored in the com.teambrilliant.nom preferences domain
/// (~/Library/Preferences/com.teambrilliant.nom.plist), keyed by
/// SpaceInfo.persistentKey. Inspect with: defaults read com.teambrilliant.nom
///
/// CFPreferences (not UserDefaults) so the app and the bundle-less CLI hit
/// the same domain symmetrically through cfprefsd.
public struct NameStore: Sendable {
    private static let domain = "com.teambrilliant.nom"
    private static let namesKey = "spaceNames"
    private static let migratedKey = "migratedFromConfigJSON"

    private var domain: CFString { Self.domain as CFString }
    private var namesKey: CFString { Self.namesKey as CFString }
    private var migratedKey: CFString { Self.migratedKey as CFString }

    public init() {}

    /// All names, [persistentKey: name].
    public func allNames() -> [String: String] {
        CFPreferencesAppSynchronize(domain)
        return CFPreferencesCopyAppValue(namesKey, domain) as? [String: String] ?? [:]
    }

    /// nil name removes the key.
    public func setName(_ name: String?, for key: String) {
        var names = allNames()
        names[key] = name
        write(names)
    }

    /// One-time import of ~/.nom/config.json (legacy id64-keyed names).
    /// Exact pass: entries whose id64 matches a live space. Rescue pass:
    /// remaining entries assigned by creation order onto still-unnamed
    /// desktops in Mission Control order — a best-effort guess after a
    /// reboot invalidated every id64. config.json itself is never modified.
    public func migrateLegacyConfigIfNeeded(liveSpaces: [SpaceInfo]) {
        CFPreferencesAppSynchronize(domain)
        if (CFPreferencesCopyAppValue(migratedKey, domain) as? Bool) == true {
            return
        }

        defer {
            CFPreferencesSetAppValue(migratedKey, true as CFBoolean, domain)
            CFPreferencesAppSynchronize(domain)
        }

        guard let data = try? Data(contentsOf: ConfigStore.configPath),
              let config = try? JSONDecoder().decode(NomConfig.self, from: data),
              !config.spaces.isEmpty else {
            return
        }

        var names = allNames()
        var legacy = config.spaces

        for space in liveSpaces {
            guard let entry = legacy.removeValue(forKey: "\(space.spaceId)") else { continue }
            if names[space.persistentKey] == nil {
                names[space.persistentKey] = entry.name
            }
        }

        let orphans = legacy
            .compactMap { key, entry in Int(key).map { (id64: $0, name: entry.name) } }
            .sorted { $0.id64 < $1.id64 }
        let unnamed = liveSpaces
            .filter { !$0.isFullscreen && names[$0.persistentKey] == nil }
            .sorted { $0.index < $1.index }
        for (orphan, space) in zip(orphans, unnamed) {
            names[space.persistentKey] = orphan.name
            FileHandle.standardError.write(
                Data("nom: recovered name \"\(orphan.name)\" -> Desktop \(space.index) (best-effort; fix with `nom set`)\n".utf8)
            )
        }

        write(names)
    }

    private func write(_ names: [String: String]) {
        CFPreferencesSetAppValue(namesKey, names as CFDictionary, domain)
        // Flush through cfprefsd immediately — the CLI exits right after.
        CFPreferencesAppSynchronize(domain)
    }
}
