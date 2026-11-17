#!/bin/bash
# Scrolls a screen of the optimised build by itself, in the background, and reports how late
# the main thread was for each of the 120 ticks a second (see App/DebugAutoscroll.swift).
# A tick more than 8 ms late is a missed frame at 120 Hz; more than 16 ms, at 60 Hz.
#
# Usage: Scripts/measure-scroll.sh [section] [seconds] [points-per-second] [more app arguments…]
#   Scripts/measure-scroll.sh discover 8
#   CLEAR_IMAGE_CACHE=1 Scripts/measure-scroll.sh home 8 2500    artwork has to be fetched and decoded
#
# Needs Scripts/build-profile.sh to have been run. The window is in the background but must not
# be hidden behind others entirely for Core Animation to do its part of the work.
set -euo pipefail

cd "$(dirname "$0")/.."
SECTION="${1:-discover}"
SECONDS_TO_SCROLL="${2:-8}"
SPEED="${3:-2500}"
shift $(( $# > 3 ? 3 : $# ))

APP="$(find build/DerivedData-Profile/Build/Products/Debug -maxdepth 1 -name '*.app' 2>/dev/null | head -1)"
[[ -d "$APP" ]] || { echo "No profile build found. Run Scripts/build-profile.sh first." >&2; exit 1; }
APP="$(cd "$APP" && pwd)"
PLIST="$APP/Contents/Info.plist"
BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$PLIST")"
BINARY="$APP/Contents/MacOS/$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$PLIST")"

quit_app() {
    pkill -f "$BINARY" 2>/dev/null || true
    while pgrep -f "$BINARY" >/dev/null 2>&1; do sleep 0.2; done
}
trap quit_app EXIT
quit_app
if [[ "${CLEAR_IMAGE_CACHE:-0}" == "1" ]]; then
    rm -rf "$HOME/Library/Caches/$BUNDLE_ID/Images"
fi

open -g "$APP" --args -section "$SECTION" -autoscroll "$SECONDS_TO_SCROLL" -scrollSpeed "$SPEED" "$@"
PID=""
for _ in $(seq 1 50); do
    PID="$(pgrep -f "$BINARY" | head -1 || true)"
    [[ -n "$PID" ]] && break
    sleep 0.1
done
[[ -n "$PID" ]] || { echo "app did not start" >&2; exit 1; }
sleep "$((SECONDS_TO_SCROLL + 5))"

RESULT="$(/usr/bin/log show --last "$((SECONDS_TO_SCROLL + 30))s" --style compact \
    --predicate "processID == $PID AND subsystem == \"$BUNDLE_ID\" AND category == \"autoscroll\"" 2>/dev/null \
    | grep -oE 'autoscroll .*' | tail -1 || true)"
echo "screen:  $SECTION, ${SECONDS_TO_SCROLL} s at ${SPEED} pt/s${CLEAR_IMAGE_CACHE:+, empty image cache}"
echo "result:  ${RESULT:-not reported}"
