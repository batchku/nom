import Testing
@testable import NomCore

struct SpaceSnapshotTests {
    @Test func reorderedInactiveDesktopsKeepTheirNames() {
        let before = snapshot([space(10, index: 1), space(20, index: 2), space(30, index: 3)])
        let after = snapshot([space(10, index: 1), space(30, index: 2), space(20, index: 3)])

        #expect(after.change(since: before) == .layout)
        let named = after.namedSpaces(using: ["uuid-10": "Code", "uuid-20": "Mail", "uuid-30": "Design"])
        #expect(named.map(\.spaceId) == [10, 30, 20])
        #expect(named.map(\.index) == [1, 2, 3])
        #expect(named.map(\.name) == ["Code", "Design", "Mail"])
        #expect(after.activeSpaceId == before.activeSpaceId)
        #expect(after.currentSpaceIds == before.currentSpaceIds)
    }

    @Test func movingTheActiveDesktopChangesLayoutWithoutSwitching() throws {
        let before = snapshot([space(10, index: 1), space(20, index: 2)])
        let after = snapshot([space(20, index: 1), space(10, index: 2)])

        #expect(after.change(since: before) == .layout)
        #expect(try #require(after.space(withID: after.activeSpaceId)).index == 2)
    }

    @Test func displayReorderingUpdatesGlobalNumbers() {
        let before = snapshot([
            space(10, index: 1), space(40, index: 2, display: "secondary"),
        ], current: ["primary": 10, "secondary": 40])
        let after = snapshot([
            space(40, index: 1, display: "secondary"), space(10, index: 2),
        ], current: ["primary": 10, "secondary": 40])

        #expect(after.change(since: before) == .layout)
    }

    @Test func movingAnInactiveDesktopBetweenDisplaysChangesLayout() {
        let before = snapshot([
            space(10, index: 1), space(20, index: 2), space(40, index: 3, display: "secondary"),
        ], current: ["primary": 10, "secondary": 40])
        let after = snapshot([
            space(10, index: 1), space(20, index: 2, display: "secondary"),
            space(40, index: 3, display: "secondary"),
        ], current: ["primary": 10, "secondary": 40])

        #expect(after.change(since: before) == .layout)
    }

    @Test func fullscreenOrderAndMetadataArePartOfTheLayout() {
        let fullscreen = space(60, index: 0, type: 4, appName: "Browser")
        let before = snapshot([space(10, index: 1), fullscreen, space(20, index: 2)])
        let reordered = snapshot([space(10, index: 1), space(20, index: 2), fullscreen])
        let renamedApp = snapshot([
            space(10, index: 1), space(60, index: 0, type: 4, appName: "Editor"), space(20, index: 2),
        ])
        let changedType = snapshot([
            space(10, index: 1), space(60, index: 0, type: 2, appName: "Browser"), space(20, index: 2),
        ])

        #expect(reordered.change(since: before) == .layout)
        #expect(renamedApp.change(since: before) == .layout)
        #expect(changedType.change(since: before) == .layout)
    }

    @Test func addingOrRemovingAnInactiveDesktopChangesLayout() {
        let before = snapshot([space(10, index: 1), space(20, index: 2)])
        let added = snapshot([space(10, index: 1), space(20, index: 2), space(30, index: 3)])
        let removed = snapshot([space(10, index: 1)])

        #expect(added.change(since: before) == .layout)
        #expect(removed.change(since: before) == .layout)
    }

    @Test func focusAcrossDisplaysDoesNotCountAsASpaceSwitch() {
        let spaces = [space(10, index: 1), space(40, index: 2, display: "secondary")]
        let before = snapshot(spaces, current: ["primary": 10, "secondary": 40])
        let after = snapshot(spaces, active: 40, current: ["primary": 10, "secondary": 40])

        #expect(after.change(since: before) == .focus)
    }

    @Test func aVisibleSpaceChangeWinsEvenWhenFocusDoesNotChange() {
        let before = snapshot([
            space(10, index: 1), space(40, index: 2, display: "secondary"),
            space(50, index: 3, display: "secondary"),
        ], current: ["primary": 10, "secondary": 40])
        let after = snapshot([
            space(10, index: 1), space(50, index: 2, display: "secondary"),
            space(40, index: 3, display: "secondary"),
        ], current: ["primary": 10, "secondary": 50])

        #expect(after.change(since: before) == .space)
        #expect(after.activeSpaceId == before.activeSpaceId)
    }

    @Test func layoutTakesPriorityOverFocus() {
        let before = snapshot([space(10, index: 1), space(40, index: 2, display: "secondary")],
                              current: ["primary": 10, "secondary": 40])
        let after = snapshot([space(40, index: 1, display: "secondary"), space(10, index: 2)],
                             active: 40, current: ["primary": 10, "secondary": 40])

        #expect(after.change(since: before) == .layout)
    }

    @Test func unchangedStateAndStoredNameChangesDoNotChangeLayout() {
        let before = snapshot([space(10, index: 1)])
        let renamed = snapshot([space(10, index: 1, name: "New name")])

        #expect(before.change(since: before) == .none)
        #expect(renamed.change(since: before) == .none)
    }

    @Test func changedUUIDRefreshesIdentityAndNames() {
        let before = snapshot([space(10, index: 1)])
        let after = snapshot([space(10, index: 1, uuid: "replacement")])

        #expect(after.change(since: before) == .layout)
        #expect(after.namedSpaces(using: ["uuid-10": "Old", "replacement": "New"]).first?.name == "New")
    }

    @Test func namesUsePersistentKeysAndClearRemovedNames() {
        let state = snapshot([
            space(1, index: 2, uuid: "", name: "Stale"),
            space(20, index: 1, name: "Removed"),
        ], active: 1, current: ["primary": 1])
        let named = state.namedSpaces(using: ["desktop-1": "Home"])

        #expect(named.map(\.spaceId) == [1, 20])
        #expect(named.map(\.name) == ["Home", nil])
    }

    @Test func staleSelectionResolvesCurrentIndexAndDisplay() throws {
        let selected = space(20, index: 2)
        let after = snapshot([
            space(10, index: 1), space(40, index: 2, display: "secondary"),
            space(20, index: 3, display: "secondary"),
        ], current: ["primary": 10, "secondary": 40])
        let resolved = try #require(after.space(withID: selected.spaceId))

        #expect(resolved.index == 3)
        #expect(resolved.displayId == "secondary")
        #expect(resolved.uuid == selected.uuid)
        #expect(after.space(withID: 99) == nil)
        #expect(snapshot([space(10, index: 1)]).space(withID: selected.spaceId) == nil)
    }

    private func snapshot(
        _ spaces: [SpaceInfo], active: Int = 10, current: [String: Int] = ["primary": 10]
    ) -> SpaceSnapshot {
        SpaceSnapshot(spaces: spaces, activeSpaceId: active, currentSpaceIds: current)
    }

    private func space(
        _ id: Int, index: Int, display: String = "primary", uuid: String? = nil,
        type: Int32 = 0, name: String? = nil, appName: String? = nil
    ) -> SpaceInfo {
        SpaceInfo(spaceId: id, uuid: uuid ?? "uuid-\(id)", index: index, displayId: display,
                  type: type, name: name, appName: appName)
    }
}
