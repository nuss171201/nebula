#!/bin/bash
# Measures launch time (process creation -> first screen) and idle memory.
# The app logs the launch time itself (MediaCore.LaunchMetrics); this script
# launches it in the background several times and reads the value back.
#
# Usage: Scripts/measure-launch.sh [runs]        (default 5, Release build)
#        CONFIG=Debug Scripts/measure-launch.sh
#
# Note: these are warm-cache launches. A true cold launch (after reboot or
# `sudo purge`) is slower; measure that by hand when it matters.
set -euo pipefail

cd "$(dirname "$0")/.."
RUNS="${1:-5}"
CONFIG="${CONFIG:-Release}"
PRODUCTS="build/DerivedData/Build/Products/$CONFIG"

APP="$(find "$PRODUCTS" -maxdepth 1 -name '*.app' 2>/dev/null | head -1)"
if [[ ! -d "$APP" ]]; then
    echo "No $CONFIG build found. Run: Scripts/ci.sh --release" >&2
    exit 1
fi
APP="$(cd "$APP" && pwd)"
PLIST="$APP/Contents/Info.plist"
BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$PLIST")"
BINARY="$APP/Contents/MacOS/$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$PLIST")"

quit_app() {
    pkill -f "$BINARY" 2>/dev/null || true
    while pgrep -f "$BINARY" >/dev/null 2>&1; do sleep 0.2; done
}

results=()
footprint_line=""
for run in $(seq 1 "$RUNS"); do
    quit_app
    open -g "$APP"

    pid=""
    for _ in $(seq 1 50); do
        pid="$(pgrep -f "$BINARY" | head -1 || true)"
        [[ -n "$pid" ]] && break
        sleep 0.1
    done
    [[ -n "$pid" ]] || { echo "run $run: app did not start" >&2; exit 1; }

    ms=""
    for _ in $(seq 1 20); do
        ms="$(/usr/bin/log show --last 30s --style compact \
            --predicate "processID == $pid AND subsystem == \"$BUNDLE_ID\" AND category == \"launch\"" 2>/dev/null \
            | sed -n 's/.*first-screen-ms=\([0-9][0-9]*\).*/\1/p' | tail -1)"
        [[ -n "$ms" ]] && break
        sleep 0.5
    done
    [[ -n "$ms" ]] || { echo "run $run: no launch log entry found" >&2; quit_app; exit 1; }

    echo "run $run: ${ms} ms"
    results+=("$ms")

    if [[ "$run" == "$RUNS" ]]; then
        sleep 3 # let the app settle before sampling idle memory
        footprint_line="$(footprint "$pid" 2>/dev/null | grep -m1 -i 'footprint:' || true)"
        rss_kb="$(ps -o rss= -p "$pid" | tr -d ' ')"
    fi
done
quit_app

sorted=($(printf '%s\n' "${results[@]}" | sort -n))
count=${#sorted[@]}
median=${sorted[$((count / 2))]}
echo
echo "config:        $CONFIG"
echo "launch median: ${median} ms  (min ${sorted[0]}, max ${sorted[$((count - 1))]}, n=$count)"
echo "idle RSS:      $((rss_kb / 1024)) MB"
[[ -n "$footprint_line" ]] && echo "idle footprint: $footprint_line"
