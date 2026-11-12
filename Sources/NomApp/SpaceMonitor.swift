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
    /// Synthetic mouse gestures must finish before another space action starts.
    private(set) var isPerformingSpaceAction = false

    var menuBarTitle: String {
        if isTransitioning { return "…" }
        return currentSpace?.displayName ?? "nom"
    }
    private let store = ConfigStore()
    private let hud = HUDController()
    private let renamePrompt = RenamePromptController()
    private let nameStore = NameStore()
    private var names: [String: String] = [:]
    /// Includes ordered IDs: a Mission Control reorder need not change any
    /// display's current space or the focused display.
    private var lastSnapshot: SpaceSnapshot?
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
        let initialSnapshot = SpaceReader.snapshot()

        swipeDetector.onSwipeBegan = { [weak self] in
            self?.onSwipeBegan()
        }
        swipeDetector.onSwipeActivity = { [weak self] in
            self?.transitionTicks = 0
        }
        swipeDetector.start()

        nameStore.migrateLegacyConfigIfNeeded(
            liveSpaces: initialSnapshot.spaces
        )
        names = nameStore.allNames()
        refreshSync(snapshot: initialSnapshot)

        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.pollInterval)
                guard let self else { return }
                self.refresh()
            }
        }

        // Notifications complement polling, but macOS does not reliably
        // send one when Mission Control only reorders desktops.
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

    /// Used by both polling and menu opening so a fresh observation also
    /// completes an in-flight gesture when its desktop switch has committed.
    func refresh() {
        let snapshot = SpaceReader.snapshot()
        let change = lastSnapshot.map { snapshot.change(since: $0) } ?? .layout

        if isTransitioning {
            transitionTicks += 1
            if change == .space {
                // Switch committed; apply this same observation to the HUD.
                isTransitioning = false
                onSpaceSwitch(snapshot: snapshot)
            } else if transitionTicks >= Self.transitionTimeoutTicks {
                // Swipe ended without a space change (or was Mission Control).
                isTransitioning = false
                refreshSync(snapshot: snapshot)
                if let space = currentSpace, !space.isFullscreen {
                    hud.show(space: space)
                }
            } else if change != .none {
                // Mission Control can reorder desktops during a gesture.
                refreshSync(snapshot: snapshot)
            }
        } else if change == .space {
            onSpaceSwitch(snapshot: snapshot)
        } else if change != .none {
            // Reorder, add/remove, or focus on another display: refresh the
            // menu and runtime state without showing a space-switch HUD.
            refreshSync(snapshot: snapshot)
        }
    }

    func onSpaceSwitch() {
        onSpaceSwitch(snapshot: SpaceReader.snapshot())
    }

    private func onSpaceSwitch(snapshot: SpaceSnapshot) {
        let isNewSpace = lastSnapshot.map { snapshot.currentSpaceIds != $0.currentSpaceIds } ?? false
        refreshSync(snapshot: snapshot)
        // The notification may arrive after polling already applied the switch.
        if isNewSpace, let space = currentSpace, !space.isFullscreen {
            hud.show(space: space)
        }
    }

    /// Jump to a space. Prompts for Accessibility permission on first use —
    /// posting the Mission Control keyboard shortcut requires it.
    func jump(to space: SpaceInfo) {
        guard !isPerformingSpaceAction else { return }
        guard SpaceSwitcher.hasAccessibilityPermission else {
            SpaceSwitcher.requestAccessibilityPermission()
            return
        }
        isPerformingSpaceAction = true
        Task {
            defer { isPerformingSpaceAction = false }
            // The hotkey can go out while the menu panel is still closing;
            // the Mission Control fallback can't — input dismisses it.
            await SpaceSwitcher.switchTo(space, fallbackDelay: .milliseconds(250))
        }
    }

    /// Move the frontmost window (of the app active before the menu opened)
    /// to a space, following it there. Prompts for Accessibility permission
    /// on first use, same as jump.
    func moveFrontmostWindow(to space: SpaceInfo) {
        guard !isPerformingSpaceAction, !space.isFullscreen else { return }
        guard SpaceSwitcher.hasAccessibilityPermission else {
            SpaceSwitcher.requestAccessibilityPermission()
            return
        }
        guard let pid = lastFrontmostPid else { return }
        isPerformingSpaceAction = true

        Task {
            defer { isPerformingSpaceAction = false }
            // Let the menu panel finish closing — the move synthesizes real
            // mouse events on the target window's title bar.
            try? await Task.sleep(for: .milliseconds(250))
            if !(await WindowMover.moveFocusedWindow(ofPid: pid, to: space)) {
                let alert = NSAlert()
                alert.messageText = "Couldn’t move the window"
                alert.informativeText = "nom couldn’t move the front window to \(space.displayName)."
                alert.addButton(withTitle: "OK")
                alert.runModal()
            }
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
        guard !isPerformingSpaceAction else { return }
        guard canDelete(space) else { return }
        guard SpaceSwitcher.hasAccessibilityPermission else {
            SpaceSwitcher.requestAccessibilityPermission()
            return
        }

        isPerformingSpaceAction = true
        Task {
            defer { isPerformingSpaceAction = false }
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

    /// Add a desktop on a display via Mission Control's "+" button, switch
    /// to it, and prompt for its name. Prompts for Accessibility permission
    /// on first use, same as jump.
    func addSpace(onDisplay displayId: String) {
        guard !isPerformingSpaceAction else { return }
        guard SpaceSwitcher.hasAccessibilityPermission else {
            SpaceSwitcher.requestAccessibilityPermission()
            return
        }

        isPerformingSpaceAction = true
        Task {
            defer { isPerformingSpaceAction = false }
            // Let the menu panel finish closing — Mission Control dismisses
            // if input arrives while it opens.
            try? await Task.sleep(for: .milliseconds(250))
            guard let newSpaceId = await SpaceAdder.add(onDisplay: displayId) else { return }
            refreshSync()
            guard let space = allSpaces.first(where: { $0.spaceId == newSpaceId }) else { return }

            // Mission Control's dismiss animation swallows a switch hotkey
            // posted too early.
            try? await Task.sleep(for: .milliseconds(500))
            await SpaceSwitcher.switchTo(space)

            // The switch's own HUD card would sit under the prompt — swap it.
            hud.dismissNow()
            renamePrompt.show(for: space) { [weak self] name in
                guard let self, let name else { return }
                self.setName(name, for: space)
                if let named = self.allSpaces.first(where: { $0.id == space.id }) {
                    self.hud.show(space: named)
                }
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

    /// Apply one observation and the UUID-keyed names synchronously.
    private func refreshSync(snapshot: SpaceSnapshot = SpaceReader.snapshot()) {
        lastSnapshot = snapshot
        let named = snapshot.namedSpaces(using: names)
        allSpaces = named
        currentSpace = named.first(where: { $0.spaceId == snapshot.activeSpaceId })

        let state = NomState(currentSpaceId: currentSpace?.id ?? "", spaces: named)
        Task {
            try? await store.writeState(state)
        }
    }

    private func reloadNames() {
        names = nameStore.allNames()
        refreshSync()
    }
}
