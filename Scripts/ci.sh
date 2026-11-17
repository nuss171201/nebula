#!/bin/bash
# The single gate for every stage: generate, lint, build with zero warnings, test.
#
# Usage:
#   Scripts/ci.sh            lint + Debug build + tests
#   Scripts/ci.sh --release  also build the universal Release configuration
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd)"
PROJECT="MediaCenter.xcodeproj"
SCHEME="MediaCenter"
DERIVED="$ROOT/build/DerivedData"
LOGS="$ROOT/build/logs"
BUILD_RELEASE=0
[[ "${1:-}" == "--release" ]] && BUILD_RELEASE=1

mkdir -p "$LOGS"

step() { printf '\n==> %s\n' "$1"; }
fail() { printf '\nFAILED: %s\n' "$1" >&2; exit 1; }

require() {
    command -v "$1" >/dev/null 2>&1 || fail "'$1' is not installed (brew install $1)"
}

# Compiler, linker and project-level warnings. Xcode's own tools print unrelated
# "warning:" chatter (DVTAssertions, appintentsmetadataprocessor); those are not ours.
count_warnings() {
    grep -E -c '(^/.*:[0-9]+:[0-9]+: warning:|^ld: warning:|^warning: )' "$1" || true
}

run_xcodebuild() {
    local log="$1"; shift
    if ! xcodebuild -project "$PROJECT" -scheme "$SCHEME" -derivedDataPath "$DERIVED" "$@" >"$log" 2>&1; then
        grep -E '(error:|warning:|\*\* .* FAILED \*\*|✘)' "$log" | head -40 >&2 || true
        fail "xcodebuild $* (full log: $log)"
    fi
    local warnings
    warnings="$(count_warnings "$log")"
    if [[ "$warnings" != "0" ]]; then
        grep -E '(^/.*:[0-9]+:[0-9]+: warning:|^ld: warning:|^warning: )' "$log" | sort -u | head -40 >&2
        fail "$warnings warning(s) in $log; the build must be warning-free"
    fi
}

require xcodegen
require swiftformat
require swiftlint
require ffmpeg

step "Prepare Libmpv.framework and test media"
Scripts/build-mpv-framework.sh
Scripts/make-test-media.sh >/dev/null

step "Generate Xcode project"
xcodegen generate --quiet

step "Format check (SwiftFormat)"
swiftformat --lint --quiet . || fail "formatting differs; run 'swiftformat .'"

step "Lint (SwiftLint, strict)"
swiftlint lint --strict --quiet || fail "SwiftLint reported violations"

step "Build Debug (warnings are errors)"
run_xcodebuild "$LOGS/build-debug.log" -configuration Debug -destination 'platform=macOS,arch=arm64' build

step "Test"
run_xcodebuild "$LOGS/test.log" -configuration Debug -destination 'platform=macOS,arch=arm64' test
grep -E '^✔ Test run with' "$LOGS/test.log" || fail "no test summary found in $LOGS/test.log"

if [[ "$BUILD_RELEASE" == "1" ]]; then
    step "Build Release (universal: arm64 + x86_64)"
    run_xcodebuild "$LOGS/build-release.log" -configuration Release -destination 'generic/platform=macOS' build
    APP="$(find "$DERIVED/Build/Products/Release" -maxdepth 1 -name '*.app' | head -1)"
    BINARY="$APP/Contents/MacOS/$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$APP/Contents/Info.plist")"
    ARCHS="$(lipo -archs "$BINARY")"
    echo "Release binary architectures: $ARCHS"
    [[ "$ARCHS" == *arm64* && "$ARCHS" == *x86_64* ]] || fail "Release binary is not universal ($ARCHS)"
fi

printf '\nCI passed.\n'
