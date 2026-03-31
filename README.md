# nom

Name your macOS Spaces. Always know where you are.

**nom** is a minimal macOS menu bar app that lets you assign names to your virtual desktops and shows the current Space name — persistently in the menu bar and as a large HUD overlay when switching.

## Features

- **Menu bar label** — always shows current Space name
- **HUD overlay** — large pill appears on all displays when switching Spaces, fades after 1.5s
- **CLI control** — name spaces from the terminal
- **Multi-display** — supports multiple monitors with global Mission Control numbering
- **No SIP changes** — uses only read-only private APIs

## Install

Requires macOS 14+ and Swift 6.

```bash
git clone https://github.com/teambrilliant/nom.git
cd nom
bash scripts/build-app.sh release --install
```

This builds and installs to `/Applications/nom.app`.

## CLI

```bash
nom list               # 1: Code  2: Email  3: Design  4: Comms  5: Music  6: Scratch *
nom current            # Scratch
nom set 3 "Design"     # Named space 3 → "Design"
nom unset 3            # Removed name from space 3
```

Space numbers are global Mission Control indices (matches Ctrl+N shortcuts).

The CLI binary is at `.build/release/nom` after building. Symlink it:

```bash
ln -s "$(pwd)/.build/release/nom" /usr/local/bin/nom
```

## How It Works

nom reads macOS Space state via SkyLight private APIs (read-only). Names are stored in `~/.nom/config.json`. The app and CLI sync via shared files + distributed notifications — changes from the CLI appear in the app within a second.

## Architecture

```
Sources/
  NomCore/    # Shared: SkyLight bridge, models, config, file watching
  NomApp/     # SwiftUI menu bar app + HUD overlay
  NomCLI/     # CLI binary
```

Three SPM targets, no Xcode project, no external dependencies.

## License

MIT
