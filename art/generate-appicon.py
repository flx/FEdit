#!/usr/bin/env python3
"""(app-icon-knockout) Regenerate FEdit's AppIcon.appiconset from the 1024 source.

    python3 art/generate-appicon.py

Reads art/fedit-4-knockout-1024.png and writes the seven PNGs
AppIcon.appiconset/Contents.json already names. Contents.json is NOT touched:
its ten entries map onto these seven filenames, and the filenames are the
contract.

The source is already drawn on Apple's macOS large-icon grid — its opaque
bounding box is (100,100)-(924,924), i.e. 824x824 within a 1024 canvas — so
every size here is a straight proportional downscale with no re-inset. Lanczos,
because the artwork is a hard-edged knockout and a box filter visibly softens
the counter of the F at 32 pt and below.
"""

import pathlib
import sys

from PIL import Image

ROOT = pathlib.Path(__file__).resolve().parent.parent
SOURCE = ROOT / "art" / "fedit-4-knockout-1024.png"
DEST = ROOT / "FEdit" / "Assets.xcassets" / "AppIcon.appiconset"
SIZES = [16, 32, 64, 128, 256, 512, 1024]


def main() -> int:
    if not SOURCE.exists():
        print(f"missing source: {SOURCE}", file=sys.stderr)
        return 1
    if not DEST.is_dir():
        print(f"missing appiconset: {DEST}", file=sys.stderr)
        return 1

    src = Image.open(SOURCE).convert("RGBA")
    if src.size != (1024, 1024):
        print(f"source must be 1024x1024, got {src.size}", file=sys.stderr)
        return 1

    for size in SIZES:
        out = DEST / f"icon_{size}.png"
        img = src if size == 1024 else src.resize((size, size), Image.LANCZOS)
        img.save(out, format="PNG", optimize=True)
        print(f"wrote {out.relative_to(ROOT)}  {size}x{size}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
