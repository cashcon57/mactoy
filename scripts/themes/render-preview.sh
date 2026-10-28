#!/bin/zsh
# Render themes/previews/<id>.jpg by booting the real installer's result in QEMU.
# usage: scripts/themes/render-preview.sh <id> [<id> …]   (needs `brew install qemu`)
set -euo pipefail
ROOT=${0:A:h:h:h}
E2E=$ROOT/scripts/e2e
TOOL=(swift run --package-path "$ROOT/scripts/themes" -q mactoy-themes)
(cd "$E2E" && swift build -q)
WORK=$(mktemp -d)
dev=""
# An attached image must never outlive the script, whether a step failed or not.
cleanup() {
  if [[ -n $dev ]]; then hdiutil detach "$dev" >/dev/null 2>&1 || hdiutil detach -force "$dev" >/dev/null 2>&1 || true; fi
  rm -rf "$WORK"
}
trap cleanup EXIT
for id in "$@"; do
  img=$WORK/$id.img
  mkfile -n 1g "$img"
  dev=$(hdiutil attach -nomount -imagekey diskimage-class=CRawDiskImage "$img" 2>/dev/null | awk 'NR==1{print $1}')
  "$E2E/.build/debug/e2e" "${dev#/dev/}" install off gpt >/dev/null
  mnt=$WORK/mnt-$id; mkdir -p "$mnt"
  diskutil unmount "${dev}s1" >/dev/null 2>&1 || true
  diskutil mount -mountPoint "$mnt" "${dev}s1" >/dev/null
  for f in ubuntu-24.04.3-desktop-amd64.iso Fedora-Workstation-Live-43-1.6.x86_64.iso archlinux-2026.10.01-x86_64.iso \
           debian-13.1.0-amd64-netinst.iso linuxmint-22.2-cinnamon-64bit.iso Win11_25H2_English_x64.iso \
           tails-amd64-7.1.img memtest86plus-7.20.iso; do mkfile -n 64k "$mnt/$f"; done
  "${TOOL[@]}" install "$ROOT/themes/catalog.json" "$mnt" "$id"
  # macOS adds AppleDouble files on exFAT; they aren't part of what a user's drive would hold.
  find "$mnt" -name '._*' -delete
  hdiutil detach "$dev" >/dev/null 2>&1
  dev=""
  (cd "$WORK" && python3 "$E2E/qemu-drive.py" "$img" uefi "shot-$id" wait:35 shot:menu >/dev/null)
  shot=$WORK/shot-$id-menu.png
  w=$(sips -g pixelWidth "$shot" | awk '/pixelWidth/{print $2}'); h=$(sips -g pixelHeight "$shot" | awk '/pixelHeight/{print $2}')
  if (( w * 9 == h * 16 )); then
    sips -s format jpeg -s formatOptions 84 -z 900 1600 "$shot" --out "$ROOT/themes/previews/$id.jpg" >/dev/null
  else
    # A theme that sets a 4:3 mode (568flat) is captured at that mode. Stretching it to 16:9 would
    # distort it, so it's scaled to the height and padded with black at the sides.
    sips -s format jpeg -s formatOptions 84 --resampleHeight 900 --padToHeightWidth 900 1600 --padColor 000000 "$shot" --out "$ROOT/themes/previews/$id.jpg" >/dev/null 2>&1
  fi
  rm -f "$img"
  echo "rendered themes/previews/$id.jpg (captured ${w}x${h})"
done
