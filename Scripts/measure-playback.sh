#!/bin/bash
# Plays a file or URL in the Debug build, silently and in the background, and reports
# time to first frame, CPU and memory while it plays, and leaks.
#
# Usage: Scripts/measure-playback.sh <file-or-url> [seconds-to-sample] [engine options]
#   Scripts/measure-playback.sh TestMedia/hdr10-hevc-4k60.mkv 12
#   Scripts/measure-playback.sh TestMedia/hdr10-hevc-4k60.mkv 12 "profile=fast"
#
# The file is played in a loop, so that it is still playing while the samples are taken
# however short it is. (Until Stage 4 it was not: with the 10-second samples the memory figure
# was read after the file had ended, about 200 MB too low, and idle CPU samples were dropped
# by accident. Numbers recorded before that are marked in the performance log.)
#
# Notes: the Debug build is used because the launch arguments that start playback are
# compiled out of Release; the engine itself (Libmpv.framework) is the same optimised
# binary either way. CPU is a share of one core. The window is in the background, so
# the numbers do not include whatever the window server saves or spends on an occluded window.
set -euo pipefail

cd "$(dirname "$0")/.."
MEDIA="${1:?usage: measure-playback.sh <file-or-url> [seconds]}"
SECONDS_TO_SAMPLE="${2:-10}"
ENGINE_OPTIONS="loop-file=inf${3:+,$3}"
# Never hand the app a file inside ~/Documents: macOS would ask the user for permission.
MEDIA="$(Scripts/stage-media.sh "$MEDIA")"

# PROFILE_BUILD=1 uses the optimised build with launch arguments (Scripts/build-profile.sh).
PRODUCTS="build/DerivedData${PROFILE_BUILD:+-Profile}/Build/Products/Debug"
APP="$(find "$PRODUCTS" -maxdepth 1 -name '*.app' 2>/dev/null | head -1)"
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
open -g "$APP" --args -silent YES -section addons -engine "$ENGINE_OPTIONS" -play "$MEDIA" -stats "$((SECONDS_TO_SAMPLE + 2))"
PID=""
for _ in $(seq 1 50); do
    PID="$(pgrep -f "$BINARY" | head -1 || true)"
    [[ -n "$PID" ]] && break
    sleep 0.1
done
[[ -n "$PID" ]] || { echo "app did not start" >&2; exit 1; }

sleep 3 # past start-up
# top's first sample is since process start; the later ones are per interval.
TOP_OUTPUT="$(mktemp)"
top -l $((SECONDS_TO_SAMPLE / 2 + 1)) -s 2 -pid "$PID" -stats cpu >"$TOP_OUTPUT" 2>/dev/null &
TOP_PID=$!
# Memory while it plays: the largest of a few readings taken alongside the CPU samples.
FOOTPRINT_MB=0
READINGS=()
while kill -0 "$TOP_PID" 2>/dev/null; do
    reading="$(footprint "$PID" 2>/dev/null | awk '/TOTAL/ {print ($2 == "GB") ? $1 * 1024 : $1; exit}')"
    reading="${reading%.*}"
    if [[ -n "$reading" ]]; then
        READINGS+=("$reading")
        [[ "$reading" -gt "$FOOTPRINT_MB" ]] && FOOTPRINT_MB="$reading"
    fi
    sleep 1.5
done
# The last third of the readings: what it settles at once caches have filled.
SETTLED_MB="$(printf '%s\n' ${READINGS[@]+"${READINGS[@]}"} | tail -n "$(( (${#READINGS[@]} + 2) / 3 ))" | sort -n | awk '{v[NR] = $1} END {if (NR) print v[int((NR + 1) / 2)]; else print "?"}')"
wait "$TOP_PID" 2>/dev/null || true
# top pads values below 10 with spaces, so the test is on the field, not on the whole line.
CPU_SAMPLES="$(awk 'NF == 1 && $1 ~ /^[0-9.]+$/ {print $1}' "$TOP_OUTPUT" | tail -n +2)"
rm -f "$TOP_OUTPUT"
CPU_AVG="$(echo "$CPU_SAMPLES" | awk '{sum += $1; n++} END {if (n) printf "%.1f", sum / n; else print "?"}')"
CPU_MAX="$(echo "$CPU_SAMPLES" | sort -n | tail -1)"
FOOTPRINT="${FOOTPRINT_MB} MB"
LEAKS="$(leaks "$PID" 2>/dev/null | grep -E 'leaks for' | sed 's/^Process [0-9]*: //' || true)"
FIRST_FRAME="$(/usr/bin/log show --last "$((SECONDS_TO_SAMPLE + 20))s" --style compact \
    --predicate "processID == $PID AND subsystem == \"$BUNDLE_ID\" AND category == \"player\"" 2>/dev/null \
    | grep -oE '(first-frame-ms=[0-9]+ source=[a-z]+|playback failed.*)' | tail -1 || true)"

DECODER="$(/usr/bin/log show --last "$((SECONDS_TO_SAMPLE + 20))s" --style compact \
    --predicate "processID == $PID AND subsystem == \"$BUNDLE_ID\" AND category == \"player\"" 2>/dev/null \
    | grep -oE 'decoder=[a-z-]+' | tr '\n' ' ' || true)"

STATS="$(/usr/bin/log show --last "$((SECONDS_TO_SAMPLE + 20))s" --style compact \
    --predicate "processID == $PID AND subsystem == \"$BUNDLE_ID\" AND category == \"player\"" 2>/dev/null \
    | grep -oE 'stats .*' | tail -1 | sed 's/^stats //' || true)"

echo "media:        $(basename "$MEDIA")${ENGINE_OPTIONS:+   [engine: $ENGINE_OPTIONS]}"
echo "first frame:  ${FIRST_FRAME:-not reported}"
echo "decoder:      ${DECODER:-not reported}"
echo "cpu:          average ${CPU_AVG}% of one core, peak ${CPU_MAX:-?}% (sampled every 2 s for ${SECONDS_TO_SAMPLE} s)"
echo "memory:       footprint ${FOOTPRINT:-unknown} at most while playing, ${SETTLED_MB} MB towards the end"
echo "frames:       ${STATS:-not reported}"
echo "leaks:        ${LEAKS:-not available}"
