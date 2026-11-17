#!/bin/bash
# Measures launch time and idle memory. The app logs its own launch milestones
# (MediaCore.LaunchMetrics); this script launches it in the background several
# times and reads the values back:
#   first-screen   process start -> the main window's first frame
#   home-content   process start -> the first Home row has its catalog data
#
# Usage: Scripts/measure-launch.sh [runs]        (default 5, Release build)
#        CONFIG=Debug Scripts/measure-launch.sh
#
# Notes: these are warm-cache launches; a true cold launch (after a reboot or
# `sudo purge`) is slower. home-content depends on the network unless the catalog
# response is still in the HTTP cache.
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

# Reads one milestone for a pid from the unified log, waiting up to ~12 s.
read_milestone() {
    local pid="$1" name="$2" value=""
    for _ in $(seq 1 24); do
        value="$(/usr/bin/log show --last 40s --style compact \
            --predicate "processID == $pid AND subsystem == \"$BUNDLE_ID\" AND category == \"launch\"" 2>/dev/null \
            | sed -n "s/.*$name-ms=\([0-9][0-9]*\).*/\1/p" | tail -1)"
        [[ -n "$value" ]] && break
        sleep 0.5
    done
    echo "$value"
}

summarise() {
    local label="$1"; shift
    local sorted count
    sorted=($(printf '%s\n' "$@" | sort -n))
    count=${#sorted[@]}
    printf '%-14s median %s ms  (min %s, max %s, n=%s)\n' \
        "$label" "${sorted[$((count / 2))]}" "${sorted[0]}" "${sorted[$((count - 1))]}" "$count"
}

first_screen=()
home_content=()
footprint_line=""
rss_kb=0
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

    screen_ms="$(read_milestone "$pid" first-screen)"
    [[ -n "$screen_ms" ]] || { echo "run $run: no first-screen log entry found" >&2; quit_app; exit 1; }
    content_ms="$(read_milestone "$pid" home-content)"

    echo "run $run: first-screen ${screen_ms} ms, home-content ${content_ms:-not reached} ms"
    first_screen+=("$screen_ms")
    [[ -n "$content_ms" ]] && home_content+=("$content_ms")

    if [[ "$run" == "$RUNS" ]]; then
        sleep 4 # let artwork finish loading before sampling memory
        footprint_line="$(footprint "$pid" 2>/dev/null | grep -m1 -i 'footprint:' | sed 's/.*Footprint: *//' || true)"
        rss_kb="$(ps -o rss= -p "$pid" | tr -d ' ')"
    fi
done
quit_app

echo
echo "config:        $CONFIG"
summarise "first-screen" "${first_screen[@]}"
if (( ${#home_content[@]} > 0 )); then
    summarise "home-content" "${home_content[@]}"
else
    echo "home-content   not reached in any run (offline, or no catalogs installed)"
fi
echo "memory:        footprint ${footprint_line:-unknown}, RSS $((rss_kb / 1024)) MB (Home loaded, idle)"
