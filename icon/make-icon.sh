#!/bin/sh
# Regenerates icon/AppIcon.icns and the README logos in docs/ from icon/make-icon.swift and Brand.swift.
set -e
cd "$(dirname "$0")/.."
WORK=$(mktemp -d "${TMPDIR:-/tmp}/typethru-icon.XXXXXX")
# Top-level code must live in a file named main.swift.
cp icon/make-icon.swift "$WORK/main.swift"
swiftc -module-cache-path "$WORK/module-cache" "$WORK/main.swift" Brand.swift -o "$WORK/make-icon"
"$WORK/make-icon" "$WORK/AppIcon.iconset" docs
iconutil -c icns "$WORK/AppIcon.iconset" -o icon/AppIcon.icns
echo "Wrote icon/AppIcon.icns and docs/logo-*.png"
