#!/bin/bash
# Builds Packages/PlayerKit/Vendor/Libmpv.xcframework: a *dynamic* framework containing
# libmpv, FFmpeg and their dependencies, exporting only libmpv's public C API.
#
# Why dynamic: the prebuilt libraries (MPVKit, LGPL build) are static archives. Linking
# them straight into the app would statically link LGPL code. Linking them into their own
# framework keeps the app's code separate and lets a user replace the framework, which is
# what the LGPL asks for. The app only ever sees Libmpv.framework, so the libraries can
# later come from a from-source build without touching player code.
#
# Inputs:  Config/mpv-libraries.lock (name, sha256, url); downloads are verified.
# Cache:   Vendor/cache/ (git-ignored). Delete it to force fresh downloads.
# Usage:   Scripts/build-mpv-framework.sh [--force]
set -euo pipefail
shopt -s nullglob

cd "$(dirname "$0")/.."
ROOT="$(pwd)"
LOCK="$ROOT/Config/mpv-libraries.lock"
CACHE="$ROOT/Vendor/cache"
WORK="$ROOT/Vendor/work"
OUTPUT_DIR="$ROOT/Packages/PlayerKit/Vendor"
NAME="Libmpv"
OUTPUT="$OUTPUT_DIR/$NAME.xcframework"
STAMP="$OUTPUT/lock.sha256"
DEPLOYMENT_TARGET="14.0"
ARCHS=(arm64 x86_64)

LOCK_HASH="$(shasum -a 256 "$LOCK" "$0" | shasum -a 256 | cut -d' ' -f1)"
if [[ "${1:-}" != "--force" && -f "$STAMP" && "$(cat "$STAMP")" == "$LOCK_HASH" ]]; then
    echo "$NAME.xcframework is up to date."
    exit 0
fi

fail() { echo "error: $1" >&2; exit 1; }

mkdir -p "$CACHE"
rm -rf "$WORK"
mkdir -p "$WORK/extracted" "$WORK/link"

