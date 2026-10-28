#!/bin/bash
# Build a distributable MacmonDash release:
#   dist/MacmonDash-<version>.zip   (ditto, Finder-compatible, keeps codesign)
#   dist/MacmonDash-<version>.dmg   (Docker-style drag-to-Applications window)
#   dist/MacmonDash.dmg             (same image, stable name for the README button)
#   dist/MacmonDash.zip             (same archive, stable name)
#   dist/SHA256SUMS.txt
#
# Usage: ./Scripts/make-release.sh [version]     (default 1.0.0)
#
# DMG styling needs the Python package `dmgbuild` (writes Finder .DS_Store):
#   pip3 install --user dmgbuild
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
export MACMONDASH_ROOT="$ROOT"

VERSION="${1:-${VERSION:-1.0.0}}"
APP_NAME="MacmonDash"
APP_DIR="$ROOT/dist/${APP_NAME}.app"
VOL_NAME="MacmonDash"
BG_PNG="$ROOT/Resources/dmg-background.png"

echo "==> Building ${APP_NAME} ${VERSION}"
INSTALL=0 VERSION="$VERSION" "$ROOT/Scripts/package-app.sh"

# Sanity: bundle contents + signature
codesign --verify --deep --strict "$APP_DIR"
for f in MacOS/MacmonDash Resources/macmon Resources/macmon10 Resources/AppIcon.icns Info.plist; do
  [[ -e "$APP_DIR/Contents/$f" ]] || { echo "missing $f in bundle" >&2; exit 1; }
done

echo "==> DMG background"
if python3 -c "from PIL import Image" 2>/dev/null; then
  python3 "$ROOT/Scripts/make-dmg-background.py"
else
  echo "Pillow not installed — using committed Resources/dmg-background.png"
fi
[[ -f "$BG_PNG" ]] || { echo "missing $BG_PNG" >&2; exit 1; }

DMGBUILD="$(command -v dmgbuild || true)"
if [[ -z "$DMGBUILD" || ! -x "$DMGBUILD" ]]; then
  for cand in \
    "$HOME/Library/Python/"*/bin/dmgbuild \
    /usr/local/bin/dmgbuild \
    /opt/homebrew/bin/dmgbuild
  do
    if [[ -x "$cand" ]]; then DMGBUILD="$cand"; break; fi
  done
fi
if [[ -z "${DMGBUILD:-}" || ! -x "${DMGBUILD:-}" ]]; then
  if python3 -c "import dmgbuild" 2>/dev/null; then
    DMGBUILD=""
  else
    echo "dmgbuild is required for the drag-and-drop installer window." >&2
    echo "Install with: pip3 install --user dmgbuild" >&2
    exit 1
  fi
fi

ZIP="$ROOT/dist/${APP_NAME}-${VERSION}.zip"
DMG="$ROOT/dist/${APP_NAME}-${VERSION}.dmg"
rm -f "$ZIP" "$DMG"

# Detach leftover mount
if [[ -d "/Volumes/${VOL_NAME}" ]]; then
  hdiutil detach "/Volumes/${VOL_NAME}" -quiet 2>/dev/null || \
    hdiutil detach "/Volumes/${VOL_NAME}" -force -quiet 2>/dev/null || true
fi

echo "==> Zipping → $ZIP"
ditto -c -k --sequesterRsrc --keepParent "$APP_DIR" "$ZIP"

echo "==> Building DMG → $DMG"
if [[ -n "$DMGBUILD" ]]; then
  "$DMGBUILD" -s "$ROOT/Scripts/dmgbuild-settings.py" "$VOL_NAME" "$DMG"
else
  python3 -m dmgbuild -s "$ROOT/Scripts/dmgbuild-settings.py" "$VOL_NAME" "$DMG"
fi

# Stable names so the README can link releases/latest/download/MacmonDash.dmg
cp "$DMG" "$ROOT/dist/${APP_NAME}.dmg"
cp "$ZIP" "$ROOT/dist/${APP_NAME}.zip"

echo "==> Checksums"
( cd "$ROOT/dist" && shasum -a 256 \
    "$(basename "$ZIP")" "$(basename "$DMG")" \
    "${APP_NAME}.zip" "${APP_NAME}.dmg" | tee SHA256SUMS.txt )

echo "Done:"
ls -la "$ZIP" "$DMG" "$ROOT/dist/${APP_NAME}.dmg" "$ROOT/dist/${APP_NAME}.zip"
