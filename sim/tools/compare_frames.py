#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
# Taito B System core for MiSTer - simulation helper.
#
# Compare two captured frames under a transform:
#   compare_frames.py rot180 A.ppm B.ppm      B must equal A turned 180 degrees
#   compare_frames.py same   A.ppm B.ppm      B must equal A
#   compare_frames.py rot90cw  NATIVE.ppm FB.ppm   FB = NATIVE turned 90 clockwise
#   compare_frames.py rot90ccw NATIVE.ppm FB.ppm   FB = NATIVE turned 90 counter-clockwise
# Prints the number of differing pixels and their bounding box; exit status 1 if any
# differ (or the sizes do not fit the transform). --png writes a side-by-side image.
import argparse, sys
from PIL import Image, ImageChops

ap = argparse.ArgumentParser()
ap.add_argument("mode", choices=["rot180", "same", "rot90cw", "rot90ccw"])
ap.add_argument("a")
ap.add_argument("b")
ap.add_argument("--png")
ap.add_argument("--label", default="")
args = ap.parse_args()

a = Image.open(args.a).convert("RGB")
b = Image.open(args.b).convert("RGB")
t = {"rot180": lambda im: im.transpose(Image.ROTATE_180),
     "same": lambda im: im,
     "rot90cw": lambda im: im.transpose(Image.ROTATE_270),   # PIL rotates counter-clockwise
     "rot90ccw": lambda im: im.transpose(Image.ROTATE_90)}[args.mode](a)

if t.size != b.size:
    print(f"{args.label} {args.mode}: size mismatch {t.size} vs {b.size}")
    sys.exit(1)
diff = ImageChops.difference(t, b).convert("L").point(lambda v: 255 if v else 0)
n = sum(1 for v in diff.getdata() if v)
nonblack = sum(1 for p in b.getdata() if p != (0, 0, 0))
print(f"{args.label} {args.mode}: {b.size[0]}x{b.size[1]}, {nonblack} non-black pixels, "
      f"{n} differ, bbox {diff.getbbox()}")
if args.png:
    w, h = b.size
    out = Image.new("RGB", (w * 3 + 8, h), (40, 0, 40))
    out.paste(t, (0, 0)); out.paste(b, (w + 4, 0)); out.paste(diff.convert("RGB"), (2 * w + 8, 0))
    out.save(args.png)
sys.exit(1 if n else 0)
