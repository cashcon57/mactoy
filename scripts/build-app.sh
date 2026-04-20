#!/usr/bin/env bash
# Build Mactoy.app bundle from SPM output.
# Usage:
#   scripts/build-app.sh                  # debug
#   scripts/build-app.sh release          # release, unsigned
#   scripts/build-app.sh release sign     # release, ad-hoc signed (local)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

MODE="${1:-debug}"
SIGN="${2:-nosign}"

CONFIG="debug"
if [[ "$MODE" == "release" ]]; then
    CONFIG="release"
fi

echo "==> Building $CONFIG"
swift build -c "$CONFIG" --product Mactoy
swift build -c "$CONFIG" --product mactoyd

BUILD_DIR="$(swift build -c "$CONFIG" --show-bin-path)"

APP="$ROOT/build/Mactoy.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
mkdir -p "$APP/Contents/Resources"

cp "$BUILD_DIR/Mactoy"   "$APP/Contents/MacOS/Mactoy"
cp "$BUILD_DIR/mactoyd"  "$APP/Contents/Resources/mactoyd"
chmod +x "$APP/Contents/MacOS/Mactoy" "$APP/Contents/Resources/mactoyd"

cp "$ROOT/app-support/Info.plist" "$APP/Contents/Info.plist"

# Copy AppIcon if present
if [[ -f "$ROOT/app-support/AppIcon.icns" ]]; then
    cp "$ROOT/app-support/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
fi

# Copy SPM-bundled resources if they exist
if [[ -d "$BUILD_DIR/Mactoy_Mactoy.bundle" ]]; then
    cp -R "$BUILD_DIR/Mactoy_Mactoy.bundle" "$APP/Contents/Resources/"
fi

# Ad-hoc sign if requested (so macOS doesn't quarantine as hard)
if [[ "$SIGN" == "sign" ]]; then
    codesign --force --deep --sign - "$APP/Contents/Resources/mactoyd"
    codesign --force --deep --sign - "$APP"
fi

echo "==> Built $APP"
du -sh "$APP" 2>/dev/null || true
