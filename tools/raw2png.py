#!/usr/bin/env python3
"""raw2png.py — turn a packed 10-bit Bayer capture from CAMSS into a PNG.

Usage: raw2png.py IN.raw WIDTH HEIGHT OUT.png [FRAME]

IN.raw is what tools/camtest.sh writes (V4L2 SGRBG10P, 'pgAA': four pixels
in five bytes, MSBs first, LSB pairs in the fifth byte). Bytes per line are
WIDTH*5/4 rounded up to 16 as CAMSS reports them. FRAME picks a frame from a
multi-frame file (default 0). The output is a quarter-size, percentile
stretched, gamma 2.2 half-resolution debayer of the GRBG mosaic: a picture to
look at, not calibrated data. Prints min, max, mean, std of the raw 10-bit
values first so a flat or clipped frame is visible before the PNG is opened.
"""
import sys
import numpy as np
from PIL import Image

inp, w, h, out = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), sys.argv[4]
frame = int(sys.argv[5]) if len(sys.argv) > 5 else 0
bpl = -(-(w * 5 // 4) // 16) * 16
size = bpl * h
raw = np.fromfile(inp, dtype=np.uint8, count=size, offset=frame * size)
raw = raw.reshape(h, bpl)[:, :w * 5 // 4].reshape(h, -1, 5).astype(np.uint16)
p = np.empty((h, w), np.uint16)
for i in range(4):
    p[:, i::4] = (raw[:, :, i] << 2) | ((raw[:, :, 4] >> (2 * i)) & 3)
print(f"raw10 min {p.min()} max {p.max()} mean {p.mean():.1f} std {p.std():.1f}")
g = (p[0::2, 0::2].astype(np.float32) + p[1::2, 1::2]) / 2
r = p[0::2, 1::2].astype(np.float32)
b = p[1::2, 0::2].astype(np.float32)
img = np.stack([r, g, b], -1)
lo, hi = np.percentile(img, [0.5, 99.5])
img = np.clip((img - lo) / max(hi - lo, 1), 0, 1) ** (1 / 2.2)
Image.fromarray((img * 255).astype(np.uint8)).resize((w // 4, h // 4)).save(out)
print(f"wrote {out}")
