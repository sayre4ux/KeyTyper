#!/bin/sh
# Regenerates icon/AppIcon.icns from icon/make-icon.swift and Brand.swift.
set -e
cd "$(dirname "$0")/.."
WORK=$(mktemp -d "${TMPDIR:-/tmp}/typethru-icon.XXXXXX")
# Top-level code must live in a file named main.swift.
cp icon/make-icon.swift "$WORK/main.swift"
swiftc -module-cache-path "$WORK/module-cache" "$WORK/main.swift" Brand.swift -o "$WORK/make-icon"
"$WORK/make-icon" "$WORK/AppIcon.iconset"
iconutil -c icns "$WORK/AppIcon.iconset" -o icon/AppIcon.icns
cp "$WORK/AppIcon.iconset/icon_512x512@2x.png" "$WORK/preview.png"
echo "Wrote icon/AppIcon.icns (preview: $WORK/preview.png)"
