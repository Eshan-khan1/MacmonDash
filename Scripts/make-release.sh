#!/bin/bash
# Build a distributable MacmonDash release:
#   dist/MacmonDash-<version>.zip   (ditto, Finder-compatible, keeps codesign)
#   dist/MacmonDash-<version>.dmg   (drag-to-Applications image)
#   dist/MacmonDash.dmg             (same image, stable name for the README button)
#   dist/MacmonDash.zip             (same archive, stable name)
#   dist/SHA256SUMS.txt
#
# Usage: ./Scripts/make-release.sh [version]     (default 1.0.0)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

VERSION="${1:-${VERSION:-1.0.0}}"
APP_NAME="MacmonDash"
APP_DIR="$ROOT/dist/${APP_NAME}.app"

echo "==> Building ${APP_NAME} ${VERSION}"
INSTALL=0 VERSION="$VERSION" "$ROOT/Scripts/package-app.sh"

# Sanity: bundle contents + signature
codesign --verify --deep --strict "$APP_DIR"
for f in MacOS/MacmonDash Resources/macmon Resources/macmon10 Resources/AppIcon.icns Info.plist; do
  [[ -e "$APP_DIR/Contents/$f" ]] || { echo "missing $f in bundle" >&2; exit 1; }
done

ZIP="$ROOT/dist/${APP_NAME}-${VERSION}.zip"
DMG="$ROOT/dist/${APP_NAME}-${VERSION}.dmg"
rm -f "$ZIP" "$DMG"

echo "==> Zipping → $ZIP"
ditto -c -k --sequesterRsrc --keepParent "$APP_DIR" "$ZIP"

echo "==> Building DMG → $DMG"
STAGE="$(mktemp -d)"
cp -R "$APP_DIR" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
cat > "$STAGE/READ ME FIRST.txt" << 'EOF'
MacmonDash — live Apple Silicon monitor with fan control

1. Drag MacmonDash into the Applications folder.
2. First launch: macOS will say the app is from an unidentified developer
   (it is open source and not notarized). Right-click MacmonDash → Open,
   or allow it in System Settings → Privacy & Security → "Open Anyway".
3. MacmonDash will offer to install a small helper for fan control and
   cache purge. macOS asks for your password once. You can remove the helper
   from the MacmonDash menu at any time.

https://github.com/Eshan-khan1/MacmonDash
EOF
hdiutil create -volname "${APP_NAME} ${VERSION}" -srcfolder "$STAGE" -ov -format UDZO -quiet "$DMG"
rm -rf "$STAGE"

# Stable names so the README can link releases/latest/download/MacmonDash.dmg
cp "$DMG" "$ROOT/dist/${APP_NAME}.dmg"
cp "$ZIP" "$ROOT/dist/${APP_NAME}.zip"

echo "==> Checksums"
( cd "$ROOT/dist" && shasum -a 256 \
    "$(basename "$ZIP")" "$(basename "$DMG")" \
    "${APP_NAME}.zip" "${APP_NAME}.dmg" | tee SHA256SUMS.txt )

echo "Done:"
ls -la "$ZIP" "$DMG" "$ROOT/dist/${APP_NAME}.dmg" "$ROOT/dist/${APP_NAME}.zip"
