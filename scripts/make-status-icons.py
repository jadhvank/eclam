#!/usr/bin/env python3
"""Regenerate menu bar status template icons from the raw black-on-white art.

Source art lives in Resources/icon-src/ (opaque black-on-white PNGs).
This converts luminance -> alpha (black = opaque, white = transparent, edges =
partial alpha) so the result is a proper macOS template image: MenuBarController
sets isTemplate=true and the menu bar tints the opaque pixels, with the lightning
bolt / background showing through as transparent cutouts.

Usage:  python3 scripts/make-status-icons.py
Requires: Pillow (PIL).
"""
import os
from PIL import Image

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PAIRS = [
    ("Resources/icon-src/eclam_on.png",  "Resources/status-on.png"),
    ("Resources/icon-src/eclam_off.png", "Resources/status-off.png"),
]
OUT_HEIGHT = 144   # NSImage downscales to ~18pt; 144 keeps Retina crisp.
TRIM_THRESH = 12   # alpha above this counts as content when cropping whitespace.


def make_template(src, dst):
    im = Image.open(os.path.join(ROOT, src)).convert("L")
    alpha = im.point(lambda p: 255 - p)            # darkness -> alpha
    black = Image.new("L", im.size, 0)
    rgba = Image.merge("RGBA", (black, black, black, alpha))
    mask = alpha.point(lambda p: 255 if p > TRIM_THRESH else 0)
    bbox = mask.getbbox()
    if bbox:
        rgba = rgba.crop(bbox)
    cw, ch = rgba.size
    rgba = rgba.resize((round(cw * OUT_HEIGHT / ch), OUT_HEIGHT), Image.LANCZOS)
    rgba.save(os.path.join(ROOT, dst))
    print(f"{dst}: trimmed {bbox} -> {rgba.size[0]}x{rgba.size[1]}")


if __name__ == "__main__":
    for src, dst in PAIRS:
        make_template(src, dst)
