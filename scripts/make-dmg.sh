#!/usr/bin/env bash
# Package a built Blah Desktop.app into a DMG for direct distribution.
#
# Usage:
#   scripts/make-dmg.sh <path-to-app> [output.dmg]
#
# Signing and notarization are opt-in through the environment. Without them the
# DMG still works, but Gatekeeper makes the first launch a right-click -> Open.
#
#   SIGN_IDENTITY   Developer ID Application certificate, e.g.
#                   "Developer ID Application: Example Inc (ABCDE12345)"
#   NOTARY_PROFILE  keychain profile holding App Store Connect credentials,
#                   created once with:
#                     xcrun notarytool store-credentials <name> \
#                       --key <AuthKey_XXX.p8> --key-id <KEY_ID> --issuer <ISSUER_ID>
#
# Notarization is a malware scan, not a submission: unlike App Store Connect it
# accepts builds made with a beta Xcode.
set -euo pipefail

APP="${1:-}"
if [ -z "$APP" ] || [ ! -d "$APP" ]; then
    echo "usage: $0 <path-to-.app> [output.dmg]" >&2
    exit 1
fi

APP_NAME="$(basename "$APP" .app)"
VOL_NAME="$APP_NAME"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
    "$APP/Contents/Info.plist" 2>/dev/null || echo unknown)"
OUT="${2:-$(dirname "$APP")/$APP_NAME-$VERSION.dmg}"

SIGN_IDENTITY="${SIGN_IDENTITY:-}"
NOTARY_PROFILE="${NOTARY_PROFILE:-}"

STAGE="$(mktemp -d)"
TEMP_DMG="$(mktemp -u).dmg"
cleanup() { rm -rf "$STAGE" "$TEMP_DMG"; }
trap cleanup EXIT

echo "==> $APP_NAME $VERSION"

# --- sign -----------------------------------------------------------------
# Nested code is signed first and the bundle last, and every part gets the same
# identity: dyld refuses to load a framework whose team differs from the app's.
if [ -n "$SIGN_IDENTITY" ]; then
    echo "==> signing with: $SIGN_IDENTITY"
    ENTITLEMENTS="$(cd "$(dirname "$0")/.." && pwd)/Telegram/Telegram/Telegram.entitlements"
    while IFS= read -r nested; do
        [ -n "$nested" ] || continue
        echo "    nested: $(basename "$nested")"
        codesign --force --options runtime --timestamp \
            --sign "$SIGN_IDENTITY" "$nested"
    done < <(find "$APP/Contents/Frameworks" -maxdepth 1 \
        \( -name '*.framework' -o -name '*.dylib' \) 2>/dev/null || true)

    codesign --force --options runtime --timestamp \
        --entitlements "$ENTITLEMENTS" \
        --sign "$SIGN_IDENTITY" "$APP"
    codesign --verify --deep --strict --verbose=1 "$APP"
else
    echo "==> no SIGN_IDENTITY, leaving the existing signature alone"
fi

# --- build the image ------------------------------------------------------
echo "==> staging"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"

echo "==> creating image"
hdiutil create -volname "$VOL_NAME" -srcfolder "$STAGE" \
    -ov -format UDBZ -quiet "$TEMP_DMG"
mv "$TEMP_DMG" "$OUT"

if [ -n "$SIGN_IDENTITY" ]; then
    codesign --force --sign "$SIGN_IDENTITY" "$OUT"
fi

# --- notarize -------------------------------------------------------------
if [ -n "$NOTARY_PROFILE" ]; then
    echo "==> notarizing (this uploads the image to Apple and waits)"
    xcrun notarytool submit "$OUT" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$OUT"
    echo "==> stapled"
    spctl --assess --type open --context context:primary-signature -v "$OUT" || true
else
    echo "==> no NOTARY_PROFILE, skipping notarization"
    echo "    testers open it once with right-click -> Open"
fi

echo
echo "==> $OUT"
du -h "$OUT" | awk '{print "    " $1}'
