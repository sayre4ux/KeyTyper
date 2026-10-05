#!/bin/sh
# Builds KeyTyper.app next to this script.
set -e
cd "$(dirname "$0")"
for tool in git clang++ swiftc codesign; do
    command -v "$tool" >/dev/null 2>&1 || {
        echo "Missing $tool. Install the Xcode Command Line Tools with: xcode-select --install"
        exit 1
    }
done
APP=KeyTyper.app

# A stable signing identity lets macOS keep the Accessibility permission across builds.
# Any code signing certificate works: paid Developer ID, free Apple Development, or self-signed.
# Set KEYTYPER_SIGN_IDENTITY to a certificate name or hash, or to - to force ad-hoc signing.
# DECISION: without the variable, prefer Developer ID, then Apple Development, then ad-hoc.
IDENTITY=${KEYTYPER_SIGN_IDENTITY-}
if [ -z "$IDENTITY" ]; then
    IDENTITIES=$(security find-identity -v -p codesigning 2>/dev/null || true)
    for kind in 'Developer ID Application' 'Apple Development'; do
        IDENTITY=$(printf '%s\n' "$IDENTITIES" | awk -v k="\"$kind:" 'index($0, k) { print $2; exit }')
        [ -n "$IDENTITY" ] && break
    done
fi
IDENTITY=${IDENTITY:--}
if [ "$IDENTITY" = - ]; then
    echo 'Signing: ad-hoc (macOS will ask for Accessibility again after each build)'
else
    NAME=$(security find-identity -p codesigning 2>/dev/null | awk -v h="$IDENTITY" '$2 == h { sub(/^[^"]*/, ""); print; exit }')
    echo "Signing: ${NAME:-$IDENTITY}"
fi
# DECISION: --timestamp=none keeps builds offline; these builds are not notarized.
sign() { codesign --force --timestamp=none --sign "$IDENTITY" "$@"; }

REV=072fa83e824c1b633f508f60cbad87b41aab3047
SOURCE=.build/virtualhid-source
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" .build/module-cache
if [ ! -d "$SOURCE/.git" ]; then
    git init "$SOURCE"
    git -C "$SOURCE" remote add origin https://github.com/pqrs-org/Karabiner-DriverKit-VirtualHIDDevice.git
    git -C "$SOURCE" fetch --depth 1 origin "$REV"
    git -C "$SOURCE" checkout --detach FETCH_HEAD
fi
[ "$(git -C "$SOURCE" rev-parse HEAD)" = "$REV" ] || { echo 'Unexpected virtual HID source revision'; exit 1; }
clang++ -std=c++23 -O2 -Wall -Wextra -pthread -I "$SOURCE/include" -I "$SOURCE/vendor/vendor/include" \
    helper/virtual-keyboard.cpp -o "$APP/Contents/Resources/KeyTyper-VirtualKeyboard"
sign --identifier local.keytyper.virtual-keyboard "$APP/Contents/Resources/KeyTyper-VirtualKeyboard"
"$APP/Contents/Resources/KeyTyper-VirtualKeyboard" --check-protocol
rm -f "$APP/Contents/Resources/"*.command
cp helper/*.command helper/install-helper.sh "$APP/Contents/Resources/"
cp "$SOURCE/dist/Karabiner-DriverKit-VirtualHIDDevice-8.6.0.pkg" "$APP/Contents/Resources/"
cp "$SOURCE/LICENSE.md" "$APP/Contents/Resources/Karabiner-LICENSE.txt"
swiftc -O -module-cache-path "$PWD/.build/module-cache" main.swift VirtualKeyboard.swift -o "$APP/Contents/MacOS/KeyTyper"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>local.keytyper</string>
  <key>CFBundleName</key><string>KeyTyper</string>
  <key>CFBundleExecutable</key><string>KeyTyper</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.1</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
</dict>
</plist>
PLIST
sign --identifier local.keytyper "$APP"

# macOS ties the Accessibility permission to the signature. When the new build cannot reuse the
# old permission (ad-hoc, or a different identity), clear the stale entry so macOS asks cleanly.
LAST=$(cat .build/last-sign-identity 2>/dev/null || true)
if [ "$IDENTITY" = - ] || [ "$IDENTITY" != "$LAST" ]; then
    tccutil reset Accessibility local.keytyper >/dev/null 2>&1 || true
    echo 'Cleared the old Accessibility permission. Allow KeyTyper again when it asks.'
fi
printf '%s\n' "$IDENTITY" > .build/last-sign-identity
echo "Built $(pwd)/$APP"
pgrep -x KeyTyper >/dev/null && echo 'KeyTyper is still running the previous build. Quit and reopen it.' || true
