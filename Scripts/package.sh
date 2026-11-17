#!/bin/bash
# Makes the app ready to hand out: a signed .app and a .dmg holding it, in build/dist/.
#
# Usage:
#   Scripts/package.sh              run Scripts/ci.sh --release first, then package what it built
#   Scripts/package.sh --skip-ci    package the Release build that is already there
#
# Signing (environment):
#   SIGN_IDENTITY    A signing identity from the keychain, such as
#                    "Developer ID Application: Your Name (TEAMID)". Without it the app is
#                    ad-hoc signed: it runs on this Mac, and on another Mac only after its
#                    owner allows it by hand (Gatekeeper does not know who made it).
#   NOTARY_PROFILE   The name of a keychain profile saved with
#                    `xcrun notarytool store-credentials`. With a Developer ID identity, the
#                    disk image is then sent to Apple for notarisation and the ticket stapled
#                    to it, which is what lets it open on other Macs without a warning.
#
# Nothing here makes or stores a credential: both come from the keychain, put there by you.
#
# What it does, in order: copies the Release app, strips local symbols (the dSYMs are kept in
# build/dist/dSYMs), signs every piece of code from the inside out with the hardened runtime,
# checks the result (signature, entitlements, both architectures, that it starts), builds the
# disk image, signs and notarises it when it can, and checks the image by mounting it.
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd)"
SKIP_CI=0
[[ "${1:-}" == "--skip-ci" ]] && SKIP_CI=1
IDENTITY="${SIGN_IDENTITY:--}"
NOTARY_PROFILE="${NOTARY_PROFILE:-}"
PRODUCTS="$ROOT/build/DerivedData/Build/Products/Release"
DIST="$ROOT/build/dist"

step() { printf '\n==> %s\n' "$1"; }
# Newer systems say on every call that hdiutil's verbs are being replaced by `diskutil image`,
# which older build machines do not have. The notice is dropped; real errors still show.
image_tool() { hdiutil "$@" 2> >(grep -v 'is deprecated' >&2); }
fail() { printf '\nFAILED: %s\n' "$1" >&2; exit 1; }
plist() { /usr/libexec/PlistBuddy -c "Print :$2" "$1/Contents/Info.plist" 2>/dev/null || true; }

if [[ "$SKIP_CI" == "0" ]]; then
    Scripts/ci.sh --release
fi
BUILT="$(find "$PRODUCTS" -maxdepth 1 -name '*.app' 2>/dev/null | head -1)"
[[ -d "$BUILT" ]] || fail "no Release build in $PRODUCTS (run Scripts/ci.sh --release)"

NAME="$(plist "$BUILT" CFBundleName)"
VERSION="$(plist "$BUILT" CFBundleShortVersionString)"
BUILD_NUMBER="$(plist "$BUILT" CFBundleVersion)"
EXECUTABLE="$(plist "$BUILT" CFBundleExecutable)"
[[ -n "$NAME" && -n "$VERSION" && -n "$EXECUTABLE" ]] || fail "could not read the app's name and version"

KIND="ad-hoc"
TIMESTAMP=(--timestamp=none)
if [[ "$IDENTITY" == "Developer ID Application:"* ]]; then
    KIND="Developer ID"
    TIMESTAMP=(--timestamp)
elif [[ "$IDENTITY" != "-" ]]; then
    KIND="development"
fi
if [[ "$IDENTITY" != "-" ]]; then
    security find-identity -v -p codesigning | grep -F "\"$IDENTITY\"" >/dev/null \
        || fail "the signing identity \"$IDENTITY\" is not in the keychain"
fi

step "Stage $NAME $VERSION ($BUILD_NUMBER), $KIND signing"
rm -rf "$DIST"
mkdir -p "$DIST/image" "$DIST/dSYMs"
APP="$DIST/image/$NAME.app"
ditto "$BUILT" "$APP"
find "$PRODUCTS" -maxdepth 1 -name '*.dSYM' -exec cp -R {} "$DIST/dSYMs/" \;
BINARY="$APP/Contents/MacOS/$EXECUTABLE"
ENGINE="$APP/Contents/Frameworks/Libmpv.framework"
SPARKLE="$APP/Contents/Frameworks/Sparkle.framework/Versions/B"

# The licence texts must go out with the app.
LICENSES="$(find "$APP/Contents/Resources/Licenses" -type f 2>/dev/null | wc -l | tr -d ' ')"
[[ "$LICENSES" -ge 30 && -f "$APP/Contents/Resources/ThirdParty.json" ]] \
    || fail "the app carries $LICENSES licence texts; run Scripts/collect-licenses.sh and build again"

step "Strip local symbols"
BEFORE="$(du -sm "$APP" | cut -f1)"
strip -x "$BINARY" 2>/dev/null
strip -x "$ENGINE/Versions/A/Libmpv" 2>/dev/null
echo "$BEFORE MB -> $(du -sm "$APP" | cut -f1) MB"

