#!/bin/bash
# Builds Packages/StreamEngine/Vendor/Libtorrent.xcframework: libtorrent-rasterbar built
# from source as one static, universal (arm64 + x86_64) library with OpenSSL inside it,
# plus the headers the bridge needs (libtorrent's, and the parts of Boost and OpenSSL
# they include).
#
# Why static: libtorrent (BSD), Boost (BSL) and OpenSSL (Apache-2.0) all allow it, and a
# static library is stripped down to what the bridge uses when the app is linked.
# Their licence texts are copied into the framework; the app must ship them (Stage 9).
#
# Inputs:  Config/torrent-libraries.lock, and the Libssl / Libcrypto lines of
#          Config/mpv-libraries.lock. Every download is checked against its sha256.
# Needs:   cmake and ninja (brew install cmake ninja).
# Cache:   Vendor/cache/ (git-ignored). Delete it to force fresh downloads.
# Usage:   Scripts/build-torrent-framework.sh [--force]
#          REUSE_BUILD=1 Scripts/build-torrent-framework.sh --force   keeps the compiled
#          libraries of a run that failed later on (the compile is the slow part).
set -euo pipefail
shopt -s nullglob

cd "$(dirname "$0")/.."
ROOT="$(pwd)"
LOCK="$ROOT/Config/torrent-libraries.lock"
MPV_LOCK="$ROOT/Config/mpv-libraries.lock"
CACHE="$ROOT/Vendor/cache"
WORK="$ROOT/Vendor/torrent-work"
OUTPUT_DIR="$ROOT/Packages/StreamEngine/Vendor"
NAME="Libtorrent"
OUTPUT="$OUTPUT_DIR/$NAME.xcframework"
STAMP="$OUTPUT/lock.sha256"
DEPLOYMENT_TARGET="14.0"
ARCHS=(arm64 x86_64)
# What libtorrent's build defines for everything that includes its headers. The bridge
# must be compiled with the same ones (Packages/StreamEngine/Package.swift); libtorrent
# checks at link time that they agree.
PUBLIC_DEFINES=(
    BOOST_ASIO_ENABLE_CANCELIO BOOST_ASIO_NO_DEPRECATED
    # From deprecated-functions=OFF. It also selects the library's ABI namespace, so leaving
    # it out of the bridge shows up as undefined symbols at link time.
    TORRENT_NO_DEPRECATE
    TORRENT_USE_OPENSSL TORRENT_USE_LIBCRYPTO TORRENT_SSL_PEERS
    OPENSSL_NO_SSL2 OPENSSL_NO_SSL3 OPENSSL_NO_TLS1 OPENSSL_NO_TLS1_1 OPENSSL_NO_DTLS1
)

# Of the contents only: file names (and how the script was called) must not matter.
LOCK_HASH="$({ cat "$LOCK" "$ROOT/Scripts/build-torrent-framework.sh"; grep -E '^(Libssl|Libcrypto) ' "$MPV_LOCK"; } | shasum -a 256 | cut -d' ' -f1)"
if [[ "${1:-}" != "--force" && -f "$STAMP" && "$(cat "$STAMP")" == "$LOCK_HASH" ]]; then
    echo "$NAME.xcframework is up to date."
    exit 0
fi

fail() { echo "error: $1" >&2; exit 1; }
command -v cmake >/dev/null 2>&1 || fail "cmake is not installed (brew install cmake ninja)"
command -v ninja >/dev/null 2>&1 || fail "ninja is not installed (brew install cmake ninja)"

mkdir -p "$CACHE"
REUSE=0
if [[ "${REUSE_BUILD:-0}" == "1" && -f "$WORK/build-arm64/combined.a" && -f "$WORK/build-x86_64/combined.a" ]]; then
    REUSE=1
    echo "reusing the libraries compiled by the previous run"
else
    rm -rf "$WORK"
    mkdir -p "$WORK"
fi

# Downloads <url> to the cache unless a copy with the right checksum is there; prints its path.
fetch() {
    local name="$1" sha="$2" url="$3"
    local file="$CACHE/$name-${sha:0:12}.${url##*.}"
    if [[ ! -f "$file" ]] || [[ "$(shasum -a 256 "$file" | cut -d' ' -f1)" != "$sha" ]]; then
        echo "downloading $name" >&2
        curl --fail --silent --show-error --location --max-time 900 -o "$file.part" "$url"
        local actual
        actual="$(shasum -a 256 "$file.part" | cut -d' ' -f1)"
        [[ "$actual" == "$sha" ]] || { rm -f "$file.part"; fail "$name: checksum mismatch (got $actual)"; }
        mv "$file.part" "$file"
    fi
    echo "$file"
}

