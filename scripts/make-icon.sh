#!/bin/sh
# Regenerates Resources/AppIcon.icns and the README logos in docs/ from scripts/make-icon.swift and Sources/Brand.swift.
set -e
cd "$(dirname "$0")/.."
WORK=$(mktemp -d "${TMPDIR:-/tmp}/typethru-icon.XXXXXX")
# Top-level code must live in a file named main.swift.
cp scripts/make-icon.swift "$WORK/main.swift"
swiftc -module-cache-path "$WORK/module-cache" "$WORK/main.swift" Sources/Brand.swift -o "$WORK/make-icon"
"$WORK/make-icon" "$WORK/AppIcon.iconset" docs
iconutil -c icns "$WORK/AppIcon.iconset" -o Resources/AppIcon.icns
echo "Wrote Resources/AppIcon.icns and docs/logo-*.png"
