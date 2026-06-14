#!/usr/bin/env python3
"""Regenerate the menu-bar status glyphs from the clam art pack.

Source art lives in Resources/icon-src/menubar/ as six 1024x1024 PNGs:
  clam.{light,dark}.{off,on.bolt,on.remote}.png
  - "light" art is black-on-transparent (drawn for a light menu bar)
  - "dark"  art is white-on-transparent (drawn for a dark menu bar)
The three states are off (outline shell = asleep), on.bolt (filled shell +
lightning = the user is holding sleep open), on.remote (filled shell + remote =
an automatic signal is holding it).

All six are drawn on the same canvas with the same content bounding box, so we
crop every image to the *union* bbox (one rectangle) before resizing. That keeps
the three states identically framed in the menu bar — no per-image trim drift.

Output (Resources/, consumed by MenuBarController.statusImage):
  clam-{off,bolt,remote}-{light,dark}.png   (height 144, aspect preserved)

MenuBarController draws the "light" (black) art as a *template* for the System
theme (the menu bar tints it per appearance) and as-is for the Light theme; the
"dark" (white) art is used as-is for the Dark theme.

Usage:  python3 scripts/make-menubar-icons.py
Requires: Pillow (PIL).
"""
import os
from PIL import Image

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC_DIR = os.path.join(ROOT, "Resources/icon-src/menubar")
OUT_DIR = os.path.join(ROOT, "Resources")
OUT_HEIGHT = 144   # NSImage downscales to ~18pt; 144 keeps Retina crisp.

# source filename -> bundled output name
MAP = {
    "clam.light.off.png":       "clam-off-light.png",
    "clam.light.on.bolt.png":   "clam-bolt-light.png",
    "clam.light.on.remote.png": "clam-remote-light.png",
    "clam.dark.off.png":        "clam-off-dark.png",
    "clam.dark.on.bolt.png":    "clam-bolt-dark.png",
    "clam.dark.on.remote.png":  "clam-remote-dark.png",
}


def union_bbox(images):
    box = None
    for im in images:
        b = im.split()[-1].getbbox()   # alpha-channel content box
        if b is None:
            continue
        box = b if box is None else (
            min(box[0], b[0]), min(box[1], b[1]),
            max(box[2], b[2]), max(box[3], b[3]))
    return box


def main():
    loaded = {src: Image.open(os.path.join(SRC_DIR, src)).convert("RGBA")
              for src in MAP}
    box = union_bbox(loaded.values())
    if box is None:
        raise SystemExit("no content found in source PNGs")
    cw, ch = box[2] - box[0], box[3] - box[1]
    out_w = round(cw * OUT_HEIGHT / ch)
    print(f"union bbox {box} ({cw}x{ch}) -> {out_w}x{OUT_HEIGHT}")
    for src, dst in MAP.items():
        im = loaded[src].crop(box).resize((out_w, OUT_HEIGHT), Image.LANCZOS)
        im.save(os.path.join(OUT_DIR, dst))
        print(f"  {dst}")


if __name__ == "__main__":
    main()
