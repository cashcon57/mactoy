#!/usr/bin/env bash
# Build Mactoy.dmg from a previously-built Mactoy.app.
# Usage: scripts/build-dmg.sh [version]
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

VERSION="${1:-0.2.1}"
APP="$ROOT/build/Mactoy.app"
DMG="$ROOT/build/Mactoy-$VERSION.dmg"

if [[ ! -d "$APP" ]]; then
    echo "error: $APP not found — run scripts/build-app.sh release sign first" >&2
    exit 1
fi

rm -f "$DMG"

if ! command -v create-dmg >/dev/null; then
    echo "error: create-dmg not found — install via 'brew install create-dmg'" >&2
    exit 1
fi

create-dmg \
    --volname "Mactoy $VERSION" \
    --window-pos 200 200 \
    --window-size 600 380 \
    --icon-size 96 \
    --icon "Mactoy.app" 150 180 \
    --hide-extension "Mactoy.app" \
    --app-drop-link 450 180 \
    --no-internet-enable \
    "$DMG" \
    "$APP"

# Sign the DMG with the same Developer ID if requested
if [[ "${2:-}" == "devid" ]]; then
    IDENTITY="${MACTOY_DEVID_IDENTITY:-}"
    if [[ -z "$IDENTITY" ]]; then
        IDENTITY="$(security find-identity -v -p codesigning | awk -F'"' '/Developer ID Application:/ {print $2; exit}')"
    fi
    if [[ -n "$IDENTITY" ]]; then
        echo "==> Signing DMG with: $IDENTITY"
        codesign --force --sign "$IDENTITY" --timestamp "$DMG"
    fi
fi

echo "==> Built $DMG"
du -sh "$DMG"
shasum -a 256 "$DMG"
