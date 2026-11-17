#!/bin/bash
# Plays a file or URL in the Debug build, silently and in the background, and reports
# time to first frame, CPU and memory while it plays, and leaks.
#
# Usage: Scripts/measure-playback.sh <file-or-url> [seconds-to-sample] [engine options]
#   Scripts/measure-playback.sh TestMedia/hdr10-hevc-4k60.mkv 12
#   Scripts/measure-playback.sh TestMedia/hdr10-hevc-4k60.mkv 12 "profile=fast"
#
# Notes: the Debug build is used because the launch arguments that start playback are
# compiled out of Release; the engine itself (Libmpv.framework) is the same optimised
# binary either way. CPU is a share of one core. The window is in the background, so
# the numbers do not include whatever the window server saves or spends on an occluded window.
set -euo pipefail

cd "$(dirname "$0")/.."
MEDIA="${1:?usage: measure-playback.sh <file-or-url> [seconds]}"
SECONDS_TO_SAMPLE="${2:-10}"
ENGINE_OPTIONS="${3:-}"
# Never hand the app a file inside ~/Documents: macOS would ask the user for permission.
MEDIA="$(Scripts/stage-media.sh "$MEDIA")"

APP="$(find build/DerivedData/Build/Products/Debug -maxdepth 1 -name '*.app' 2>/dev/null | head -1)"
[[ -d "$APP" ]] || { echo "No Debug build found. Run Scripts/ci.sh first." >&2; exit 1; }
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
# The Add-ons section keeps the main window quiet, so the numbers are the player's.
open -g "$APP" --args -silent YES -section addons -engine "$ENGINE_OPTIONS" -play "$MEDIA"
PID=""
for _ in $(seq 1 50); do
    PID="$(pgrep -f "$BINARY" | head -1 || true)"
    [[ -n "$PID" ]] && break
    sleep 0.1
done
[[ -n "$PID" ]] || { echo "app did not start" >&2; exit 1; }

sleep 3 # past start-up
# top's first sample is since process start; the later ones are per interval.
CPU_SAMPLES="$(top -l $((SECONDS_TO_SAMPLE / 2 + 1)) -s 2 -pid "$PID" -stats cpu 2>/dev/null | awk '/^[0-9.]+$/ {print $1}' | tail -n +2)"
CPU_AVG="$(echo "$CPU_SAMPLES" | awk '{sum += $1; n++} END {if (n) printf "%.1f", sum / n; else print "?"}')"
CPU_MAX="$(echo "$CPU_SAMPLES" | sort -n | tail -1)"
FOOTPRINT="$(footprint "$PID" 2>/dev/null | grep -m1 -i 'footprint:' | sed 's/.*Footprint: *//; s/ (.*//' || true)"
LEAKS="$(leaks "$PID" 2>/dev/null | grep -E 'leaks for' | sed 's/^Process [0-9]*: //' || true)"
FIRST_FRAME="$(/usr/bin/log show --last "$((SECONDS_TO_SAMPLE + 20))s" --style compact \
    --predicate "processID == $PID AND subsystem == \"$BUNDLE_ID\" AND category == \"player\"" 2>/dev/null \
    | grep -oE '(first-frame-ms=[0-9]+ source=[a-z]+|playback failed.*)' | tail -1 || true)"

DECODER="$(/usr/bin/log show --last "$((SECONDS_TO_SAMPLE + 20))s" --style compact \
    --predicate "processID == $PID AND subsystem == \"$BUNDLE_ID\" AND category == \"player\"" 2>/dev/null \
    | grep -oE 'decoder=[a-z-]+' | tr '\n' ' ' || true)"

echo "media:        $(basename "$MEDIA")${ENGINE_OPTIONS:+   [engine: $ENGINE_OPTIONS]}"
echo "first frame:  ${FIRST_FRAME:-not reported}"
echo "decoder:      ${DECODER:-not reported}"
echo "cpu:          average ${CPU_AVG}% of one core, peak ${CPU_MAX:-?}% (sampled every 2 s for ${SECONDS_TO_SAMPLE} s)"
echo "memory:       footprint ${FOOTPRINT:-unknown}"
echo "leaks:        ${LEAKS:-not available}"
