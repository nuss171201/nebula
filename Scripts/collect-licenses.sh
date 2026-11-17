#!/bin/bash
# Collects the licence texts of the third-party code the app ships into Vendor/Licenses/,
# which the app bundles as Resources/Licenses and shows in its Acknowledgements window.
#
# Inputs:  Config/licenses.lock (file name, sha256, url); downloads are verified.
#          Packages/StreamEngine/Vendor/Libtorrent.xcframework/Licenses (libtorrent, Boost),
#          written by Scripts/build-torrent-framework.sh from the source archives.
# Cache:   Vendor/cache/licenses/ (git-ignored).
# Usage:   Scripts/collect-licenses.sh [--force]
set -euo pipefail

cd "$(dirname "$0")/.."
LOCK="Config/licenses.lock"
CACHE="Vendor/cache/licenses"
OUTPUT="Vendor/Licenses"
# Beside the folder, not in it: the folder is copied into the app as it is.
STAMP="Vendor/Licenses.lock.sha256"
TORRENT_LICENSES="Packages/StreamEngine/Vendor/Libtorrent.xcframework/Licenses"

fail() { echo "error: $1" >&2; exit 1; }

[[ -d "$TORRENT_LICENSES" ]] || fail "run Scripts/build-torrent-framework.sh first: $TORRENT_LICENSES is missing"
LOCK_HASH="$(cat "$LOCK" "$0" "$TORRENT_LICENSES"/* | shasum -a 256 | cut -d' ' -f1)"
if [[ "${1:-}" != "--force" && -f "$STAMP" && "$(cat "$STAMP")" == "$LOCK_HASH" ]]; then
    echo "Licences are up to date."
    exit 0
fi

mkdir -p "$CACHE"
rm -rf "$OUTPUT"
mkdir -p "$OUTPUT"
while read -r name sha url; do
    [[ -z "$name" || "$name" == \#* ]] && continue
    cached="$CACHE/${sha:0:12}-$name"
    if [[ ! -f "$cached" ]] || [[ "$(shasum -a 256 "$cached" | cut -d' ' -f1)" != "$sha" ]]; then
        echo "downloading $name"
        curl --fail --silent --show-error --location --max-time 120 -o "$cached.part" "$url"
        [[ "$(shasum -a 256 "$cached.part" | cut -d' ' -f1)" == "$sha" ]] \
            || { rm -f "$cached.part"; fail "$name does not match the hash in $LOCK"; }
        mv "$cached.part" "$cached"
    fi
    cp "$cached" "$OUTPUT/$name"
done <"$LOCK"
cp "$TORRENT_LICENSES"/*.txt "$OUTPUT/"

# Every file the app's list of components names must be here, and nothing may be left unlisted.
python3 - "$OUTPUT" Config/ThirdParty.json <<'PY'
import json, os, sys
folder, catalog = sys.argv[1], sys.argv[2]
listed = {name for group in json.load(open(catalog))["groups"] for part in group["components"] for name in part["files"]}
present = {name for name in os.listdir(folder) if not name.startswith(".")}
problems = [f"listed but not collected: {name}" for name in sorted(listed - present)]
problems += [f"collected but not listed: {name}" for name in sorted(present - listed)]
if problems:
    sys.exit("error: Config/ThirdParty.json and the licence files disagree:\n  " + "\n  ".join(problems))
PY
echo "$LOCK_HASH" >"$STAMP"
echo "Collected $(find "$OUTPUT" -type f ! -name '.*' | wc -l | tr -d ' ') licence files in $OUTPUT."
