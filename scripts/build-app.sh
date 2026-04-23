#!/usr/bin/env bash
# Build Mactoy.app bundle from SPM output.
# Usage:
#   scripts/build-app.sh                          # debug, native arch
#   scripts/build-app.sh release                  # release, native arch
#   scripts/build-app.sh release sign             # release, ad-hoc signed
#   scripts/build-app.sh release devid            # release, Developer ID
#   MACTOY_UNIVERSAL=1 scripts/build-app.sh ...   # build arm64 + x86_64
#     fat binaries (ships a single app that runs on Apple Silicon AND
#     Intel Macs back to macOS 13 Ventura).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

MODE="${1:-debug}"
SIGN="${2:-nosign}"

CONFIG="debug"
if [[ "$MODE" == "release" ]]; then
    CONFIG="release"
fi

# Universal binary opt-in. SwiftPM supports multiple --arch flags in a
# single `swift build` invocation to produce a fat binary directly.
# Default off so local dev builds stay fast on Apple Silicon; CI /
# release builds should export MACTOY_UNIVERSAL=1.
ARCH_ARGS=()
if [[ "${MACTOY_UNIVERSAL:-0}" == "1" ]]; then
    ARCH_ARGS=(--arch arm64 --arch x86_64)
    echo "==> Universal build (arm64 + x86_64)"
fi

echo "==> Building $CONFIG"
# ${ARCH_ARGS[@]+"${ARCH_ARGS[@]}"} is the bash-3.2-safe idiom for
# "expand to nothing when the array is empty, quoted args otherwise".
# macOS still ships bash 3.2 at /bin/bash and trips `set -u` without it.
swift build -c "$CONFIG" ${ARCH_ARGS[@]+"${ARCH_ARGS[@]}"} --product Mactoy
swift build -c "$CONFIG" ${ARCH_ARGS[@]+"${ARCH_ARGS[@]}"} --product mactoyd

# With multiple --arch flags SwiftPM puts the universal binary in an
# `apple/Products/<Config>` directory instead of the normal flat path.
# --show-bin-path returns the right directory in both cases.
BUILD_DIR="$(swift build -c "$CONFIG" ${ARCH_ARGS[@]+"${ARCH_ARGS[@]}"} --show-bin-path)"

APP="$ROOT/build/Mactoy.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
mkdir -p "$APP/Contents/Resources"
mkdir -p "$APP/Contents/Library/LaunchDaemons"

# Both binaries live in Contents/MacOS so codesign --deep descends into
# both. SMAppService expects BundleProgram paths to be relative to
# Contents/, and the daemon plist we ship points at Contents/MacOS/mactoyd.
cp "$BUILD_DIR/Mactoy"   "$APP/Contents/MacOS/Mactoy"
cp "$BUILD_DIR/mactoyd"  "$APP/Contents/MacOS/mactoyd"
chmod +x "$APP/Contents/MacOS/Mactoy" "$APP/Contents/MacOS/mactoyd"

cp "$ROOT/app-support/Info.plist" "$APP/Contents/Info.plist"

# LaunchDaemon plist. SMAppService reads this from
# Contents/Library/LaunchDaemons/<Label>.plist when the app calls
# SMAppService.daemon(plistName:).
cp "$ROOT/app-support/com.mactoy.mactoyd.plist" \
   "$APP/Contents/Library/LaunchDaemons/com.mactoy.mactoyd.plist"

# Copy AppIcon if present
if [[ -f "$ROOT/app-support/AppIcon.icns" ]]; then
    cp "$ROOT/app-support/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
fi

# Copy SPM-bundled resources if they exist
if [[ -d "$BUILD_DIR/Mactoy_Mactoy.bundle" ]]; then
    cp -R "$BUILD_DIR/Mactoy_Mactoy.bundle" "$APP/Contents/Resources/"
fi

# Signing:
#   SIGN=nosign    : no codesign at all
#   SIGN=sign      : ad-hoc sign (for local dev)
#   SIGN=devid     : Developer ID Application + hardened runtime (release-ready)
# The Developer ID identity is read from env var MACTOY_DEVID_IDENTITY or
# defaults to the first Developer ID Application cert on the keychain.
if [[ "$SIGN" == "sign" ]]; then
    codesign --force --sign - "$APP/Contents/MacOS/mactoyd"
    codesign --force --deep --sign - "$APP"
elif [[ "$SIGN" == "devid" ]]; then
    IDENTITY="${MACTOY_DEVID_IDENTITY:-}"
    if [[ -z "$IDENTITY" ]]; then
        IDENTITY="$(security find-identity -v -p codesigning | awk -F'"' '/Developer ID Application:/ {print $2; exit}')"
    fi
    if [[ -z "$IDENTITY" ]]; then
        echo "error: no Developer ID Application identity on keychain" >&2
        exit 1
    fi
    echo "==> Signing with: $IDENTITY"

    APP_ENT="$ROOT/app-support/Mactoy.entitlements"
    HELPER_ENT="$ROOT/app-support/mactoyd.entitlements"

    # Inside-out signing. `--deep --entitlements` is the classic trap that
    # would overwrite mactoyd's entitlements with the app's, so we sign
    # each piece explicitly and without --deep on the final app pass.

    # SPM's resource bundles (Mactoy_Mactoy.bundle) are flat directories
    # without Contents/MacOS structure — codesign treats them as mach-O
    # bundles and rejects them. They have no executable code, so we
    # intentionally skip signing them; the outer app signature still
    # hashes their contents into the resource bag, so tampering breaks
    # the app signature.

    # Sign the daemon with its own (narrow) entitlements. The identifier
    # must match the LaunchDaemon plist Label — SMAppService rejects a
    # daemon whose code-signature identifier doesn't match.
    codesign --force --options runtime --timestamp \
        --identifier "com.mactoy.mactoyd" \
        --entitlements "$HELPER_ENT" \
        --sign "$IDENTITY" \
        "$APP/Contents/MacOS/mactoyd"

    # Sign the app last. No --deep: if we use --deep with --entitlements,
    # codesign silently reapplies APP_ENT to every nested mach-O, blowing
    # away the entitlements we just set on mactoyd.
    codesign --force --options runtime --timestamp \
        --entitlements "$APP_ENT" \
        --sign "$IDENTITY" \
        "$APP"

    # Verify — use --deep here to confirm every nested mach-O is signed.
    codesign --verify --deep --strict --verbose=2 "$APP"
fi

echo "==> Built $APP"
du -sh "$APP" 2>/dev/null || true
