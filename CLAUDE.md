# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build & Run

```bash
swift build                              # build all targets
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

1. `SpaceMonitor` observes `NSWorkspace.activeSpaceDidChangeNotification`
2. On switch: reads SkyLight APIs → merges with config names → updates `@Observable` state → triggers HUD
3. `MenuBarExtra` label re-renders from `SpaceMonitor.currentSpace`
4. CLI writes the preferences domain via `NameStore` → distributed notification → SpaceMonitor reloads

## SkyLight Private APIs

Accessed via `@_silgen_name` in `NomCore/SkyLight.swift`. Linked with `-F/System/Library/PrivateFrameworks -framework SkyLight`.

**Safe to use (read-only):**
- `SLSMainConnectionID`, `SLSGetActiveSpace`, `SLSCopyManagedDisplaySpaces`, `SLSSpaceGetType`

**Do NOT use:**
- `SLSManagedDisplaySetCurrentSpace` — corrupts macOS display compositor, causes overlapping menu bars and space merging. Requires SIP disable + yabai-level setup.
- `SLSSpaceSetName` — overwrites the space UUID field instead of setting a separate name attribute, breaking UUID-based identity.

## Key Design Decisions

- **Space identity**: `SpaceInfo.persistentKey` = the space `uuid` from `SLSCopyManagedDisplaySpaces` — the only identifier that survives reboot. `id64` is a per-boot counter, runtime-only. Default Desktop 1 has an empty UUID → sentinel key `"desktop-1"`. Never write names via `SLSSpaceSetName` (it corrupts the UUID field)
- **Global indexing**: `SpaceInfo.index` is global Mission Control order (primary display first), matches Ctrl+N shortcuts
- **Sync refresh**: `SpaceMonitor.refreshSync()` applies names from cached config synchronously so HUD shows correct name immediately (no async race)
- **Space actions go through UI-level paths, never write-side SLS APIs** (all need Accessibility permission):
  - *Switch*: `SpaceSwitcher` posts the "Switch to Desktop N" symbolic hotkey (ID 118+N-1), enabling it just long enough if disabled
  - *Move window*: `WindowMover` holds the title bar with synthetic mouse events (grab verified via AX before switching; cross-display = drag there first). Direct `SLSMoveWindowsToManagedSpace` is dead without SIP off since ~14.5
  - *Delete space*: `SpaceDeleter` opens Mission Control (symbolic hotkey 32) and performs `AXRemoveDesktop` on the space's thumbnail in the Dock's AX tree. Don't pre-check advertised action names — the Dock registers `AXRemoveDesktop` lazily (often only `AXPress` shows right after opening); perform it and verify the space vanished from `SLSCopyManagedDisplaySpaces`. Mission Control dismisses on any real user input, so wait for an input-quiet moment first. The `mc.display` groups sometimes sit under a wrapper group `id=mc`, sometimes at the Dock's top level

## Concurrency

Swift 6 strict concurrency throughout:
- `SpaceMonitor`, `HUDController`, `AppDelegate` are `@MainActor`
- `ConfigStore` is an actor (serialized state-file I/O)
- `NameStore` is a stateless `Sendable` struct (CFPreferences is thread-safe)
- CLI bypasses actor isolation with direct synchronous file I/O
