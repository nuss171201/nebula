#!/bin/bash
# Plays a file silently in the background in the optimised build (Scripts/build-profile.sh)
# and prints what its memory is made of once it has been playing for a while: the footprint
# by category, the largest heap users, and the sizes of the graphics surfaces.
#
# Usage: Scripts/memory-detail.sh <file-or-url> [seconds-before-reading] [engine options]
set -euo pipefail

cd "$(dirname "$0")/.."
MEDIA="$(Scripts/stage-media.sh "${1:?usage: memory-detail.sh <file-or-url> [seconds] [engine options]}")"
WAIT="${2:-8}"
# NO_LOOP=1 lets the file end (the player then holds its last frame), to see what an idle player keeps.
ENGINE_OPTIONS="${NO_LOOP:+keep-open=yes}${NO_LOOP:-loop-file=inf}${3:+,$3}"
ENGINE_OPTIONS="${ENGINE_OPTIONS/#keep-open=yes1/keep-open=yes}"
APP="$(cd "$(find build/DerivedData-Profile/Build/Products/Debug -maxdepth 1 -name '*.app' | head -1)" && pwd)"
BINARY="$APP/Contents/MacOS/$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$APP/Contents/Info.plist")"
quit_app() {
    pkill -f "$BINARY" 2>/dev/null || true
    while pgrep -f "$BINARY" >/dev/null 2>&1; do sleep 0.2; done
}
trap quit_app EXIT
quit_app
# A profile of its own: nothing of the user's is read or trimmed, and it runs alongside the app if that is open.
SCRATCH_PROFILE="$(mktemp -d "${TMPDIR:-/tmp}/orbit-check.XXXXXX")"
# shellcheck disable=SC2086  # EXTRA_ARGS is a list of words on purpose
open -g ${OPEN_ENV:+--env "$OPEN_ENV"} "$APP" --args -profile "$SCRATCH_PROFILE" -silent YES -section addons -engine "$ENGINE_OPTIONS" -play "$MEDIA" ${EXTRA_ARGS:-}
sleep "$WAIT"
PID="$(pgrep -f "$BINARY" | head -1)"
echo "engine: $ENGINE_OPTIONS"
footprint "$PID" | sed -n '2p;6,12p'
if [[ -n "${REGIONS:-}" ]]; then
    echo "--- unmapped graphics regions by size (count, dirty size)"
    footprint -v "$PID" 2>/dev/null | grep -iE 'unmapped.*graphics|graphics.*unmapped' | awk '{print $1, $2}' | sort | uniq -c | sort -k1,1nr | head -25
fi
echo "--- heap, largest"
heap "$PID" -s 2>/dev/null | sed -n '/COUNT/,$p' | sed -n '3,6p' | cut -c1-110
echo "--- graphics regions by size (count, size)"
vmmap "$PID" 2>/dev/null | grep -E '^(IOSurface|IOAccelerator)' | sed -E 's/^([A-Za-z]+).*\[ *([0-9.]+[KMG]).*/\1 \2/' | sort | uniq -c | sort -k1,1nr | head -14
