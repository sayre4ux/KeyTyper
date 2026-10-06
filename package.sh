#!/bin/sh
# Builds TypeThru.app and wraps it in TypeThru-<version>.dmg for download.
# With a Developer ID certificate and TYPETHRU_NOTARY_PROFILE (a notarytool keychain profile),
# the disk image is also notarized, so it opens without a Gatekeeper warning.
set -e
cd "$(dirname "$0")"
./build.sh
VERSION=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' TypeThru.app/Contents/Info.plist)
DMG="TypeThru-$VERSION.dmg"
# DECISION: a fresh staging folder in TMPDIR, which macOS cleans, instead of deleting folders here.
STAGE=$(mktemp -d "${TMPDIR:-/tmp}/typethru-dmg.XXXXXX")
rm -f "$DMG"
ditto TypeThru.app "$STAGE/TypeThru.app"
ln -s /Applications "$STAGE/Applications"
cat > "$STAGE/Read Me First.txt" <<'TEXT'
Install TypeThru

1. Drag TypeThru into the Applications folder.
2. Eject this disk, then open TypeThru from Applications.
3. If macOS says it cannot verify TypeThru: open System Settings > Privacy & Security,
   scroll down, and choose Open Anyway next to TypeThru. This is needed once.
4. Follow TypeThru's prompts: allow Accessibility, then set up Virtual Keyboard
   with your administrator password.

A keyboard icon appears in the menu bar. Copy text, click a field in your remote
session, and press Control+\ to type it.
TEXT
hdiutil create -quiet -volname TypeThru -srcfolder "$STAGE" -format UDZO -fs HFS+ "$DMG"
if [ -n "${TYPETHRU_NOTARY_PROFILE-}" ]; then
    xcrun notarytool submit "$DMG" --keychain-profile "$TYPETHRU_NOTARY_PROFILE" --wait
    xcrun stapler staple "$DMG"
fi
shasum -a 256 "$DMG"
echo "Packaged $(pwd)/$DMG"
