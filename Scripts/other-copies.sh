#!/bin/bash
# Prints the process ids of running copies of the app other than the one at the given path.
#
# Usage: Scripts/other-copies.sh <path to an app's binary: …/Name.app/Contents/MacOS/Name>
#
# By what is actually running, not by searching command lines for the app's path: a search
# also finds any shell command that merely mentions the path (it once found the very command
# that was running the check, and reported the app as open).
set -euo pipefail
OWN="${1:?usage: other-copies.sh <app binary>}"
SUFFIX="/Contents/MacOS/$(basename "$OWN")"
ps -axo pid=,comm= | awk -v suffix="$SUFFIX" -v own="$OWN" '{
    pid = $1
    sub(/^[ \t]*[0-9]+[ \t]+/, "")
    if (length($0) >= length(suffix) && substr($0, length($0) - length(suffix) + 1) == suffix && $0 != own) print pid
}'