lock_line() { grep -E "^$2 " "$1" || fail "$2 is not in $(basename "$1")"; }

if [[ "$REUSE" == "0" ]]; then
    # --- 1. Sources ------------------------------------------------------------------------
    read -r _ sha url <<<"$(lock_line "$LOCK" libtorrent)"
    mkdir -p "$WORK/libtorrent"
    tar -xzf "$(fetch libtorrent "$sha" "$url")" -C "$WORK/libtorrent" --strip-components 1

    read -r _ sha url <<<"$(lock_line "$LOCK" boost)"
    mkdir -p "$WORK/boost"
    echo "unpacking Boost headers"
    # Only the headers and the licence: nothing of Boost is compiled.
    tar -xJf "$(fetch boost "$sha" "$url")" -C "$WORK/boost" --strip-components 1 '*/boost' '*/LICENSE_1_0.txt'
    [[ -f "$WORK/boost/boost/version.hpp" ]] || fail "Boost headers were not found in the archive"

    # --- 2. OpenSSL, as cmake expects to find it: include/ and lib/ under one root ---------
    mkdir -p "$WORK/openssl/include" "$WORK/openssl/lib" "$WORK/openssl/zip"
    for name in Libssl Libcrypto; do
        read -r _ sha url <<<"$(lock_line "$MPV_LOCK" "$name")"
        unzip -q -o "$(fetch "$name" "$sha" "$url")" "*/macos-*" -d "$WORK/openssl/zip/$name"
        frameworks=("$WORK/openssl/zip/$name"/*.xcframework/macos-*/"$name.framework")
        [[ ${#frameworks[@]} -eq 1 ]] || fail "$name: expected one macOS framework"
        archive="${frameworks[0]}/Versions/A/$name"
        [[ -f "$archive" ]] || archive="${frameworks[0]}/$name"
        file -b "$archive" | grep -q "ar archive" || fail "$name is not a static archive"
        lower="$(echo "${name#Lib}" | tr '[:upper:]' '[:lower:]')"
        cp "$archive" "$WORK/openssl/lib/lib$lower.a"
        if [[ -d "${frameworks[0]}/Headers/openssl" ]]; then
            cp -R "${frameworks[0]}/Headers/openssl" "$WORK/openssl/include/"
        fi
    done
    [[ -f "$WORK/openssl/include/openssl/ssl.h" ]] || fail "OpenSSL headers were not found"

    # --- 3. A description of Boost for cmake ------------------------------------------------
    # cmake no longer ships its own Boost finder, and header-only Boost has nothing installed
    # that describes it, so this says the little there is to say.
    mkdir -p "$WORK/boost-cmake"
    cat >"$WORK/boost-cmake/BoostConfig.cmake" <<CMAKE
set(Boost_FOUND TRUE)
set(Boost_VERSION 1.92.0)
set(Boost_MAJOR_VERSION 1)
set(Boost_MINOR_VERSION 92)
set(Boost_INCLUDE_DIRS "$WORK/boost")
if(NOT TARGET Boost::headers)
    add_library(Boost::headers INTERFACE IMPORTED)
    set_target_properties(Boost::headers PROPERTIES INTERFACE_INCLUDE_DIRECTORIES "$WORK/boost")
    add_library(Boost::boost INTERFACE IMPORTED)
    set_target_properties(Boost::boost PROPERTIES INTERFACE_LINK_LIBRARIES Boost::headers)
endif()
CMAKE

    # --- 4. Build libtorrent once per architecture -----------------------------------------
    for arch in "${ARCHS[@]}"; do
        echo "building libtorrent ($arch)"
        build="$WORK/build-$arch"
        cmake -G Ninja -S "$WORK/libtorrent" -B "$build" \
            -DCMAKE_BUILD_TYPE=Release \
            -DCMAKE_OSX_ARCHITECTURES="$arch" \
            -DCMAKE_OSX_DEPLOYMENT_TARGET="$DEPLOYMENT_TARGET" \
            -DCMAKE_CXX_STANDARD=17 \
            -DBUILD_SHARED_LIBS=OFF \
            -Ddeprecated-functions=OFF \
            -Dbuild_tests=OFF -Dbuild_examples=OFF -Dbuild_tools=OFF -Dpython-bindings=OFF \
            -DBoost_DIR="$WORK/boost-cmake" \
            -DOPENSSL_ROOT_DIR="$WORK/openssl" -DOPENSSL_USE_STATIC_LIBS=TRUE \
            >"$build.configure.log" 2>&1 || { tail -30 "$build.configure.log" >&2; fail "cmake failed for $arch"; }
        grep -q "TORRENT_USE_OPENSSL" "$build/build.ninja" || fail "libtorrent was configured without OpenSSL ($arch)"
        ninja -C "$build" torrent-rasterbar >"$build.build.log" 2>&1 || { tail -40 "$build.build.log" >&2; fail "build failed for $arch"; }
        archives=("$build"/libtorrent-rasterbar*.a)
        [[ ${#archives[@]} -eq 1 ]] || fail "no library was produced for $arch"
        # One archive per architecture holding libtorrent and the OpenSSL it needs.
        for part in ssl crypto; do
            lipo "$WORK/openssl/lib/lib$part.a" -thin "$arch" -output "$build/lib$part-$arch.a"
        done
        libtool -static -no_warning_for_no_symbols -o "$build/combined.a" "${archives[0]}" "$build/libssl-$arch.a" "$build/libcrypto-$arch.a" 2>/dev/null
    done
fi

SLICES=()
for arch in "${ARCHS[@]}"; do SLICES+=("$WORK/build-$arch/combined.a"); done
rm -rf "$WORK/product"
mkdir -p "$WORK/product"
lipo -create "${SLICES[@]}" -output "$WORK/product/libtorrent.a"

# --- 5. Headers: all of libtorrent's, and what they include from Boost and OpenSSL ------
echo "collecting headers"
HEADERS="$WORK/product/Headers"
mkdir -p "$HEADERS"
cp -R "$WORK/libtorrent/include/libtorrent" "$HEADERS/"
# Ask the compiler which files every public libtorrent header pulls in.
UMBRELLA="$WORK/umbrella.cpp"
(cd "$WORK/libtorrent/include" && for header in libtorrent/*.hpp libtorrent/extensions/*.hpp libtorrent/kademlia/*.hpp; do
    # Two headers exist only to tell users of older versions that they are gone.
    [[ "$header" == "libtorrent/io_service.hpp" || "$header" == "libtorrent/storage.hpp" ]] && continue
    echo "#include <$header>"
done) >"$UMBRELLA"
DEFINES=()
for define in "${PUBLIC_DEFINES[@]}"; do DEFINES+=("-D$define"); done
xcrun clang++ -std=c++17 -M "${DEFINES[@]}" \
    -I "$WORK/libtorrent/include" -I "$WORK/boost" -I "$WORK/openssl/include" "$UMBRELLA" \
    | tr ' \\' '\n\n' | grep -E "^$WORK/(boost|openssl/include)/" | sort -u >"$WORK/used-headers.txt" \
    || fail "could not work out which headers are needed"
while read -r header; do
    relative="${header#"$WORK/boost/"}"
    relative="${relative#"$WORK/openssl/include/"}"
    mkdir -p "$HEADERS/$(dirname "$relative")"
    cp "$header" "$HEADERS/$relative"
done <"$WORK/used-headers.txt"
[[ -f "$HEADERS/boost/asio/io_context.hpp" ]] || fail "the Boost headers were not collected"

# --- 6. Package --------------------------------------------------------------------------
rm -rf "$OUTPUT"
mkdir -p "$OUTPUT_DIR"
xcodebuild -create-xcframework -library "$WORK/product/libtorrent.a" -headers "$HEADERS" -output "$OUTPUT" >/dev/null
mkdir -p "$OUTPUT/Licenses"
cp "$WORK/libtorrent/LICENSE" "$OUTPUT/Licenses/libtorrent-LICENSE.txt"
cp "$WORK/boost/LICENSE_1_0.txt" "$OUTPUT/Licenses/Boost-LICENSE_1_0.txt"
printf '%s\n' "${PUBLIC_DEFINES[@]}" >"$OUTPUT/public-defines.txt"
echo "$LOCK_HASH" >"$STAMP"
rm -rf "$WORK"

BINARY="$(find "$OUTPUT" -name libtorrent.a | head -1)"
echo "built $OUTPUT"
echo "  architectures: $(lipo -archs "$BINARY")"
echo "  size:          $(du -sh "$BINARY" | cut -f1) library, $(find "$OUTPUT" -name '*.h*' | wc -l | tr -d ' ') headers"
