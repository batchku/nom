#!/bin/bash
set -euo pipefail

if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
    cat <<'HELP'
Usage: bash scripts/test-window-move.sh [--full-height] [destination-desktop-index]

Creates a disposable window, moves it to another desktop, then moves it back.
The default destination is the next desktop on the window's display, wrapping
to the first desktop. An explicit index can test a move to another display.
--full-height uses a 600-point-wide window filling its screen's visible height
and checks that its original size and position survive the round trip.

Requires Accessibility permission for the terminal. Briefly controls the mouse
and switches desktops: leave the mouse and keyboard idle until it finishes.
Restores the original visible desktops, app focus, and pointer before exiting.
HELP
    exit 0
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
BINARY="$PROJECT_DIR/.build/probes/window-move-smoke-test"
mkdir -p "$(dirname "$BINARY")"
swiftc -swift-version 6 -package-name Nom \
    "$PROJECT_DIR"/Sources/NomCore/*.swift "$SCRIPT_DIR/WindowMoveSmokeTest.swift" \
    -o "$BINARY" -F/System/Library/PrivateFrameworks -framework SkyLight
exec "$BINARY" "$@"
