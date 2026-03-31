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

- **NomCore** — shared library: SkyLight private API bridge, models, config persistence, file watching
- **NomApp** — SwiftUI menu bar app with HUD overlay (depends on NomCore)
- **NomCLI** — standalone CLI tool (depends on NomCore)

App and CLI communicate via shared files (`~/.nom/config.json`, `~/.nom/state.json`) + `DistributedNotificationCenter`. CLI can run independently of the app.

### Key flow

1. `SpaceMonitor` observes `NSWorkspace.activeSpaceDidChangeNotification`
2. On switch: reads SkyLight APIs → merges with config names → updates `@Observable` state → triggers HUD
3. `MenuBarExtra` label re-renders from `SpaceMonitor.currentSpace`
4. CLI writes config.json → FileWatcher + distributed notification → SpaceMonitor reloads

## SkyLight Private APIs

Accessed via `@_silgen_name` in `NomCore/SkyLight.swift`. Linked with `-F/System/Library/PrivateFrameworks -framework SkyLight`.

**Safe to use (read-only):**
- `SLSMainConnectionID`, `SLSGetActiveSpace`, `SLSCopyManagedDisplaySpaces`, `SLSSpaceGetType`

**Do NOT use:**
- `SLSManagedDisplaySetCurrentSpace` — corrupts macOS display compositor, causes overlapping menu bars and space merging. Requires SIP disable + yabai-level setup.
- `SLSSpaceSetName` — overwrites the space UUID field instead of setting a separate name attribute, breaking UUID-based identity.

## Key Design Decisions

- **Space identity**: uses `id64` (not UUID) as stable key — `SLSSpaceSetName` corrupts UUIDs, and default Desktop 1 has empty UUID
- **Global indexing**: `SpaceInfo.index` is global Mission Control order (primary display first), matches Ctrl+N shortcuts
- **Sync refresh**: `SpaceMonitor.refreshSync()` applies names from cached config synchronously so HUD shows correct name immediately (no async race)
- **No space switching**: private API is unsafe without SIP changes; app is display-only

## Concurrency

Swift 6 strict concurrency throughout:
- `SpaceMonitor`, `HUDController`, `AppDelegate` are `@MainActor`
- `ConfigStore` is an actor (serialized file I/O)
- `FileWatcher` is `@unchecked Sendable` (manages its own DispatchSource lifecycle)
- CLI bypasses actor isolation with direct synchronous file I/O
