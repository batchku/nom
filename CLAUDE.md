# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build & Run

```bash
swift build                              # build all targets
swift test                               # movement and workspace-state regression tests
bash scripts/test-window-move.sh          # opt-in live round trip with a disposable window
bash scripts/test-window-move.sh --full-height # regression for vertically constrained windows
.build/debug/nom list                    # run CLI
bash scripts/build-app.sh               # build .app bundle → .build/debug/nom.app
bash scripts/build-app.sh release       # release build
open .build/debug/nom.app               # launch the app
pkill -f NomApp                         # kill running app before rebuild
```

No Xcode project — pure SPM + manual .app bundle assembly via `scripts/build-app.sh`.

## Architecture

Three SPM targets sharing a core library:

- **NomCore** — shared library: SkyLight private API bridge, models, name persistence (`NameStore`), state file
- **NomApp** — SwiftUI menu bar app with HUD overlay (depends on NomCore)
- **NomCLI** — standalone CLI tool (depends on NomCore)

Space names live in the `com.teambrilliant.nom` preferences domain (`~/Library/Preferences/com.teambrilliant.nom.plist` via CFPreferences in `NameStore`) — inspect with `defaults read com.teambrilliant.nom`. App and CLI both read/write it; CLI posts a `DistributedNotificationCenter` notification so the app reloads. `~/.nom/state.json` carries runtime state for `nom current`; `~/.nom/config.json` is legacy, read once by `NameStore.migrateLegacyConfigIfNeeded` and never written.

### Key flow

1. `SpaceMonitor` polls `SpaceReader.snapshot()` and observes `NSWorkspace.activeSpaceDidChangeNotification`
2. On a layout, focus, or current-space change: applies UUID-keyed names and updates `@Observable` state; only a current-space change triggers the switch HUD
3. `MenuBarExtra` label re-renders from `SpaceMonitor.currentSpace`
4. CLI writes the preferences domain via `NameStore` → distributed notification → SpaceMonitor reloads

## SkyLight Private APIs

Accessed via `@_silgen_name` in `NomCore/SkyLight.swift`. Linked with `-F/System/Library/PrivateFrameworks -framework SkyLight`.

**Safe to use (read-only):**
- `SLSMainConnectionID`, `SLSGetActiveSpace`, `SLSCopyManagedDisplaySpaces`, `SLSSpaceGetType`, `SLSCopySpacesForWindows`
- `_AXUIElementGetWindow` maps a captured AX window to its window ID for membership checks

**Do NOT use:**
- `SLSManagedDisplaySetCurrentSpace` — corrupts macOS display compositor, causes overlapping menu bars and space merging. Requires SIP disable + yabai-level setup.
- `SLSSpaceSetName` — overwrites the space UUID field instead of setting a separate name attribute, breaking UUID-based identity.

## Key Design Decisions

