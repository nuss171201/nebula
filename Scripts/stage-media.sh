#!/bin/bash
# Prints a path to give the app instead of <path>: a copy outside the folders macOS guards.
#
# Usage: Scripts/stage-media.sh <path-or-url>
#
# Why: this repository lives in ~/Documents. When the app (not the test runner) opens a
# file there, macOS asks the user "Orbit would like to access files in your Documents
# folder" and playback waits for the answer. Local builds are ad-hoc signed, so every
# rebuild is a "new app" and the question comes back. Checks must never put that dialog
# on the user's screen, so they play a copy from the temporary folder instead.
# URLs and paths that are not in a guarded folder are printed unchanged.
set -euo pipefail

INPUT="${1:?usage: stage-media.sh <path-or-url>}"
case "$INPUT" in
    http://* | https://*) echo "$INPUT"; exit 0 ;;
esac
[[ -f "$INPUT" ]] || { echo "$INPUT"; exit 0; }

ABSOLUTE="$(cd "$(dirname "$INPUT")" && pwd -P)/$(basename "$INPUT")"
case "$ABSOLUTE" in
    "$HOME/Documents/"* | "$HOME/Desktop/"* | "$HOME/Downloads/"*) ;;
    *) echo "$ABSOLUTE"; exit 0 ;;
esac

TEMPORARY="${TMPDIR:-/tmp}"
STAGE="${TEMPORARY%/}/orbit-staged-media"
mkdir -p "$STAGE"
TARGET="$STAGE/$(basename "$ABSOLUTE")"
if [[ ! -f "$TARGET" || "$ABSOLUTE" -nt "$TARGET" ]]; then
    cp -f "$ABSOLUTE" "$TARGET"
fi
echo "$TARGET"
