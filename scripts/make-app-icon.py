#!/usr/bin/env python3
"""Regenerate the app icon (Resources/AppIcon.icns) from the 1024 master.

Source master:  Resources/icon-src/app/icon_1024.png  (a scallop shell + bolt on
a dark squircle, pre-rendered with the macOS icon shape baked in).
Produces the Apple .iconset (all sizes/resolutions) next to the master, then
runs `iconutil` to pack it into Resources/AppIcon.icns. build.sh copies that
.icns into the bundle; App-Info.plist's CFBundleIconFile=AppIcon points at it.

Usage:  python3 scripts/make-app-icon.py
Requires: Pillow (PIL) + macOS `iconutil`.
"""
import os
import subprocess
from PIL import Image

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
APP_DIR = os.path.join(ROOT, "Resources/icon-src/app")
MASTER = os.path.join(APP_DIR, "icon_1024.png")
ICONSET = os.path.join(APP_DIR, "AppIcon.iconset")
ICNS = os.path.join(ROOT, "Resources/AppIcon.icns")

# Apple .iconset member -> pixel size.
MAPPING = {
    "icon_16x16.png": 16,      "icon_16x16@2x.png": 32,
    "icon_32x32.png": 32,      "icon_32x32@2x.png": 64,
    "icon_128x128.png": 128,   "icon_128x128@2x.png": 256,
    "icon_256x256.png": 256,   "icon_256x256@2x.png": 512,
    "icon_512x512.png": 512,   "icon_512x512@2x.png": 1024,
}


def main():
    master = Image.open(MASTER).convert("RGBA")
    os.makedirs(ICONSET, exist_ok=True)
    for name, size in MAPPING.items():
        master.resize((size, size), Image.LANCZOS).save(os.path.join(ICONSET, name))
    subprocess.run(["iconutil", "-c", "icns", "-o", ICNS, ICONSET], check=True)
    print(f"wrote {os.path.relpath(ICNS, ROOT)} from {len(MAPPING)} iconset members")


if __name__ == "__main__":
    main()
