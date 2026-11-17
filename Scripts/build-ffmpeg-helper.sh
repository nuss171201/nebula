#!/bin/bash
# Builds Vendor/Helpers/ffmpeg: a small universal `ffmpeg` program that the app carries for one
# job, converting an audio track the player cannot play directly into AAC (AudioTranscoder).
#
# From FFmpeg's source, so that what goes into it is ours to decide:
#   - LGPL only: no --enable-gpl, no --enable-version3, no --enable-nonfree (checked below).
#   - No external libraries but the system's zlib and Secure Transport (for https).
#   - Only what the job needs: every demuxer and parser, the audio decoders, the AAC encoder,
#     the Matroska muxer, the audio filters a conversion uses, and file/http/https input.
#     No video decoders, no devices, no other programs.
#
# The Intel half is built without hand-written assembly unless `nasm` is installed: slower,
# which does not matter for converting sound.
#
# Inputs:  Config/ffmpeg-helper.lock (sha256, url); the download is verified.
# Cache:   Vendor/cache/, Vendor/work/ffmpeg-helper/ (git-ignored).
# Usage:   Scripts/build-ffmpeg-helper.sh [--force]
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd)"
LOCK="$ROOT/Config/ffmpeg-helper.lock"
CACHE="$ROOT/Vendor/cache"
WORK="$ROOT/Vendor/work/ffmpeg-helper"
OUTPUT_DIR="$ROOT/Vendor/Helpers"
OUTPUT="$OUTPUT_DIR/ffmpeg"
STAMP="$OUTPUT_DIR/ffmpeg.lock.sha256"
DEPLOYMENT_TARGET="14.0"
ARCHS=(arm64 x86_64)

fail() { echo "error: $1" >&2; exit 1; }

LOCK_HASH="$(shasum -a 256 "$LOCK" "$0" | shasum -a 256 | cut -d' ' -f1)"
if [[ "${1:-}" != "--force" && -x "$OUTPUT" && -f "$STAMP" && "$(cat "$STAMP")" == "$LOCK_HASH" ]]; then
    echo "The ffmpeg helper is up to date."
    exit 0
fi

read -r _ SHA URL <<<"$(grep -E '^ffmpeg ' "$LOCK" || fail "ffmpeg is not in $(basename "$LOCK")")"
ARCHIVE="$CACHE/ffmpeg-source-${SHA:0:12}.tar.xz"
mkdir -p "$CACHE"
if [[ ! -f "$ARCHIVE" ]] || [[ "$(shasum -a 256 "$ARCHIVE" | cut -d' ' -f1)" != "$SHA" ]]; then
    echo "downloading the FFmpeg source"
    curl --fail --silent --show-error --location --max-time 900 -o "$ARCHIVE.part" "$URL"
    [[ "$(shasum -a 256 "$ARCHIVE.part" | cut -d' ' -f1)" == "$SHA" ]] \
        || { rm -f "$ARCHIVE.part"; fail "the FFmpeg source does not match the hash in $(basename "$LOCK")"; }
    mv "$ARCHIVE.part" "$ARCHIVE"
fi

rm -rf "$WORK"
mkdir -p "$WORK/source" "$OUTPUT_DIR"
tar -xJf "$ARCHIVE" -C "$WORK/source" --strip-components 1

# The audio decoders, read from the source's own list: everything between its "audio codecs"
# heading and its "subtitles" heading (audio, PCM, DPCM and ADPCM), which is before the
# decoders that need external libraries.
DECODERS="$(awk '
    /\/\* audio codecs \*\// { on = 1 }
    /\/\* subtitles \*\// { on = 0 }
    on && match($0, /ff_[a-z0-9_]+_decoder/) { name = substr($0, RSTART + 3, RLENGTH - 11); print name }
' "$WORK/source/libavcodec/allcodecs.c" | sort -u | paste -sd, -)"
[[ "$(tr ',' '\n' <<<"$DECODERS" | wc -l)" -gt 100 ]] || fail "could not read the list of audio decoders from the source"
for required in aac ac3 eac3 dca truehd mlp flac opus vorbis mp3 pcm_s16le; do
    [[ ",$DECODERS," == *",$required,"* ]] || fail "the audio decoder list is missing $required"
