#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

APP_NAME="MacmonDash"
BUILD_DIR="$ROOT/.build/release"
APP_DIR="$ROOT/dist/${APP_NAME}.app"
INSTALL_DIR="/Applications/${APP_NAME}.app"
# INSTALL=0 ./Scripts/package-app.sh  → build dist/MacmonDash.app only (CI / release)
INSTALL="${INSTALL:-1}"
VERSION="${VERSION:-1.0.0}"

echo "==> Building $APP_NAME (release)"
swift build -c release --product MacmonDash

BIN="$BUILD_DIR/MacmonDash"
if [[ ! -x "$BIN" ]]; then
  # SPM may put binary in arch triple folder
  BIN="$(find "$ROOT/.build" -type f -name MacmonDash -path '*/release/MacmonDash' | head -1)"
fi
if [[ ! -x "$BIN" ]]; then
  echo "Built binary not found" >&2
  exit 1
fi

echo "==> Assembling $APP_DIR"
rm -rf "$ROOT/dist"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"

cp "$BIN" "$APP_DIR/Contents/MacOS/$APP_NAME"
chmod +x "$APP_DIR/Contents/MacOS/$APP_NAME"

# Prefer SPM-bundled resource from build, else project Resources
MACMON_SRC=""
if [[ -x "$ROOT/Sources/MacmonDash/Resources/macmon" ]]; then
  MACMON_SRC="$ROOT/Sources/MacmonDash/Resources/macmon"
elif [[ -x "$ROOT/Resources/macmon" ]]; then
  MACMON_SRC="$ROOT/Resources/macmon"
fi
# Also copy any resource-bundle macmon produced by SPM
SPM_MACMON="$(find "$ROOT/.build" -type f -name macmon 2>/dev/null | head -1 || true)"
if [[ -n "$SPM_MACMON" && -f "$SPM_MACMON" ]]; then
  MACMON_SRC="$SPM_MACMON"
fi
if [[ -z "$MACMON_SRC" ]]; then
  echo "macmon binary missing" >&2
  exit 1
fi
cp "$MACMON_SRC" "$APP_DIR/Contents/Resources/macmon"
chmod +x "$APP_DIR/Contents/Resources/macmon"

# Fan poller (macmon 0.10)
MACMON10=""
if [[ -x "$ROOT/Sources/MacmonDash/Resources/macmon10" ]]; then
  MACMON10="$ROOT/Sources/MacmonDash/Resources/macmon10"
fi
SPM10="$(find "$ROOT/.build" -type f -name macmon10 2>/dev/null | head -1 || true)"
if [[ -n "$SPM10" ]]; then MACMON10="$SPM10"; fi
if [[ -n "$MACMON10" ]]; then
  cp "$MACMON10" "$APP_DIR/Contents/Resources/macmon10"
  chmod +x "$APP_DIR/Contents/Resources/macmon10"
fi

# App icon (bit-graphic fan) — regenerate if missing
if [[ ! -f "$ROOT/Resources/AppIcon.icns" ]]; then
  python3 "$ROOT/Scripts/make-icon.py"
fi
cp "$ROOT/Resources/AppIcon.icns" "$APP_DIR/Contents/Resources/AppIcon.icns"

# Copy SPM resource bundle if present (Bundle.module)
RES_BUNDLE="$(find "$ROOT/.build" -type d -name 'MacmonDash_MacmonDash.bundle' 2>/dev/null | head -1 || true)"
if [[ -n "$RES_BUNDLE" ]]; then
  cp -R "$RES_BUNDLE" "$APP_DIR/Contents/Resources/"
fi

cat > "$APP_DIR/Contents/Info.plist" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleDisplayName</key>
  <string>MacmonDash</string>
  <key>CFBundleExecutable</key>
  <string>${APP_NAME}</string>
  <key>CFBundleIconFile</key>
  <string>AppIcon</string>
  <key>CFBundleIdentifier</key>
  <string>com.local.macmondash</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>MacmonDash</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>${VERSION}</string>
  <key>CFBundleVersion</key>
  <string>${VERSION}</string>
  <key>NSHumanReadableCopyright</key>
  <string>© 2026 Eshan Khan. MIT License. Built on macmon (vladkens) and SwiftTerm.</string>
  <key>LSApplicationCategoryType</key>
  <string>public.app-category.utilities</string>
  <key>LSMinimumSystemVersion</key>
  <string>14.0</string>
  <key>LSArchitecturePriority</key>
  <array>
    <string>arm64</string>
  </array>
  <key>NSHighResolutionCapable</key>
  <true/>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
  <key>NSSupportsAutomaticGraphicsSwitching</key>
  <true/>
</dict>
</plist>
EOF

# PkgInfo
echo -n 'APPL????' > "$APP_DIR/Contents/PkgInfo"

echo "==> Codesigning (ad-hoc)"
codesign --force --deep -s - "$APP_DIR"

if [[ "$INSTALL" != "1" ]]; then
  echo "Done: $APP_DIR"
  exit 0
fi

echo "==> Installing to $INSTALL_DIR"
rm -rf "$INSTALL_DIR"
cp -R "$APP_DIR" "$INSTALL_DIR"
codesign --force --deep -s - "$INSTALL_DIR"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$INSTALL_DIR" || true

echo "Done: $INSTALL_DIR"
echo "Launch: open -a MacmonDash"
