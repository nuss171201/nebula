#!/bin/bash
# Launches the Debug build in the background (without taking focus), waits, saves a
# screenshot of its main window, and quits it. Extra arguments are passed to the app;
# see App/DebugLaunchOptions.swift.
#
# Usage: Scripts/screenshot.sh <output.png> [seconds-to-wait] [app arguments...]
#   Scripts/screenshot.sh /tmp/home.png 6
#   Scripts/screenshot.sh /tmp/discover.png 6 -section discover
#   Scripts/screenshot.sh /tmp/detail.png 8 -open series:tt0386676
#   KEEP_RUNNING=1 Scripts/screenshot.sh ...     leave the app running afterwards
#
# Every window of the app is captured: the largest as <output>, the rest as <output>-2 and so on.
# Limitation: a window that has a sheet attached cannot be captured this way.
set -euo pipefail

cd "$(dirname "$0")/.."
OUTPUT="${1:?usage: screenshot.sh <output.png> [seconds] [app args...]}"
WAIT="${2:-5}"
shift $(( $# > 1 ? 2 : 1 ))

APP="$(find build/DerivedData/Build/Products/Debug -maxdepth 1 -name '*.app' 2>/dev/null | head -1)"
[[ -d "$APP" ]] || { echo "No Debug build found. Run Scripts/ci.sh first." >&2; exit 1; }
APP="$(cd "$APP" && pwd)"
BINARY="$APP/Contents/MacOS/$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$APP/Contents/Info.plist")"

quit_app() {
    pkill -f "$BINARY" 2>/dev/null || true
    while pgrep -f "$BINARY" >/dev/null 2>&1; do sleep 0.2; done
}

quit_app
# Never leave the app running behind the user's back, even if the capture fails.
[[ "${KEEP_RUNNING:-0}" == "1" ]] || trap quit_app EXIT
open -g "$APP" --args "$@"

PID=""
for _ in $(seq 1 50); do
    PID="$(pgrep -f "$BINARY" | head -1 || true)"
    [[ -n "$PID" ]] && break
    sleep 0.1
done
[[ -n "$PID" ]] || { echo "app did not start" >&2; exit 1; }

sleep "$WAIT"
# Largest window first. The first is saved as OUTPUT; any others (the player window,
# for example) as OUTPUT with -2, -3 … before the extension.
index=1
swift Scripts/window-id.swift "$PID" | while read -r window size; do
    target="$OUTPUT"
    [[ "$index" -gt 1 ]] && target="${OUTPUT%.*}-$index.${OUTPUT##*.}"
    if screencapture -x -o -l "$window" "$target" 2>/dev/null; then
        echo "saved $target (window $window, $size)"
    else
        echo "could not capture window $window ($size)" >&2
    fi
    index=$((index + 1))
done