done

HOST_ARCH="$(uname -m)"
BUILT=()
for arch in "${ARCHS[@]}"; do
    echo "==> ffmpeg helper, $arch"
    build="$WORK/build-$arch"
    mkdir -p "$build"
    flags=(
        --disable-autodetect --enable-zlib --enable-securetransport
        --disable-doc --disable-debug --disable-ffplay --disable-ffprobe
        --disable-avdevice --disable-swscale
        --disable-shared --enable-static
        --disable-everything
        --enable-demuxers --enable-parsers --enable-bsfs
        "--enable-decoder=$DECODERS"
        --enable-encoder=aac
        --enable-muxer=matroska
        --enable-filter=abuffer,abuffersink,aformat,anull,aresample,atrim,asetpts
        --enable-protocol=file,http,https,tcp,tls,crypto
        "--arch=$arch" --target-os=darwin
        "--cc=clang -arch $arch"
        "--extra-cflags=-mmacosx-version-min=$DEPLOYMENT_TARGET"
        "--extra-ldflags=-mmacosx-version-min=$DEPLOYMENT_TARGET"
    )
    if [[ "$arch" != "$HOST_ARCH" ]]; then
        flags+=(--enable-cross-compile)
    fi
    if [[ "$arch" == "x86_64" ]] && ! command -v nasm >/dev/null 2>&1; then
        flags+=(--disable-x86asm)
    fi
    (cd "$build" && "$WORK/source/configure" "${flags[@]}" >configure.log 2>&1) \
        || { tail -20 "$build/configure.log" >&2; fail "configure failed for $arch (see $build/configure.log)"; }
    # The licence this configuration comes under, as FFmpeg itself works it out.
    grep -q '^#define CONFIG_GPL 0' "$build/config.h" || fail "$arch: this configuration is GPL"
    grep -q '^#define CONFIG_VERSION3 0' "$build/config.h" || fail "$arch: this configuration is (L)GPL version 3"
    grep -q '^#define CONFIG_NONFREE 0' "$build/config.h" || fail "$arch: this configuration is not redistributable"
    grep -q '^#define FFMPEG_LICENSE "LGPL version 2.1 or later"' "$build/config.h" || fail "$arch: unexpected licence in config.h"
    (cd "$build" && make -j"$(sysctl -n hw.ncpu)" ffmpeg >make.log 2>&1) \
        || { tail -30 "$build/make.log" >&2; fail "the build failed for $arch (see $build/make.log)"; }
    BUILT+=("$build/ffmpeg")
done

lipo -create "${BUILT[@]}" -output "$OUTPUT.new"
strip -x "$OUTPUT.new"
ARCHS_BUILT="$(lipo -archs "$OUTPUT.new")"
[[ "$ARCHS_BUILT" == *arm64* && "$ARCHS_BUILT" == *x86_64* ]] || fail "the helper is not universal ($ARCHS_BUILT)"
# Nothing but system libraries: it must run on a Mac that has nothing installed.
if otool -L "$OUTPUT.new" | grep -vE '^\S|/usr/lib/|/System/Library/' | grep -q .; then
    otool -L "$OUTPUT.new" >&2
    fail "the helper links against something outside the system"
fi
# And it says what it is.
LICENSE_SAYS="$("$OUTPUT.new" -hide_banner -L 2>&1 | tr -s '[:space:]' ' ')"
[[ "$LICENSE_SAYS" == *"GNU Lesser General Public License"*"version 2.1 of the License, or (at your option) any later version"* ]] \
    || fail "the helper does not report itself as LGPL 2.1 or later"
mv "$OUTPUT.new" "$OUTPUT"
codesign --force --sign - "$OUTPUT" 2>/dev/null
echo "$LOCK_HASH" >"$STAMP"
echo "Built $OUTPUT ($(du -h "$OUTPUT" | cut -f1 | tr -d ' '), $ARCHS_BUILT)."
