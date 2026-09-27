#!/usr/bin/env python3
"""Generate the tileable noise texture used by FauxTracer.

Writes pack/shaders/lib/tex/noise.png (256x256 RGBA8, seamlessly tileable):

  R  tileable fBm value noise   - cloud base shape, terrain breakup
  G  tileable ridged noise      - cloud detail erosion, aurora filaments
  B  decorrelated fBm           - wind offsets, star density masks
  A  white noise                - dithering, sparse high frequency detail

No third party dependencies: PNG is emitted with zlib + struct.
Each octave lattice is built once and reused for the whole image, so the whole
texture generates in a couple of seconds.
"""

import math
import os
import struct
import zlib

SIZE = 256
HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "..", "pack", "shaders", "lib", "tex", "noise.png")


def make_lattice(period, seed):
    """period x period grid of random values in [0,1)."""
    rng = _Lcg(seed)
    return [[rng.next() for _ in range(period)] for _ in range(period)]


class _Lcg:
    def __init__(self, seed):
        self.s = seed & 0x7FFFFFFF or 1

    def next(self):
        self.s = (1103515245 * self.s + 12345) & 0x7FFFFFFF
        return self.s / 0x7FFFFFFF


def smooth(t):
    # quintic fade -> C2 continuous, no visible lattice creases
    return t * t * t * (t * (t * 6.0 - 15.0) + 10.0)


def build_channel(octaves, base, seed, ridged, uoff, voff):
    """Accumulate a normalised fBm over the whole image, octave by octave."""
    acc = [0.0] * (SIZE * SIZE)
    norm = 0.0
    amp = 1.0
    period = base
    for o in range(octaves):
        lat = make_lattice(period, seed * 7919 + o * 104729 + 1)
        for j in range(SIZE):
            fy = ((j + 0.5) / SIZE + voff) * period
            y0 = int(fy) % period
            y1 = (y0 + 1) % period
            ty = smooth(fy - int(fy))
            rowA, rowB = lat[y0], lat[y1]
            base_i = j * SIZE
            for i in range(SIZE):
                fx = ((i + 0.5) / SIZE + uoff) * period
                x0 = int(fx) % period
                x1 = (x0 + 1) % period
                tx = smooth(fx - int(fx))
                a = rowA[x0] + (rowA[x1] - rowA[x0]) * tx
                b = rowB[x0] + (rowB[x1] - rowB[x0]) * tx
                n = a + (b - a) * ty
                if ridged:
                    n = 1.0 - abs(2.0 * n - 1.0)
                    n *= n
                acc[base_i + i] += amp * n
        norm += amp
        amp *= 0.5
        period *= 2
    inv = 1.0 / norm
    for k in range(len(acc)):
        acc[k] *= inv
    return acc


def main():
    r = build_channel(6, 4, 0x1234ABCD, False, 0.0, 0.0)
    g = build_channel(5, 6, 0x1234ABCD + 31, True, 0.5, 0.5)
    b = build_channel(5, 3, 0x1234ABCD + 977, False, 0.0, 0.25)

    rng = _Lcg(0x5EEDBEEF)
    px = bytearray(SIZE * SIZE * 4)
    for k in range(SIZE * SIZE):
        px[k * 4 + 0] = min(255, int(r[k] * 255.0 + 0.5))
        px[k * 4 + 1] = min(255, int(g[k] * 255.0 + 0.5))
        px[k * 4 + 2] = min(255, int(b[k] * 255.0 + 0.5))
        px[k * 4 + 3] = min(255, int(rng.next() * 255.0 + 0.5))

    raw = bytearray()
    stride = SIZE * 4
    for j in range(SIZE):
        raw.append(0)  # filter type 0 (None)
        raw += px[j * stride : (j + 1) * stride]

    def chunk(tag, data):
        return (
            struct.pack(">I", len(data))
            + tag
            + data
            + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF)
        )

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