- **Space identity**: `SpaceInfo.persistentKey` = the space `uuid` from `SLSCopyManagedDisplaySpaces` — the only identifier that survives reboot. `id64` is a per-boot counter, runtime-only. Default Desktop 1 has an empty UUID → sentinel key `"desktop-1"`. Never write names via `SLSSpaceSetName` (it corrupts the UUID field)
- **Global indexing**: `SpaceInfo.index` is global Mission Control order (primary display first), matches Ctrl+N shortcuts
- **Workspace observation**: `SpaceReader.snapshot()` reads the ordered workspace identities and each display's "Current Space" from one SkyLight result. `SpaceMonitor` compares the full layout on every poll: Mission Control reordering can change order and global indices without changing any current-space ID or emitting `activeSpaceDidChangeNotification`. Layout-only changes refresh the menu and runtime state with names still attached to UUIDs. The menu also refreshes on opening. `SLSGetActiveSpace` changes when focus moves to another display; this refreshes the title without a switch HUD. A changed per-display current-space map triggers that HUD.
- **Sync refresh**: `SpaceMonitor.refreshSync()` applies names from cached config synchronously so HUD shows correct name immediately (no async race)
- **Space actions go through UI-level paths, never write-side SLS APIs** (all need Accessibility permission):
  - *Switch*: `SpaceSwitcher.switchTo` resolves the selected workspace's current index and display by runtime ID before posting a shortcut, so a captured menu row cannot use a pre-reorder index. It posts the "Switch to Desktop N" symbolic hotkey (ID 118+N-1), enabling it just long enough if disabled, then verifies the display's current space changed within 1.2 s. If not (or the space has no hotkey: fullscreen, index > 16) it exits to the space from Mission Control's bar via `MissionControlBar.switchTo`. The verify step exists because macOS 27 silently drops Desktop N registrations (seen on 27.0.1: everything past Desktop 3 while a secondary display had one space; `SLSSetSymbolicHotKeyEnabled` still reads back true; adding and deleting a desktop re-registers them). Always restore a hotkey's previous enabled state — Mission Control (32) and Ctrl+arrows (79/81) are on by default and stay dead if left disabled
  - *Move window*: `WindowMover` captures the focused AX window and its window ID, verifies a title-bar drag, then uses Ctrl+Left/Right (symbolic hotkeys 79/81) through the display's actual space order. Desktop N registrations are unreliable on macOS 27. Mouse and keyboard events share a private event source. Space changes and window membership are checked after each step and after mouse-up. Cross-display moves prepare the destination before grabbing, then drag onto it, including when that desktop is already visible. Full-height windows can refuse vertical dragging, and tiled/zoomed windows can resize when a hold begins. Start with a one-pixel horizontal drag, wait for AX and WindowServer frames to agree for three polls, then verify a separate ten-pixel translation with unchanged size. Allow one settled retry after a native resize; a resize alone never proves a hold. Restore failed probes before reusing coordinates. Keep the successful offset until release, then restore and verify the original frame for same-display moves. All app space actions serialize; movement failure shows an alert. Mission Control thumbnail switching cannot carry a held window on 27.0.1, and direct `SLSMoveWindowsToManagedSpace` requires SIP off.
  - *Add space*: `SpaceAdder` opens Mission Control and performs `AXPress` on the display's `mc.spaces.add` button (child of the `mc.spaces` group, sibling of `mc.spaces.list`); the new desktop is found by diffing `SLSCopyManagedDisplaySpaces` before/after. The app then jumps to it and shows a `RenamePromptController` card (non-activating key panel) for naming
  - *Delete space*: `SpaceDeleter` opens Mission Control (symbolic hotkey 32) and performs `AXRemoveDesktop` on the space's thumbnail. Don't pre-check advertised action names — `AXRemoveDesktop` is registered lazily (often only `AXPress` shows right after opening); perform it and verify the space vanished from `SLSCopyManagedDisplaySpaces`. Mission Control dismisses on any real user input, so wait for an input-quiet moment first
  - *Mission Control's AX tree* (`MissionControlBar`): hosted by the **WindowManager** process (`com.apple.WindowManager`) on macOS 27+, by the Dock before that (the Dock keeps an empty `mc` group on 27). Same identifiers in both: `mc.display` > `mc.spaces` > `mc.spaces.list` / `mc.spaces.add`, sometimes under a wrapper group `id=mc`. `MissionControlBar.hosts()` scans both. On 27 an `AXPress` on a thumbnail exits to that space and dismisses Mission Control (~100 ms); on the Dock-hosted bar it only dismisses, and the hover-dwell-click fallback is needed. Only send Escape if `isOpen()` — otherwise it lands in the frontmost app

## Concurrency

Swift 6 strict concurrency throughout:
- `SpaceMonitor`, `HUDController`, `AppDelegate` are `@MainActor`
- `ConfigStore` is an actor (serialized state-file I/O)
- `NameStore` is a stateless `Sendable` struct (CFPreferences is thread-safe)
- CLI bypasses actor isolation with direct synchronous file I/O
