#!/usr/bin/env python3
"""Shrink recipe images for the built site; the originals in _recipes/ are never touched.

Usage: optimize_images.py SRC_DIR DEST_DIR

Writes a downscaled copy of every jpg/png in SRC_DIR over its already-copied
counterpart in DEST_DIR, plus a small thumbnail in DEST_DIR/thumbs/ for the index
pages. Anything this script cannot process is left as copied, and its thumbnail
falls back to the full-size file so links never break.
"""
import os
import shutil
import sys

from PIL import Image, ImageOps

FULL_MAX = 1200
THUMB_MAX = 300
EXTENSIONS = {".jpg": "JPEG", ".jpeg": "JPEG", ".png": "PNG"}


def save(img, path, fmt, quality):
    if fmt == "JPEG":
        if img.mode not in ("RGB", "L"):
            img = img.convert("RGB")
        img.save(path, "JPEG", quality=quality, optimize=True, progressive=True)
    else:
        img.save(path, "PNG", optimize=True)


def process(src, dest, thumb, fmt):
    with Image.open(src) as opened:
        img = ImageOps.exif_transpose(opened)
        img.load()

    full = img.copy()
    full.thumbnail((FULL_MAX, FULL_MAX), Image.LANCZOS)
    tmp = dest + ".tmp"
    save(full, tmp, fmt, 82)
    if os.path.getsize(tmp) < os.path.getsize(src):
        os.replace(tmp, dest)
    else:
        os.remove(tmp)  # already small and well compressed, keep the original

    small = img.copy()
    small.thumbnail((THUMB_MAX, THUMB_MAX), Image.LANCZOS)
    save(small, thumb, fmt, 75)
    if os.path.getsize(thumb) >= os.path.getsize(dest):
        shutil.copyfile(dest, thumb)


def main():
    src_dir, dest_dir = sys.argv[1], sys.argv[2]
    thumb_dir = os.path.join(dest_dir, "thumbs")
    os.makedirs(thumb_dir, exist_ok=True)

    before = after = count = failed = 0
    for name in sorted(os.listdir(src_dir)):
        fmt = EXTENSIONS.get(os.path.splitext(name)[1].lower())
        if fmt is None:
            continue
        src = os.path.join(src_dir, name)
        dest = os.path.join(dest_dir, name)
        thumb = os.path.join(thumb_dir, name)
        before += os.path.getsize(src)
        try:
            process(src, dest, thumb, fmt)
            count += 1
        except Exception as error:
            failed += 1
            print(f"  could not optimize {name}: {error}", file=sys.stderr)
            shutil.copyfile(src, dest)
            shutil.copyfile(src, thumb)
        after += os.path.getsize(dest)

    print(f"Optimized {count} images ({before / 1e6:.1f} MB -> {after / 1e6:.1f} MB), {failed} failed")


if __name__ == "__main__":
    main()