step "Sign, from the inside out"
sign() {
    local output
    # Captured, not piped: a pipe would hide codesign's own failure behind the filter's success.
    output="$(codesign --force --sign "$IDENTITY" --options runtime "${TIMESTAMP[@]}" "$@" 2>&1)" \
        || { echo "$output" >&2; fail "could not sign ${*: -1}"; }
}
# The updater's helpers first, as its documentation asks; the downloader keeps its own entitlements.
sign "$SPARKLE/XPCServices/Installer.xpc"
sign --preserve-metadata=entitlements "$SPARKLE/XPCServices/Downloader.xpc"
sign "$SPARKLE/Autoupdate"
sign "$SPARKLE/Updater.app"
sign "$APP/Contents/Frameworks/Sparkle.framework"
sign "$ENGINE"
if [[ "$KIND" == "ad-hoc" ]]; then
    # No Team ID to tie the app to its frameworks: see Config/LocalSigning.entitlements.
    sign --entitlements Config/LocalSigning.entitlements "$APP"
else
    sign "$APP"
fi

step "Check the app"
codesign --verify --deep --strict "$APP" || fail "the signature does not verify"
ENTITLEMENTS="$(codesign -d --entitlements - "$APP" 2>/dev/null || true)"
if [[ "$KIND" != "ad-hoc" && "$ENTITLEMENTS" == *disable-library-validation* ]]; then
    fail "a build signed with an identity must not carry the library-validation exception"
fi
DETAILS="$(codesign -d --verbose=2 "$APP" 2>&1)"
[[ "$DETAILS" =~ flags=[^[:space:]]*runtime ]] || fail "the hardened runtime is not on"
for code in "$BINARY" "$ENGINE/Versions/A/Libmpv"; do
    ARCHS="$(lipo -archs "$code")"
    [[ "$ARCHS" == *arm64* && "$ARCHS" == *x86_64* ]] || fail "$(basename "$code") is not universal ($ARCHS)"
done
# Run it as the loader will: a framework it refuses shows up here, in a log, not as a crash dialog.
"$BINARY" >"$DIST/first-run.log" 2>&1 &
RUN_PID=$!
sleep 3
if kill -0 "$RUN_PID" 2>/dev/null; then
    kill "$RUN_PID" 2>/dev/null || true
    wait "$RUN_PID" 2>/dev/null || true
else
    head -c 1500 "$DIST/first-run.log" >&2
    fail "the packaged app exited at launch"
fi
echo "signature, entitlements, architectures and launch: fine"

step "Build the disk image"
ln -s /Applications "$DIST/image/Applications"
DMG="$DIST/$NAME-$VERSION.dmg"
image_tool create -volname "$NAME $VERSION" -srcfolder "$DIST/image" -fs HFS+ -format UDZO -imagekey zlib-level=9 -ov "$DMG" >/dev/null
NOTARISED="no"
if [[ "$KIND" == "Developer ID" ]]; then
    codesign --force --sign "$IDENTITY" --timestamp "$DMG"
    if [[ -n "$NOTARY_PROFILE" ]]; then
        step "Notarise (this waits for Apple)"
        xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait | tee "$DIST/notarisation.log"
        grep -q 'status: Accepted' "$DIST/notarisation.log" || fail "notarisation was not accepted (see $DIST/notarisation.log)"
        xcrun stapler staple "$DMG"
        spctl --assess --type open --context context:primary-signature "$DMG" || fail "Gatekeeper does not accept the notarised image"
        NOTARISED="yes"
    fi
fi

step "Check the disk image"
image_tool verify "$DMG" >/dev/null 2>&1 || fail "the disk image is damaged"
MOUNT="$DIST/mount"
mkdir -p "$MOUNT"
# Not shown in Finder, read-only, and gone again in a moment.
image_tool attach "$DMG" -nobrowse -readonly -mountpoint "$MOUNT" >/dev/null
trap 'hdiutil detach "$MOUNT" >/dev/null 2>&1 || true' EXIT
codesign --verify --deep --strict "$MOUNT/$NAME.app" || fail "the app inside the image does not verify"
[[ -L "$MOUNT/Applications" ]] || fail "the image has no Applications shortcut"
image_tool detach "$MOUNT" >/dev/null
trap - EXIT
rmdir "$MOUNT"

printf '\n%s\n' "$DMG"
echo "  size      $(du -h "$DMG" | cut -f1 | tr -d ' ') (app: $(du -sh "$APP" | cut -f1 | tr -d ' '))"
echo "  sha256    $(shasum -a 256 "$DMG" | cut -d' ' -f1)"
echo "  signing   $KIND; notarised: $NOTARISED"
case "$KIND/$NOTARISED" in
    "Developer ID/yes") echo "  on another Mac: opens normally." ;;
    "Developer ID/no") echo "  on another Mac: macOS will refuse it as not checked by Apple. Set NOTARY_PROFILE to notarise." ;;
    *) echo "  on another Mac: macOS will refuse to open it until its owner allows it in System Settings > Privacy & Security." ;;
esac
if [[ -n "$(plist "$APP" SUFeedURL)" && -n "$(plist "$APP" SUPublicEDKey)" ]]; then
    echo "  updates   sign this image for the appcast with:"
    echo "            build/DerivedData/SourcePackages/artifacts/sparkle/Sparkle/bin/sign_update \"$DMG\""
else
    echo "  updates   off (no feed and key in Config/Branding.xcconfig)"
fi
