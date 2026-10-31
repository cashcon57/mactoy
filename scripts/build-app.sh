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

# Record the SDK the binaries were really built with. SwiftPM writes the
# deployment target (13.5) as the SDK version, and macOS reads that number
# to pick an app's look: an app that claims a pre-26 SDK never gets Liquid
# Glass window chrome, toolbars or controls on macOS 26 and later. vtool
# fixes the number for every architecture; older macOS versions ignore it.
SDK_VERSION="$(xcrun --sdk macosx --show-sdk-version)"
for bin in "$APP/Contents/MacOS/Mactoy" "$APP/Contents/MacOS/mactoyd"; do
    vtool -set-build-version macos 13.5 "$SDK_VERSION" -replace -output "$bin" "$bin"
done

cp "$ROOT/app-support/Info.plist" "$APP/Contents/Info.plist"

# LaunchDaemon plist. SMAppService reads this from
# Contents/Library/LaunchDaemons/<Label>.plist when the app calls
# SMAppService.daemon(plistName:).
cp "$ROOT/app-support/com.mactoy.mactoyd.plist" \
   "$APP/Contents/Library/LaunchDaemons/com.mactoy.mactoyd.plist"

# App icon. The source is the Icon Composer file app-support/AppIcon.icon
# (SVG layers). actool (Xcode 26 or newer) compiles it into Assets.car, the
# Liquid Glass icon macOS 26 uses, plus AppIcon.icns for macOS 13 to 15.
# Older Xcode can't read .icon files, so it gets the committed AppIcon.icns,
# which is the same compile, saved. Rebuild that after editing the icon:
#   xcrun actool app-support/AppIcon.icon --compile /tmp/icon --platform macosx \
#     --minimum-deployment-target 13.5 --app-icon AppIcon \
#     --output-partial-info-plist /tmp/icon/p.plist && cp /tmp/icon/AppIcon.icns app-support/
ICON_OUT="$(mktemp -d)"
if xcrun actool "$ROOT/app-support/AppIcon.icon" --compile "$ICON_OUT" --platform macosx \
        --minimum-deployment-target 13.5 --app-icon AppIcon \
        --output-partial-info-plist "$ICON_OUT/partial.plist" >/dev/null 2>&1 \
        && [[ -f "$ICON_OUT/Assets.car" && -f "$ICON_OUT/AppIcon.icns" ]]; then
    cp "$ICON_OUT/Assets.car" "$APP/Contents/Resources/Assets.car"
    cp "$ICON_OUT/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
else
    echo "==> actool couldn't compile AppIcon.icon (needs Xcode 26+); using the committed AppIcon.icns"
    cp "$ROOT/app-support/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
fi
rm -rf "$ICON_OUT"

# Copy SPM-bundled resources if they exist
if [[ -d "$BUILD_DIR/Mactoy_Mactoy.bundle" ]]; then
    cp -R "$BUILD_DIR/Mactoy_Mactoy.bundle" "$APP/Contents/Resources/"
fi

# Boot theme list, screenshots and the default theme, used when the online
# list can't be reached. cp -R keeps the hidden .complete marker inside each
# bundled theme folder; without it the app ignores that folder and downloads.
mkdir -p "$APP/Contents/Resources/Themes"
cp "$ROOT/themes/catalog.json" "$APP/Contents/Resources/Themes/catalog.json"
cp -R "$ROOT/themes/previews" "$APP/Contents/Resources/Themes/previews"
cp -R "$ROOT/themes/bundled" "$APP/Contents/Resources/Themes/bundled"

# A bundled theme folder without its .complete marker is ignored by the app, which then
# downloads the theme and the bundling was for nothing, so fail here rather than ship that.
for folder in "$APP/Contents/Resources/Themes/bundled"/*/; do
    [[ -d "$folder" ]] || continue
    [[ -f "${folder}.complete" ]] || { echo "error: bundled theme ${folder#"$APP"/} has no .complete marker (re-run 'mactoy-themes bundle')" >&2; exit 1; }
done

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
