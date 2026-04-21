#!/usr/bin/env python3
"""
Turn Mactoy.png (2048x2048 with white background + drop shadow) into AppIcon.icns.

Steps:
  1. Flood-fill background from the four corners, treating desaturated
     near-white pixels as background. This kills both the pure-white fill
     AND the soft drop-shadow halo (which is desaturated gray around the
     icon), while stopping on the saturated or dark icon itself.
  2. Tight-crop to the bounding box of remaining (non-transparent) pixels.
  3. Pad the crop to a square canvas with a small safety margin and scale
     to 1024x1024.
  4. Emit AppIcon.iconset/ with all standard sizes, then run iconutil to
     produce AppIcon.icns.

Run from repo root:
    python3 scripts/make-icon.py Mactoy.png app-support/AppIcon.icns
"""
from __future__ import annotations

import subprocess
import sys
from collections import deque
from pathlib import Path

from PIL import Image

ICONSET_SIZES = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024),
]

# Background threshold (desaturated near-white = bg or shadow).
# Derived from pixel-sampling the source: shadow halo ranges (215..254, sat 0..10).
BG_MIN_CHANNEL = 215  # any pixel with min(r,g,b) < this is definitely NOT bg
BG_MAX_SAT = 15       # saturated pixels are definitely icon content


def flood_remove_bg(img: Image.Image) -> Image.Image:
    img = img.convert("RGBA")
    w, h = img.size
    px = img.load()
    visited = [[False] * w for _ in range(h)]

    def is_bg(r: int, g: int, b: int) -> bool:
        return min(r, g, b) >= BG_MIN_CHANNEL and (max(r, g, b) - min(r, g, b)) <= BG_MAX_SAT

    q: deque[tuple[int, int]] = deque()
    for x in (0, w - 1):
        for y in range(h):
            q.append((x, y))
    for y in (0, h - 1):
        for x in range(w):
            q.append((x, y))

    while q:
        x, y = q.popleft()
        if x < 0 or x >= w or y < 0 or y >= h:
            continue
        if visited[y][x]:
            continue
        r, g, b, _a = px[x, y]
        if not is_bg(r, g, b):
            continue
        visited[y][x] = True
        px[x, y] = (0, 0, 0, 0)
        q.append((x + 1, y))
        q.append((x - 1, y))
        q.append((x, y + 1))
        q.append((x, y - 1))

    return img


def tight_crop_to_opaque(img: Image.Image) -> Image.Image:
    """Crop to the bbox of non-transparent pixels. Any residual shadow
    speckle that survived flood-fill (tiny enclosed pockets) still counts,
    but the bbox will be driven by the icon itself since those specks are
    always interior to or at the icon edge."""
    bbox = img.getbbox()
    if bbox is None:
        return img
    return img.crop(bbox)


def pad_to_square(img: Image.Image, margin: float = 0.05) -> Image.Image:
    """Place the cropped icon on a square transparent canvas with the given
    margin fraction on each side (0.05 = 5% padding)."""
    w, h = img.size
    side = max(w, h)
    canvas_side = int(side / (1.0 - 2 * margin))
    canvas = Image.new("RGBA", (canvas_side, canvas_side), (0, 0, 0, 0))
    ox = (canvas_side - w) // 2
    oy = (canvas_side - h) // 2
    canvas.paste(img, (ox, oy), img)
    return canvas


def build_iconset(master: Image.Image, out_dir: Path) -> None:
    out_dir.mkdir(parents=True, exist_ok=True)
    for name, size in ICONSET_SIZES:
        resized = master.resize((size, size), Image.LANCZOS)
        resized.save(out_dir / name, format="PNG")


def main(argv: list[str]) -> int:
    if len(argv) != 3:
        print(f"usage: {argv[0]} <src.png> <out.icns>", file=sys.stderr)
        return 64
    src_path = Path(argv[1])
    icns_path = Path(argv[2])

    img = Image.open(src_path)
    if img.size[0] != img.size[1]:
        print(f"warning: source is {img.size}, not square", file=sys.stderr)

    no_bg = flood_remove_bg(img)
    cropped = tight_crop_to_opaque(no_bg)
    squared = pad_to_square(cropped, margin=0.04)

    preview = src_path.with_name(src_path.stem + "-transparent.png")
    squared.save(preview, format="PNG")
    print(f"wrote preview:  {preview} ({squared.size[0]}x{squared.size[1]})")

    # Resize master to 1024 before slicing the iconset — preserves quality.
    master = squared.resize((1024, 1024), Image.LANCZOS)

    iconset_dir = icns_path.parent / (icns_path.stem + ".iconset")
    build_iconset(master, iconset_dir)
    print(f"wrote iconset:  {iconset_dir}")

    icns_path.parent.mkdir(parents=True, exist_ok=True)
    subprocess.run(
        ["iconutil", "--convert", "icns", "--output", str(icns_path), str(iconset_dir)],
        check=True,
    )
    print(f"wrote icns:     {icns_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
