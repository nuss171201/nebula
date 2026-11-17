#!/bin/bash
# Records a Time Profiler trace around a background launch of the Release build
# and prints a summary (see Scripts/analyze-trace.py). The trace is recorded
# system-wide and filtered to the app, so the launch itself is captured without
# xctrace bringing the app to the front.
#
# Usage: Scripts/profile-launch.sh [seconds-after-launch] [app arguments...]
#   Scripts/profile-launch.sh                 launch on Home, profile 8 s
#   CLEAR_IMAGE_CACHE=1 Scripts/profile-launch.sh   force artwork to download and decode
#
# The .trace is kept in build/traces/ and can be opened in Instruments.
set -euo pipefail

cd "$(dirname "$0")/.."
SECONDS_AFTER="${1:-8}"
shift $(( $# > 0 ? 1 : 0 ))

# PROFILE_BUILD=1 uses the optimised build with launch arguments (Scripts/build-profile.sh),
# for profiling a state that only a launch argument can open (playback, scrolling).
PRODUCTS="build/DerivedData/Build/Products/Release"
[[ -n "${PROFILE_BUILD:-}" ]] && PRODUCTS="build/DerivedData-Profile/Build/Products/Debug"
APP="$(find "$PRODUCTS" -maxdepth 1 -name '*.app' 2>/dev/null | head -1)"
[[ -d "$APP" ]] || { echo "No Release build found. Run: Scripts/ci.sh --release" >&2; exit 1; }
APP="$(cd "$APP" && pwd)"
PLIST="$APP/Contents/Info.plist"
NAME="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$PLIST")"
BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$PLIST")"
BINARY="$APP/Contents/MacOS/$NAME"

quit_app() {
    pkill -f "$BINARY" 2>/dev/null || true
    while pgrep -f "$BINARY" >/dev/null 2>&1; do sleep 0.2; done
}

mkdir -p build/traces
STAMP="$(date +%Y%m%d-%H%M%S)"
TRACE="build/traces/launch-$STAMP.trace"
EXPORT="build/traces/launch-$STAMP.xml"
LEAD_IN=5 # xctrace needs a few seconds before it is actually sampling

quit_app
if [[ "${CLEAR_IMAGE_CACHE:-0}" == "1" ]]; then
    rm -rf "$HOME/Library/Caches/$BUNDLE_ID/Images"
fi

xcrun xctrace record --template 'Time Profiler' --all-processes \
    --time-limit "$((LEAD_IN + SECONDS_AFTER))s" --output "$TRACE" >"build/traces/xctrace-$STAMP.log" 2>&1 &
RECORDER=$!
sleep "$LEAD_IN"
open -g "$APP" --args "$@"
wait "$RECORDER" || { cat "build/traces/xctrace-$STAMP.log" >&2; quit_app; exit 1; }
quit_app

xcrun xctrace export --input "$TRACE" \
    --xpath '/trace-toc/run[@number="1"]/data/table[@schema="time-profile"]' --output "$EXPORT" >/dev/null
python3 Scripts/analyze-trace.py "$EXPORT" "$NAME"
rm -f "$EXPORT"
echo
echo "trace: $TRACE"
