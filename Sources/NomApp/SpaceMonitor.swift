import AppKit
import Observation
import NomCore

@Observable
@MainActor
final class SpaceMonitor {
    private(set) var currentSpace: SpaceInfo?
    private(set) var allSpaces: [SpaceInfo] = []
    private let store = ConfigStore()
    private let hud = HUDController()
    private var config = NomConfig()
    private var configWatcher: FileWatcher?

    func start() {
        Task {
            config = await store.loadConfig()
            refreshSync()
        }

        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.onSpaceSwitch()
            }
        }

        DistributedNotificationCenter.default().addObserver(
            forName: .init("com.teambrilliant.nom.configChanged"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.reloadConfig()
            }
        }

        configWatcher = FileWatcher(path: ConfigStore.configPath.path) { [weak self] in
            Task { @MainActor in
                self?.reloadConfig()
            }
        }
        configWatcher?.start()
    }

    func onSpaceSwitch() {
        refreshSync()
        if let space = currentSpace {
            hud.show(space: space)
        }
    }

    func setName(_ name: String?, forSpaceId id: String) {
        if let name {
            config.spaces[id] = NomConfig.SpaceEntry(name: name)
        } else {
            config.spaces.removeValue(forKey: id)
        }

        Task { try? await store.saveConfig(config) }

        allSpaces = allSpaces.map { space in
            var s = space
            if s.id == id { s.name = name }
            return s
        }

        if currentSpace?.id == id {
            currentSpace = allSpaces.first(where: { $0.id == id })
        }
    }

    /// Synchronous refresh — reads SkyLight + applies names from cached config.
    /// No actor hop needed, so currentSpace is set before returning.
    private func refreshSync() {
        let rawSpaces = SpaceReader.allSpaces()
        let activeId = SpaceReader.activeSpaceId()

        allSpaces = rawSpaces.map { space in
            var s = space
            s.name = config.spaces[space.id]?.name
            return s
        }
        currentSpace = allSpaces.first(where: { $0.spaceId == activeId })

        // Write state file async (non-blocking)
        Task {
            let state = NomState(
                currentSpaceId: currentSpace?.id ?? "",
                spaces: allSpaces
            )
            try? await store.writeState(state)
        }
    }

    private func reloadConfig() {
        Task {
            config = await store.loadConfig()
            refreshSync()
        }
    }
}
