#!/bin/bash
# Prints the process ids of running copies of the app other than the one at the given path.
#
# Usage: Scripts/other-copies.sh <path to an app's binary: …/Name.app/Contents/MacOS/Name>
#
# By what is actually running, not by searching command lines for the app's path: a search
# also finds any shell command that merely mentions the path (it once found the very command
# that was running the check, and reported the app as open).
#
# A copy is recognised by its bundle identifier, not by its name: the app has been renamed,
# and a copy built before that is still the same app to itself (it shares the library, and a
# second copy steps aside for it). Looking for the name alone missed such a copy once, and
# the launch check then failed on an app that had quit as it should. If the given binary's
# bundle cannot be read (the path need not exist), copies are matched by the binary's name.
set -euo pipefail
OWN="${1:?usage: other-copies.sh <app binary>}"
NAME="$(basename "$OWN")"

identifier() {
    [[ -f "$1/Contents/Info.plist" ]] || return 0
    /usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$1/Contents/Info.plist" 2>/dev/null || true
}

OWN_ID="$(identifier "${OWN%/Contents/MacOS/*}")"

ps -axo pid=,comm= | while read -r pid path; do
    [[ "$path" == *.app/Contents/MacOS/* && "$path" != "$OWN" ]] || continue
    # Only the app's own binary, not a helper inside a bundle nested in it.
    bundle="${path%/Contents/MacOS/*}"
    [[ "$bundle" != *.app/*.app ]] || continue
    if [[ -n "$OWN_ID" ]]; then
        [[ "$(identifier "$bundle")" == "$OWN_ID" ]] && echo "$pid"
    elif [[ "$(basename "$path")" == "$NAME" ]]; then
        echo "$pid"
    fi
done
