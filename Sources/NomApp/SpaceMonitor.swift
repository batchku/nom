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
    private var lastActiveId: Int = 0
    private var pollTask: Task<Void, Never>?

    /// Poll interval for active-space detection. SLSGetActiveSpace costs ~35ns,
    /// so this is effectively free and reacts as soon as the compositor commits
    /// the switch — long before NSWorkspace.activeSpaceDidChangeNotification,
    /// which only fires after the swipe animation completes.
    private static let pollInterval: Duration = .milliseconds(100)

    func start() {
        lastActiveId = SpaceReader.activeSpaceId()

        Task {
            config = await store.loadConfig()
            refreshSync()
        }

        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.pollInterval)
                guard let self else { return }
                let activeId = SpaceReader.activeSpaceId()
                if activeId != self.lastActiveId {
                    self.onSpaceSwitch()
                }
            }
        }

        // Fallback + catches space list changes (create/remove/reorder) that
        // don't change the active space ID.
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
        let activeId = SpaceReader.activeSpaceId()
        let isNewSpace = activeId != lastActiveId
        refreshSync()
        // Only show the HUD when the space actually changed — the NSWorkspace
        // notification arrives after the poller already handled the switch,
        // and re-showing would extend the HUD's dismiss timer.
        if isNewSpace, let space = currentSpace, !space.isFullscreen {
            hud.show(space: space)
        }
    }

    /// Jump to a space. Prompts for Accessibility permission on first use —
    /// posting the Mission Control keyboard shortcut requires it.
    func jump(to space: SpaceInfo) {
        guard space.index >= 1, space.index <= SpaceSwitcher.maxJumpIndex else { return }
        guard SpaceSwitcher.hasAccessibilityPermission else {
            SpaceSwitcher.requestAccessibilityPermission()
            return
        }
        SpaceSwitcher.jump(toIndex: space.index)
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
        let rawSpaces = SpaceReader.allSpaces(includeFullscreen: true)
        let activeId = SpaceReader.activeSpaceId()
        lastActiveId = activeId

        let named = rawSpaces.map { space in
            var s = space
            s.name = config.spaces[space.id]?.name
            return s
        }
        allSpaces = named.filter { !$0.isFullscreen }
        currentSpace = named.first(where: { $0.spaceId == activeId })

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
