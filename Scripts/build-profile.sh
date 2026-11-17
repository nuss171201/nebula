#!/bin/bash
# Builds the "profile" app: the Debug configuration (so the launch arguments that open a
# given state are there) compiled with optimisation, into its own folder. Measurements of the
# app's own code taken on the plain Debug build are pessimistic; Release has no launch arguments.
#
# Usage: Scripts/build-profile.sh        then  PROFILE_BUILD=1 Scripts/measure-playback.sh …
set -euo pipefail

cd "$(dirname "$0")/.."
[[ -d MediaCenter.xcodeproj ]] || xcodegen generate >/dev/null
mkdir -p build/logs
LOG=build/logs/build-profile.log
if ! xcodebuild -project MediaCenter.xcodeproj -scheme MediaCenter -configuration Debug \
    -derivedDataPath build/DerivedData-Profile -destination 'platform=macOS,arch=arm64' \
    SWIFT_OPTIMIZATION_LEVEL=-O GCC_OPTIMIZATION_LEVEL=s SWIFT_COMPILATION_MODE=wholemodule ENABLE_TESTABILITY=NO \
    build >"$LOG" 2>&1; then
    grep -E '(error:|\*\* .* FAILED \*\*)' "$LOG" | head -20 >&2
    echo "profile build failed (full log: $LOG)" >&2
    exit 1
fi
find build/DerivedData-Profile/Build/Products/Debug -maxdepth 1 -name '*.app' | head -1
