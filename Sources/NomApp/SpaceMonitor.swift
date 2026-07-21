import AppKit
import Observation
import NomCore

@Observable
@MainActor
final class SpaceMonitor {
    private(set) var currentSpace: SpaceInfo?
    private(set) var allSpaces: [SpaceInfo] = []
    /// True while a space swipe/switch animation is in flight.
    private(set) var isTransitioning = false

    var menuBarTitle: String {
        if isTransitioning { return "…" }
        return currentSpace?.displayName ?? "nom"
    }
    private let store = ConfigStore()
    private let hud = HUDController()
    private var config = NomConfig()
    private var configWatcher: FileWatcher?
    private var lastActiveId: Int = 0
    private var displayIds: [String] = []
    private var pollTask: Task<Void, Never>?

    /// SLSGetActiveSpace only commits at the END of the switch animation, so
    /// polling it can't beat the swipe. SLSManagedDisplayIsAnimating flips true
    /// while the transition is in flight — that's the "swipe began" signal.
    /// Both calls are cheap connection reads, so 50ms polling is negligible.
    private static let pollInterval: Duration = .milliseconds(50)

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
                self.pollTick()
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
                guard let self, !self.isTransitioning else { return }
                self.onSpaceSwitch()
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

    private func pollTick() {
        let animating = displayIds.contains(where: SpaceReader.isDisplayAnimating)

        if animating {
            if !isTransitioning {
                // Swipe just began — show placeholder immediately; the real
                // destination isn't knowable until the transition commits.
                isTransitioning = true
                hud.showTransition()
            }
            return
        }

        if isTransitioning {
            // Transition just ended — commit the real name everywhere.
            isTransitioning = false
            refreshSync()
            if let space = currentSpace, !space.isFullscreen {
                hud.show(space: space)
            }
        } else if SpaceReader.activeSpaceId() != lastActiveId {
            onSpaceSwitch()
        }
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

        var seenDisplays: [String] = []
        for space in named where !seenDisplays.contains(space.displayId) {
            seenDisplays.append(space.displayId)
        }
        displayIds = seenDisplays

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