# --- 1. Download, verify, extract the macOS slice of each library ----------------------
LIBS=()
MPV_ARCHIVE=""
MPV_HEADERS=""
while read -r name sha url; do
    [[ -z "$name" || "$name" == \#* ]] && continue
    zip="$CACHE/$name-${sha:0:12}.zip"
    if [[ ! -f "$zip" ]] || [[ "$(shasum -a 256 "$zip" | cut -d' ' -f1)" != "$sha" ]]; then
        echo "downloading $name"
        curl --fail --silent --show-error --location --max-time 600 -o "$zip.part" "$url"
        actual="$(shasum -a 256 "$zip.part" | cut -d' ' -f1)"
        [[ "$actual" == "$sha" ]] || { rm -f "$zip.part"; fail "$name: checksum mismatch (got $actual)"; }
        mv "$zip.part" "$zip"
    fi
    unzip -q -o "$zip" "*/macos-*" -d "$WORK/extracted/$name"

    slices=("$WORK/extracted/$name"/*.xcframework/macos-*)
    [[ ${#slices[@]} -eq 1 ]] || fail "$name: expected one macOS slice, found ${#slices[@]}"
    slice="${slices[0]}"
    archive=""
    for candidate in "$slice/$name.framework/$name" "$slice/$name.framework/Versions/A/$name" "$slice"/*.a; do
        [[ -f "$candidate" ]] && { archive="$candidate"; break; }
    done
    [[ -n "$archive" ]] || fail "$name: no static library in $slice"
    file -b "$archive" | grep -q "ar archive" || fail "$name: $archive is not a static archive"

    if [[ "$name" == "Libmpv" ]]; then
        MPV_ARCHIVE="$archive"
        MPV_HEADERS="$slice/$name.framework/Headers/mpv"
    else
        LIBS+=("$archive")
    fi
done <"$LOCK"
[[ -n "$MPV_ARCHIVE" && -d "$MPV_HEADERS" ]] || fail "Libmpv is missing from $LOCK"
echo "static libraries: $((${#LIBS[@]} + 1))"

# --- 2. Decide what to export: exactly the functions in libmpv's public headers ---------
grep -ohE '\bmpv_[a-z0-9_]+\(' "$MPV_HEADERS"/*.h | tr -d '(' | sort -u | sed 's/^/_/' >"$WORK/link/declared.txt"
nm -arch arm64 -gU "$MPV_ARCHIVE" 2>/dev/null | awk '{print $3}' | sort -u >"$WORK/link/defined.txt"
comm -12 "$WORK/link/declared.txt" "$WORK/link/defined.txt" >"$WORK/link/exports.txt"
EXPORT_COUNT="$(wc -l <"$WORK/link/exports.txt" | tr -d ' ')"
[[ "$EXPORT_COUNT" -ge 40 ]] || fail "only $EXPORT_COUNT libmpv functions found to export"

# --- 3. Link one dynamic library per architecture ----------------------------------------
SYSTEM_FRAMEWORKS=(
    AVFoundation AudioToolbox AudioUnit CoreAudio CoreFoundation CoreGraphics CoreMedia CoreVideo CoreText
    CoreImage Cocoa AppKit Foundation IOKit IOSurface Metal QuartzCore VideoToolbox OpenGL Security
    SystemConfiguration MediaPlayer Carbon UniformTypeIdentifiers Accelerate
)
FRAMEWORK_FLAGS=()
for framework in "${SYSTEM_FRAMEWORKS[@]}"; do
    FRAMEWORK_FLAGS+=(-framework "$framework")
done
# mpv's macOS backend contains Swift, so the Swift runtime search paths are needed.
SWIFT_LIBS="$(dirname "$(xcrun -f swiftc)")/../lib/swift/macosx"
SDK="$(xcrun --sdk macosx --show-sdk-path)"

SLICES=()
for arch in "${ARCHS[@]}"; do
    echo "linking $arch"
    out="$WORK/link/$NAME-$arch"
    if ! xcrun clang++ -dynamiclib -arch "$arch" -isysroot "$SDK" -mmacosx-version-min="$DEPLOYMENT_TARGET" \
        -o "$out" -L "$SWIFT_LIBS" -L "$SDK/usr/lib/swift" -Wl,-rpath,/usr/lib/swift \
        -Wl,-force_load,"$MPV_ARCHIVE" "${LIBS[@]}" "${FRAMEWORK_FLAGS[@]}" \
        -lbz2 -liconv -lexpat -lresolv -lxml2 -lz \
        -Wl,-exported_symbols_list,"$WORK/link/exports.txt" -Wl,-dead_strip \
        -install_name "@rpath/$NAME.framework/Versions/A/$NAME" >"$WORK/link/$arch.log" 2>&1; then
        grep -vE '^ld: warning: (object file|building for)' "$WORK/link/$arch.log" | head -40 >&2
        fail "linking $arch failed (full log: $WORK/link/$arch.log)"
    fi
    SLICES+=("$out")
done

# --- 4. Assemble the framework and the xcframework ----------------------------------------
FRAMEWORK="$WORK/$NAME.framework"
VERSION_DIR="$FRAMEWORK/Versions/A"
mkdir -p "$VERSION_DIR/Headers/mpv" "$VERSION_DIR/Modules" "$VERSION_DIR/Resources"
lipo -create "${SLICES[@]}" -output "$VERSION_DIR/$NAME"
cp "$MPV_HEADERS"/*.h "$VERSION_DIR/Headers/mpv/"
cat >"$VERSION_DIR/Headers/$NAME.h" <<'EOF'
// Umbrella header for the dynamic libmpv framework. The mpv client API headers are ISC-licensed.
#include "mpv/client.h"
#include "mpv/render.h"
#include "mpv/render_gl.h"
#include "mpv/stream_cb.h"
EOF
cat >"$VERSION_DIR/Modules/module.modulemap" <<EOF
framework module $NAME {
    umbrella header "$NAME.h"
    export *
}
EOF
MPV_VERSION="$(grep -m1 -oE 'mpv [0-9]+\.[0-9]+\.[0-9]+' "$LOCK" | cut -d' ' -f2 || true)"
cat >"$VERSION_DIR/Resources/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleExecutable</key>
	<string>$NAME</string>
	<key>CFBundleIdentifier</key>
	<string>io.mpv.libmpv</string>
	<key>CFBundleInfoDictionaryVersion</key>
	<string>6.0</string>
	<key>CFBundleName</key>
	<string>$NAME</string>
	<key>CFBundlePackageType</key>
	<string>FMWK</string>
	<key>CFBundleShortVersionString</key>
	<string>${MPV_VERSION:-0.0.0}</string>
	<key>CFBundleVersion</key>
	<string>1</string>
	<key>LSMinimumSystemVersion</key>
	<string>$DEPLOYMENT_TARGET</string>
</dict>
</plist>
EOF
# What the framework was built from, for the licence notices and for anyone relinking it.
{
    echo "Libmpv.framework: a dynamic build of libmpv and its dependencies (LGPL build)."
    echo "Built by Scripts/build-mpv-framework.sh from these prebuilt static libraries:"
    echo
    grep -v '^#' "$LOCK" | awk '{print $1 "  " $3}'
} >"$VERSION_DIR/Resources/COMPONENTS.txt"

(cd "$FRAMEWORK/Versions" && ln -s A Current)
(cd "$FRAMEWORK" && for item in "$NAME" Headers Modules Resources; do ln -s "Versions/Current/$item" "$item"; done)
codesign --force --sign - "$FRAMEWORK" >/dev/null 2>&1 || fail "ad-hoc signing failed"

mkdir -p "$OUTPUT_DIR"
rm -rf "$OUTPUT"
xcodebuild -create-xcframework -framework "$FRAMEWORK" -output "$OUTPUT" >/dev/null
echo "$LOCK_HASH" >"$STAMP"
rm -rf "$WORK"

BINARY="$(find "$OUTPUT" -type f -name "$NAME" | head -1)"
echo "built $OUTPUT"
echo "  architectures: $(lipo -archs "$BINARY")"
echo "  exported libmpv functions: $EXPORT_COUNT"
echo "  size: $(du -sh "$OUTPUT" | cut -f1)"
