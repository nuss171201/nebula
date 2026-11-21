#!/bin/bash
# Runs a watch party between two copies of the Debug app on this machine, without taking focus:
# starts the signalling server on the loopback interface, starts a host and a guest with scratch
# profiles playing the same file, saves a screenshot of each one's windows, prints where each
# player was at the same moment, and quits everything.
#
# Nothing leaves this machine: the invitation names a server on 127.0.0.1, which keeps the
# party's connections on the loopback interface, and both apps are silent (no sound, no microphone).
#
# Usage: Scripts/party-check.sh <output-folder> [seconds-to-wait]
#   Scripts/party-check.sh /tmp/party 14
#   GUEST_ARGS="-partySay hello" HOST_ARGS="-keys ' '" Scripts/party-check.sh /tmp/party 14
# Needs: a Debug build (Scripts/ci.sh), deno, TestMedia/long-low-res.mp4.
set -euo pipefail

cd "$(dirname "$0")/.."
OUTPUT="${1:?usage: party-check.sh <output-folder> [seconds]}"
WAIT="${2:-14}"
mkdir -p "$OUTPUT"

fail() { echo "error: $1" >&2; exit 1; }
command -v deno >/dev/null 2>&1 || fail "'deno' is not installed (brew install deno)"
PRODUCTS="build/DerivedData${PROFILE_BUILD:+-Profile}/Build/Products/Debug"
APP="$(find "$PRODUCTS" -maxdepth 1 -name '*.app' 2>/dev/null | head -1)"
[[ -d "$APP" ]] || fail "no Debug build found; run Scripts/ci.sh first"
APP="$(cd "$APP" && pwd)"
BINARY="$APP/Contents/MacOS/$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$APP/Contents/Info.plist")"
BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Contents/Info.plist")"
MEDIA="$(Scripts/stage-media.sh TestMedia/long-low-res.mp4)"
[[ -f "$MEDIA" ]] || fail "TestMedia/long-low-res.mp4 is missing; run Scripts/make-test-media.sh"

SCRATCH="${TMPDIR:-/tmp}"
SCRATCH="${SCRATCH%/}/orbit-party-check"
rm -rf "$SCRATCH"
mkdir -p "$SCRATCH/host" "$SCRATCH/guest"
PORT=$((20000 + RANDOM % 30000))
SERVER_PID=""

cleanup() {
    pkill -f "$BINARY" 2>/dev/null || true
    [[ -n "$SERVER_PID" ]] && kill "$SERVER_PID" 2>/dev/null || true
    while pgrep -f "$BINARY" >/dev/null 2>&1; do sleep 0.2; done
}
pkill -f "$BINARY" 2>/dev/null || true
trap cleanup EXIT

HOST=127.0.0.1 PORT="$PORT" ICE_SERVERS='[]' DENO_NO_UPDATE_CHECK=1 \
    deno run --no-prompt "--allow-net=127.0.0.1:$PORT" --allow-env Server/signal.ts >"$OUTPUT/server.log" 2>&1 &
SERVER_PID=$!
for _ in $(seq 1 50); do
    curl -fs "http://127.0.0.1:$PORT/healthz" >/dev/null 2>&1 && break
    sleep 0.1
done
curl -fs "http://127.0.0.1:$PORT/healthz" >/dev/null || fail "the signalling server did not start (see $OUTPUT/server.log)"

CODE="$(head -c 16 /dev/urandom | base64 | tr '+/' '-_' | tr -d '=')"
LINK="http://127.0.0.1:$PORT/#$CODE"
# Both apps say where their player is at the same moment on the wall clock.
REPORT_AT=$(($(date +%s) + WAIT - 1))

# shellcheck disable=SC2086
open -g -n "$APP" --args -silent YES -profile "$SCRATCH/host" -partyHost "$LINK" -partyName Asha \
    -partyReportAt "$REPORT_AT" -play "$MEDIA" -panel party ${HOST_ARGS:-}
sleep 3
# shellcheck disable=SC2086
open -g -n "$APP" --args -silent YES -profile "$SCRATCH/guest" -partyJoin "$LINK" -partyName Ravi \
    -partyReportAt "$REPORT_AT" -play "$MEDIA" -panel party -partySay "hello from the other Mac" ${GUEST_ARGS:-}

sleep "$WAIT"

capture() {
    local role="$1" pid index=1
    pid="$(pgrep -f -- "-party$2 $LINK" | head -1 || true)"
    [[ -n "$pid" ]] || { echo "the $role is not running" >&2; return; }
    swift Scripts/window-id.swift "$pid" | while read -r window size; do
        target="$OUTPUT/$role.png"
        [[ "$index" -gt 1 ]] && target="$OUTPUT/$role-$index.png"
        screencapture -x -o -l "$window" "$target" 2>/dev/null && echo "saved $target ($size)"
        index=$((index + 1))
    done
}
capture host Host
capture guest Join

echo
echo "Where each player was at the same moment:"
/usr/bin/log show --last "$((WAIT + 20))s" --style compact \
    --predicate "subsystem == \"$BUNDLE_ID\" AND category == \"party\" AND eventMessage CONTAINS \"party-report\"" 2>/dev/null \
    | grep -o 'party-report.*' || echo "(no report in the log)"
ls ~/Library/Logs/DiagnosticReports 2>/dev/null | grep -i "$(basename "$BINARY")" | tail -3 || true
