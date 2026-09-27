#!/usr/bin/env python3
"""Generate FauxTracer's pack.png.

A 128x128 icon: dark sky gradient, a starfield, an aurora ribbon and a low sun.
Written with zlib + struct so the build has no third party dependencies.
"""

import math
import os
import struct
import zlib

SIZE = 128
HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "..", "vitrail", "pack.png")


def clamp01(x):
    return max(0.0, min(1.0, x))


def smoothstep(a, b, x):
    t = clamp01((x - a) / (b - a))
    return t * t * (3.0 - 2.0 * t)


def hash21(x, y):
    n = math.sin(x * 127.1 + y * 311.7) * 43758.5453
    return n - math.floor(n)


def main():
    px = bytearray(SIZE * SIZE * 4)

    for j in range(SIZE):
        v = (j + 0.5) / SIZE
        for i in range(SIZE):
            u = (i + 0.5) / SIZE

            # ---- sky: deep blue zenith into a warm dusk horizon -------------
            t = clamp01(1.0 - v)
            zenith = (0.020, 0.035, 0.085)
            horizon = (0.320, 0.140, 0.075)
            col = [zenith[k] * t + horizon[k] * (1.0 - t) for k in range(3)]

            # ---- aurora ribbon --------------------------------------------
            # A vertical curtain whose horizontal position wobbles with height.
            band = math.exp(-(((u - 0.52) + 0.13 * math.sin(v * 5.0)) * 6.2) ** 2)
            height = smoothstep(0.02, 0.22, v) * (1.0 - smoothstep(0.42, 0.92, v))
            rays = 0.55 + 0.45 * math.sin(u * 78.0 + math.sin(v * 9.0) * 2.2)
            aurora = band * height * rays
            col[0] += 0.10 * aurora
            col[1] += 0.85 * aurora
            col[2] += 0.45 * aurora

            # ---- sun disc, low and warm ------------------------------------
            d = math.hypot((u - 0.34) * 1.0, (v - 0.74) * 1.0)
            disc = 1.0 - smoothstep(0.055, 0.068, d)
            halo = math.exp(-((d / 0.30) ** 2)) * 0.45
            col[0] += disc * 1.00 + halo * 0.95
            col[1] += disc * 0.72 + halo * 0.42
            col[2] += disc * 0.38 + halo * 0.18

            # ---- stars -----------------------------------------------------
            star = 0.0
            for cell in range(3):
                scale = 26.0 * (cell + 1)
                gx, gy = u * scale, v * scale
                cx, cy = math.floor(gx), math.floor(gy)
                h = hash21(cx + cell * 17.0, cy - cell * 31.0)
                if h < 0.90:
                    continue
                sx = cx + 0.2 + hash21(cx * 1.7, cy * 2.3) * 0.6
                sy = cy + 0.2 + hash21(cx * 3.1, cy * 1.9) * 0.6
                sd = math.hypot(gx - sx, gy - sy)
                star += max(0.0, 1.0 - sd / 0.55) * (0.5 + 0.5 * h) / (cell + 1)
            # Stars are washed out by the aurora and the sun.
            star *= (1.0 - clamp01(aurora * 1.6)) * (1.0 - smoothstep(0.10, 0.42, d))
            col[0] += star * 0.85
            col[1] += star * 0.90
            col[2] += star

            # ---- water: dark, with the sky reflected ----------------------
            if v > 0.80:
                w = (v - 0.80) / 0.20
                ripple = 0.5 + 0.5 * math.sin(u * 60.0 + math.sin(v * 40.0) * 1.6)
                water = [0.030 + 0.020 * ripple, 0.070 + 0.045 * ripple, 0.110 + 0.070 * ripple]
                # A soft vertical smear of the sun into the water.
                smear = math.exp(-((u - 0.34) / 0.16) ** 2) * (1.0 - w) * 0.55
                water[0] += smear * 0.90
                water[1] += smear * 0.48
                water[2] += smear * 0.22
                col = [col[k] * (1.0 - w) + water[k] * w for k in range(3)]

            # ---- vignette --------------------------------------------------
            cx, cy = u - 0.5, v - 0.5
            vig = 1.0 - smoothstep(0.42, 0.78, math.hypot(cx, cy)) * 0.45
            col = [c * vig for c in col]

            # ---- frame -----------------------------------------------------
            edge = min(u, 1.0 - u, v, 1.0 - v)
            if edge < 0.022:
                col = [0.02, 0.02, 0.03]

            px[(j * SIZE + i) * 4 + 0] = max(0, min(255, int(pow(clamp01(col[0]), 1 / 2.2) * 255 + 0.5)))
            px[(j * SIZE + i) * 4 + 1] = max(0, min(255, int(pow(clamp01(col[1]), 1 / 2.2) * 255 + 0.5)))
            px[(j * SIZE + i) * 4 + 2] = max(0, min(255, int(pow(clamp01(col[2]), 1 / 2.2) * 255 + 0.5)))
            px[(j * SIZE + i) * 4 + 3] = 255

    raw = bytearray()
    stride = SIZE * 4
    for j in range(SIZE):
        raw.append(0)
        raw += px[j * stride : (j + 1) * stride]

    def chunk(tag, data):
        return (struct.pack(">I", len(data)) + tag + data
                + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF))

    png = b"\x89PNG\r\n\x1a\n"
    png += chunk(b"IHDR", struct.pack(">IIBBBBB", SIZE, SIZE, 8, 6, 0, 0, 0))
    png += chunk(b"IDAT", zlib.compress(bytes(raw), 9))
    png += chunk(b"IEND", b"")

    out = os.path.abspath(OUT)
    os.makedirs(os.path.dirname(out), exist_ok=True)
    with open(out, "wb") as f:
        f.write(png)
    print("wrote", out, len(png), "bytes")


if __name__ == "__main__":
    main()
