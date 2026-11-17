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
open -g "$APP" --args "$@"

PID=""
for _ in $(seq 1 50); do
    PID="$(pgrep -f "$BINARY" | head -1 || true)"
    [[ -n "$PID" ]] && break
    sleep 0.1
done
[[ -n "$PID" ]] || { echo "app did not start" >&2; exit 1; }

sleep "$WAIT"
WINDOW="$(swift Scripts/window-id.swift "$PID")"
screencapture -x -o -l "$WINDOW" "$OUTPUT"
echo "saved $OUTPUT (pid $PID, window $WINDOW)"

[[ "${KEEP_RUNNING:-0}" == "1" ]] || quit_app
