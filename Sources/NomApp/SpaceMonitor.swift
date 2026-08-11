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
    private let nameStore = NameStore()
    private var names: [String: String] = [:]
    private var lastActiveId: Int = 0
    private var pollTask: Task<Void, Never>?
    private let swipeDetector = SwipeDetector()
    private var transitionTicks = 0
    /// PID of the most recently active app other than nom — the menu panel
    /// makes nom the frontmost app, so "the frontmost window" the user means
    /// belongs to whichever app was active before the panel opened.
    private var lastFrontmostPid: pid_t?

    /// SLSGetActiveSpace only commits at the END of the switch animation, so
    /// polling it can't beat the swipe — the gesture tap supplies the "swipe
    /// began" signal, and this poll commits the result.
    private static let pollInterval: Duration = .milliseconds(50)
    /// Ticks without gesture activity or a space change before a transition
    /// is abandoned (swipe bounced back / wasn't a space switch): ~1.5s.
    private static let transitionTimeoutTicks = 30

    func start() {
        lastActiveId = SpaceReader.activeSpaceId()

        swipeDetector.onSwipeBegan = { [weak self] in
            self?.onSwipeBegan()
        }
        swipeDetector.onSwipeActivity = { [weak self] in
            self?.transitionTicks = 0
        }
        swipeDetector.start()

        nameStore.migrateLegacyConfigIfNeeded(
            liveSpaces: SpaceReader.allSpaces(includeFullscreen: true)
        )
        names = nameStore.allNames()
        refreshSync()

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

        let ownPid = ProcessInfo.processInfo.processIdentifier
        if let front = NSWorkspace.shared.frontmostApplication,
           front.processIdentifier != ownPid {
            lastFrontmostPid = front.processIdentifier
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            guard let pid = app?.processIdentifier, pid != ownPid else { return }
            MainActor.assumeIsolated {
                self?.lastFrontmostPid = pid
            }
        }

        DistributedNotificationCenter.default().addObserver(
            forName: .init("com.teambrilliant.nom.configChanged"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.reloadNames()
            }
        }
    }

    private func onSwipeBegan() {
        guard !isTransitioning else { return }
        // The destination isn't knowable until the switch commits — show a
        // placeholder immediately so the old name doesn't linger mid-swipe.
        isTransitioning = true
        transitionTicks = 0
        hud.showTransition()
    }

    private func pollTick() {
        let activeId = SpaceReader.activeSpaceId()

        if isTransitioning {
            transitionTicks += 1
            if activeId != lastActiveId {
                // Switch committed — swap the placeholder for the real name.
                isTransitioning = false
                onSpaceSwitch()
            } else if transitionTicks >= Self.transitionTimeoutTicks {
                // Swipe ended without a space change (bounce-back, or the
                // gesture wasn't a space switch) — restore the current name.
                isTransitioning = false
                refreshSync()
                if let space = currentSpace, !space.isFullscreen {
                    hud.show(space: space)
                }
            }
        } else if activeId != lastActiveId {
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

    /// Move the frontmost window (of the app active before the menu opened)
    /// to a space, following it there. Prompts for Accessibility permission
    /// on first use, same as jump.
    func moveFrontmostWindow(to space: SpaceInfo) {
        guard space.id != currentSpace?.id else { return }
        guard space.index >= 1, space.index <= SpaceSwitcher.maxJumpIndex else { return }
        guard SpaceSwitcher.hasAccessibilityPermission else {
            SpaceSwitcher.requestAccessibilityPermission()
            return
        }
        guard let pid = lastFrontmostPid else { return }

        let index = space.index
        let targetSpaceId = space.spaceId
        let targetDisplayId = space.displayId
        Task {
            // Let the menu panel finish closing — the move synthesizes real
            // mouse events on the target window's title bar.
            try? await Task.sleep(for: .milliseconds(250))
            await WindowMover.moveFocusedWindow(
                ofPid: pid,
                toSpaceIndex: index,
                targetSpaceId: targetSpaceId,
                targetDisplayId: targetDisplayId
            )
        }
    }

    /// Whether the delete affordance should be offered for a space at all
    /// (macOS refuses to remove the last desktop on a display).
    func canDelete(_ space: SpaceInfo) -> Bool {
        SpaceDeleter.canDelete(space, among: allSpaces)
    }

    /// Delete a space via Mission Control's AXRemoveDesktop action. Windows
    /// on it migrate to a neighboring desktop; its saved name is cleaned up.
    /// Prompts for Accessibility permission on first use, same as jump.
    func deleteSpace(_ space: SpaceInfo) {
        guard canDelete(space) else { return }
        guard SpaceSwitcher.hasAccessibilityPermission else {
            SpaceSwitcher.requestAccessibilityPermission()
            return
        }

        Task {
            // Let the menu panel finish closing — Mission Control dismisses
            // if input arrives while it opens.
            try? await Task.sleep(for: .milliseconds(250))
            if await SpaceDeleter.delete(space: space) {
                nameStore.setName(nil, for: space.persistentKey)
                names.removeValue(forKey: space.persistentKey)
                onSpaceSwitch()
            }
        }
    }

    func setName(_ name: String?, for space: SpaceInfo) {
        nameStore.setName(name, for: space.persistentKey)
        names[space.persistentKey] = name

        allSpaces = allSpaces.map { s in
            var s = s
            if s.id == space.id { s.name = name }
            return s
        }

        if currentSpace?.id == space.id {
            currentSpace = allSpaces.first(where: { $0.id == space.id })
        }
    }

    /// Synchronous refresh — reads SkyLight + applies names from the cached
    /// names dict. No actor hop needed, so currentSpace is set before returning.
    private func refreshSync() {
        let rawSpaces = SpaceReader.allSpaces(includeFullscreen: true)
        let activeId = SpaceReader.activeSpaceId()
        lastActiveId = activeId

        let named = rawSpaces.map { space in
            var s = space
            s.name = names[space.persistentKey]
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

    private func reloadNames() {
        names = nameStore.allNames()
        refreshSync()
    }
}
