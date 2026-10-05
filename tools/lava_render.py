#!/usr/bin/env python3
"""Render the lava albedo offline, and measure whether it is lava or gold.

lib/lava.glsl cannot be looked at from here - it needs a GPU, a running game and
an actual lava pool - and the first version of it was shipped on the strength of
reasoning about a colour ramp and came out looking like poured gold. So this
renders the same maths in NumPy and writes a PNG, which settles the question
without either of those.

It reads the LAVA_* values out of shaders/lib/settings.glsl rather than taking
them as arguments, so the preview cannot drift away from the pack: if a default
is changed in settings.glsl and this is not re-run, that is a bug worth
knowing about, and the alternative - a second copy of the numbers in a Python
file - would drift silently.

Two things are measured, because "does it look right" is not a measurement:

  * **G/R and B/R across the whole surface.** This is the whole gold question.
    Gold is high red AND high green with almost no blue - linear (1.0, 0.83,
    0.0). Orange lava is high red with green around 0.4. So the number that
    matters is the green ratio, and a surface whose median G/R is much above
    about 0.55 is going to read as metal rather than as rock no matter how
    orange it looks in isolation.
  * **The spread**, so a surface that is technically lava-coloured but almost
    all one value is caught. Real lava is mostly dark crust with a small bright
    minority; a low median with a high p99 is the target.

Usage:
    python3 tools/lava_render.py
    python3 tools/lava_render.py --size 512 --settings shaders/lib/settings.glsl
"""

import argparse
import math
import os
import re
import struct
import sys
import zlib

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
PACK = os.environ.get("FX_PACK") or os.path.join(ROOT, "shaders")

# rot(1.0) = mat2(cos, -sin, sin, cos), column-major, so -1 radian.
_COS1 = math.cos(1.0)
_SIN1 = math.sin(1.0)
# Must track LAVA_OCTAVES_MAX in lib/lava.glsl. It was left at 16 when the cap
# moved to 8, which made this renderer quietly draw more octaves than the shader
# runs - a preview that disagrees with the thing it is previewing.
OCTAVES_MAX = 8


def read_settings(path):
    """Pull the LAVA_* scalars out of settings.glsl.

    Returns (values, enabled). Missing or commented-out options come back as
    None, which is reported rather than defaulted - a preview of a disabled
    feature is worth knowing about.
    """
    want = (
        "LAVA_TILE",
        "LAVA_SPEED",
        "LAVA_CRUST_LEVEL",
        "LAVA_CRACK_WIDTH",
        "LAVA_SEAM",
        "LAVA_VARIATION",
        "LAVA_GLOW",
    )
    out = {k: None for k in want}
    enabled = False
    with open(path) as fh:
        for line in fh:
            s = line.strip()
            if s.startswith("#define LAVA") and len(s) > len("#define LAVA"):
                m = re.match(r"#define\s+(\w+)\s+([-\d.]+)", s)
                if m and m.group(1) in out:
                    out[m.group(1)] = float(m.group(2))
            elif s == "#define LAVA":
                enabled = True
    return out, enabled


def getlava(x, t, octaves):
    """Port of getlava() in lib/lava.glsl."""
    x = x.copy()
    col = np.zeros((3,) + x.shape[1:])
    for i in range(octaves):
        x = x * 1.5
        x[0] += t / 64.0
        x = np.array([_COS1 * x[0] + _SIN1 * x[1], -_SIN1 * x[0] + _COS1 * x[1]])
        w = (np.sin(x[0] + x[1] + x[0] * 2.0 - t / 4.0) + np.cos(x[0] * 4.0)) / 16.0
        x = x + w
        fi = float(i)
        col[0] += np.sin(x[0] * 2.0) * np.cos(x[1] + t)
        col[1] += np.cos(x[0] + x[1] - np.cos(x[0] - x[1] + t * fi - x[1] + x[0] * 4.0))
        col[2] += np.cos(x[0] + x[1] + t + np.cos(x[0] - x[1]) + t)
    return col


def heat(x, t, octaves):
    return np.sqrt((getlava(x, t, octaves) ** 2).sum(axis=0)) / (2.0 * math.sqrt(octaves))


def lava_ramp(h):
    """Port of lavaRamp() in lib/lava.glsl."""
    def mix(a, b, e):
        e = e[..., None] if e.ndim == h.ndim else e
        return a * (1.0 - e) + b * e

    def ss(a, b, x):
        u = np.clip((x - a) / (b - a), 0.0, 1.0)
        return u * u * (3.0 - 2.0 * u)

    c = np.broadcast_to(np.array([0.012, 0.010, 0.009]), h.shape + (3,)).copy()
    c = mix(c, (0.090, 0.014, 0.003), ss(0.00, 0.42, h))
    c = mix(c, (0.420, 0.070, 0.006), ss(0.38, 0.62, h))
    c = mix(c, (0.850, 0.190, 0.016), ss(0.58, 0.80, h))
    c = mix(c, (1.000, 0.380, 0.045), ss(0.76, 0.93, h))
    c = mix(c, (1.000, 0.620, 0.170), ss(0.90, 1.00, h))
    return c


WALL_STRETCH = 0.5
COARSE_OCTAVES = 2
COARSE_MEAN = 0.4441
COARSE_STD = 0.2019


def lava_surface(p2, normal, cfg, octaves, t, px_blocks):
    """Port of lavaSurface() in lib/lava.glsl, for a 2D field coordinate.

    px_blocks is the world-space size of one pixel, which the shader gets from
    fwidth() and which sets both the gradient step and the LOD.
    """
    def ss(a, b, x):
        u = np.clip((x - a) / (b - a), 0.0, 1.0)
        return u * u * (3.0 - 2.0 * u)

    upness = ss(0.15, 0.55, normal[1])
    # blocks per field unit - the direction of this conversion is the whole point
    # of the name, see lavaBlocksPerFieldUnit in lib/lava.glsl.
    blocks_per_unit = (cfg["LAVA_TILE"] * math.sqrt(WALL_STRETCH)) * upness + (
        cfg["LAVA_TILE"]
    ) * (1.0 - upness)

    h = heat(p2, t, octaves)

    # The spatial gradient, differenced over one pixel. This is the fix: the
    # crack width is in blocks, not in field value, so the threshold is divided
    # by |grad h| before it is used.
    step = max(px_blocks / blocks_per_unit, 1e-5)
    off_x = np.zeros_like(p2)
    off_x[0] = step
    off_y = np.zeros_like(p2)
    off_y[1] = step
    hx = heat(p2 + off_x, t, octaves)
    hz = heat(p2 + off_y, t, octaves)
    grad = np.sqrt((hx - h) ** 2 + (hz - h) ** 2) / step
    grad = np.maximum(grad, 1e-5)

    cw = cfg["LAVA_CRACK_WIDTH"]

    # The coarse field, on a quarter-scale domain, offsets the crust level so
    # that whole regions of a pool run crusty and whole regions run molten.
    coarse = (
        heat(p2 * 0.25, t * 0.6, COARSE_OCTAVES) - COARSE_MEAN
    ) / COARSE_STD
    level = cfg["LAVA_CRUST_LEVEL"] + coarse * cfg["LAVA_VARIATION"]

    dist = (h - level) / grad * blocks_per_unit

    seam = 1.0 - ss(0.0, cw, np.abs(dist))
    heatv = ss(-cw * 2.0, cw * 2.0, dist)

    col = lava_ramp(heatv)
    seam_w = seam * cfg["LAVA_SEAM"]
    col = col * (1.0 - seam_w[..., None]) + lava_ramp(
        np.minimum(heatv + 0.32, 1.0)
    ) * (seam_w[..., None])

    col = col * (mix_scalar(0.75 + 0.5 * (h / np.maximum(level, 1e-4)), 1.0, heatv))[..., None]

    wall_w = (1.0 - upness) * 0.6
    col = col * (1.0 - wall_w[..., None]) + lava_ramp(
        np.minimum(heatv + 0.28, 1.0)
    ) * (wall_w[..., None])

    return col * cfg["LAVA_GLOW"]


def mix_scalar(a, b, e):
    return a * (1.0 - e) + b * e


def write_png(path, rgb):
    h, w, _ = rgb.shape
    px = bytearray()
    for j in range(h):
        px.append(0)
        for i in range(w):
            px += bytes(rgb[j, i])

    def chunk(tag, data):
        return (
            struct.pack(">I", len(data))
            + tag
            + data
            + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF)
        )

    png = b"\x89PNG\r\n\x1a\n"
    png += chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0))
    png += chunk(b"IDAT", zlib.compress(bytes(px), 9))
    png += chunk(b"IEND", b"")
    with open(path, "wb") as fh:
        fh.write(png)
    return len(png)


def to_srgb(lin):
    lin = np.clip(lin, 0.0, 1.0)
    return np.where(lin <= 0.0031308, lin * 12.92, 1.055 * lin ** (1 / 2.4) - 0.055)


def tonemap(col):
    """The pack's tonemap, so the preview shows what the screen shows."""
    luma = col @ np.array([0.21, 0.72, 0.07])
    return col / (1.0 + luma[..., None])


def grid(n, span):
    a = np.linspace(0.0, span, n, endpoint=False)
    xx, yy = np.meshgrid(a, a)
    return np.array([xx, yy])


def report(name, col):
    lum = col @ np.array([0.21, 0.72, 0.07])
    r = col[..., 0]
    g = col[..., 1]
    b = col[..., 2]
    print("\n  %s" % name)
    print("    luminance   p10 %.4f  p50 %.4f  p90 %.4f  p99 %.4f"
          % (np.percentile(lum, 10), np.percentile(lum, 50),
             np.percentile(lum, 90), np.percentile(lum, 99)))

    # Only the molten pixels. A channel ratio on a near-black pixel is
    # meaningless - dividing 0.010 by 0.012 gives 0.83 on the cold crust, which
    # is exactly gold's green ratio and made the first version of this check
    # report a pass on a surface that was 81% crust and measuring the rock.
    hot = lum > 0.10
    frac = 100.0 * float(hot.mean())
    if not hot.any():
        print("    no molten pixels at all - nothing to measure a hue on")
        return
    hr, hg, hb = r[hot], g[hot], b[hot]
    gr = hg / np.maximum(hr, 1e-6)
    br = hb / np.maximum(hr, 1e-6)
    print("    molten pixels: %.0f%% of the surface (the other %.0f%% is crust)"
          % (frac, 100.0 - frac))
    print("    G/R on molten  p50 %.3f  p90 %.3f  max %.3f   <- gold is ~0.83"
          % (np.percentile(gr, 50), np.percentile(gr, 90), gr.max()))
    print("    B/R on molten  p50 %.3f  p90 %.3f  max %.3f   <- gold is ~0.00"
          % (np.percentile(br, 50), np.percentile(br, 90), br.max()))
    med = float(np.percentile(gr, 50))
    if med < 0.45:
        verdict = "deep red-orange, reads as lava"
    elif med < 0.58:
        verdict = "orange, acceptable - hot but not gold"
    elif med < 0.72:
        verdict = "amber - drifting toward brass, turn LAVA_SEAM down"
    else:
        verdict = "TOO GREEN - reads as poured gold"
    print("    -> median G/R %.3f on molten: %s" % (med, verdict))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--size", type=int, default=384)
    ap.add_argument("--span", type=float, default=None, help="blocks across; default LAVA_TILE * 2")
    ap.add_argument("--octaves", type=int, default=OCTAVES_MAX)
    ap.add_argument("--t", type=float, default=0.0)
    ap.add_argument("--out", default=os.path.join(HERE, "lava_preview.png"))
    ap.add_argument("--fps", type=float, default=60.0)
    ap.add_argument(
        "--mode",
        choices=("render", "motion", "sheet", "sweep"),
        default="render",
        help="render: albedo + G/R report. motion: per-frame change vs SPEED.",
    )
    ap.add_argument("--settings", default=os.path.join(PACK, "lib", "settings.glsl"))
    args = ap.parse_args()

    if args.mode == "motion":
        return motion(args)
    if args.mode == "sheet":
        return sheet(args)
    if args.mode == "sweep":
        return sweep(args)

    cfg, enabled = read_settings(args.settings)
    print("lava_render: reading %s" % args.settings)
    if not enabled:
        print("  WARNING: LAVA is not #defined in settings.glsl - the pack has it off.")
    missing = [k for k, v in cfg.items() if v is None]
    if missing:
        print("  WARNING: no value found for %s - the preview is incomplete." % ", ".join(missing))
        return 1
    for k in sorted(cfg):
        print("  %-20s %s" % (k, cfg[k]))

    span = args.span if args.span else cfg["LAVA_TILE"] * 2.0
    print("\n  rendering %dx%d over %.1f blocks, %d octaves, t=%.2f"
          % (args.size, args.size, span, args.octaves, args.t))

    # One pixel, in world blocks, for the preview's field of view. The preview
    # stands in for a camera looking at this many blocks across the span, so a
    # pixel is span/size. This is what the shader would get from fwidth().
    px_blocks = span / args.size

    # Top face: normal is straight up, and the field is read in world XZ.
    top_p = grid(args.size, span) / cfg["LAVA_TILE"]
    top = lava_surface(
        top_p, (0.0, 1.0, 0.0), cfg, args.octaves, args.t * cfg["LAVA_SPEED"], px_blocks
    )

    # Wall: normal along +X, so `along` is +Z and the horizontal axis is world
    # Z, independent of Y; the vertical axis is Y, compressed by the stretch.
    # This is the projection that was missing entirely in the first version.
    #
    # Axis 0 must be the VERTICAL one and axis 1 the horizontal one, matching
    # lavaWallProjection()'s vec2(dot(worldPos.xz, along), worldPos.y * ...).
    # Getting that backwards made both axes a function of y, which rendered as
    # horizontal stripes - and it was the test harness that was wrong, not the
    # shader, which is worth establishing before trusting a preview again.
    g = grid(args.size, span)
    wall_p = np.array([g[1] * WALL_STRETCH, g[0]]) / cfg["LAVA_TILE"]
    wall = lava_surface(
        wall_p, (1.0, 0.0, 0.0), cfg, args.octaves, args.t * cfg["LAVA_SPEED"], px_blocks
    )

    report("top face", top)
    report("wall face", wall)

    both = np.concatenate([top, wall], axis=1)
    img = (to_srgb(tonemap(both)) * 255.0 + 0.5).astype(np.uint8)
    n = write_png(args.out, img)
    print("\n  wrote %s (%d bytes, %dx%d, tonemapped)"
          % (args.out, n, img.shape[1], img.shape[0]))
    return 0


def perframe(p, octaves, speed, fps):
    """RMS of h(t+dt) - h(t), over the field's standard deviation."""
    dt = 1.0 / fps
    h0 = heat(p, 0.0, octaves)
    h1 = heat(p, speed * dt, octaves)
    return float(np.sqrt(((h1 - h0) ** 2).mean()) / h0.std())


def motion(args):
    """Per-frame change of the field, against LAVA_SPEED.

    Added after the shipped LAVA_SPEED of 6.0 turned out to shimmer. The first
    attempt measured a drift velocity with the structure function, which is exact
    for an advected field, and came back nearly flat against SPEED - which looked
    like a contradiction until the source was read again.

    The reason is that a quarter of the accumulated field has its time term
    *inside* a nested cosine:

        col.g += cos(A - cos(B + t*i - ...));

    so it modulates rather than translates. Modulation is what reads as shimmer,
    and it scales linearly with SPEED while the translation barely moves. So the
    measurement is per-frame change - which is independent of TILE and of the
    normalisation, and proportional to what the eye actually sees.
    """
    cfg, _ = read_settings(args.settings)
    span = args.span if args.span else 12.0
    octaves = args.octaves
    p = grid(args.size, span) / cfg["LAVA_TILE"]

    print("motion: %d octaves at TILE %.2f, %.0f fps" % (octaves, cfg["LAVA_TILE"], args.fps))
    print("\n  SPEED   changed per frame   reads as")
    for speed in (0.1, 0.25, 0.5, 0.75, 1.0, 1.5, 2.0, 3.0, 5.0, 6.0):
        c = perframe(p, octaves, speed, args.fps)
        if c < 0.012:
            v = "barely moves"
        elif c < 0.035:
            v = "a drift you can follow"
        elif c < 0.06:
            v = "noticeable"
        elif c < 0.12:
            v = "busy"
        else:
            v = "SHIMMER"
        mark = "  <- shipped" if abs(speed - cfg["LAVA_SPEED"]) < 1e-9 else ""
        print("  %5.2f   %15.2f%%   %s%s" % (speed, 100 * c, v, mark))

    print("\n  Why TILE=8 at SPEED 1.0 did not shimmer, at a much higher rate:")
    rows = []
    for TILE, oct, speed, label in (
        (8.0, 16, 1.0, "old  TILE 8.0 oct 16"),
        (cfg["LAVA_TILE"], octaves, cfg["LAVA_SPEED"], "new  shipped"),
    ):
        pp = grid(args.size, span) / TILE
        c = perframe(pp, oct, speed, args.fps)
        d = (span / args.size) / TILE
        ox = np.zeros_like(pp)
        ox[0] = d
        oy = np.zeros_like(pp)
        oy[1] = d
        h = heat(pp, 0.0, oct)
        g = np.maximum(
            np.sqrt(
                (heat(pp + ox, 0.0, oct) - h) ** 2 + (heat(pp + oy, 0.0, oct) - h) ** 2
            )
            / d,
            1e-9,
        )
        rows.append((label, TILE, oct, speed, c, float(h.std() / np.median(g))))
        print(
            "    %-20s SPEED %4.1f: %6.2f%%/frame, feature width %.4f blocks"
            % (label, speed, 100 * c, rows[-1][5])
        )
    if len(rows) == 2 and rows[1][5] > 0:
        print(
            "    -> the old one changed %.0fx faster per frame on features %.0fx\n"
            "       smaller, so nearly all of that change fell below one pixel."
            % (rows[0][4] / rows[1][4], rows[1][5] / rows[0][5])
        )
    return 0


def sheet(args):
    """Contact sheet over (octaves, LAVA_TILE) at a fixed viewing distance.

    The frequency range is the thing that cannot be reasoned about and has to be
    looked at. The loop magnifies the domain 1.5 per octave, so 16 octaves is a
    657:1 range - which a 1000px screen can show and a lava surface cannot, since
    plates are metres apart and cracks are centimetres. This renders the same
    field at several octave counts and tile sizes, with the crack width pinned to
    a plausible 5 cm, so the one that produces metre-scale plates with hairline
    cracks between them is obvious rather than argued about.
    """
    cfg, _ = read_settings(args.settings)
    span = 8.0                       # an 8 block pool, seen from close up
    px_blocks = span / args.size     # what fwidth() would report
    cw = 0.05                        # 5 cm, the target crack width

    oct_list = (3, 4, 5, 6, 8, 10, 12, 16)
    tile_list = (0.35, 0.7, 1.5, 3.0, 8.0)

    print("sheet: %d tiles of %.0f blocks, %.4f blocks/pixel, crack %.2f blocks"
          % (args.size, span, px_blocks, cw))
    print("       gradient is differenced over one pixel, as the shader does.\n")

    tiles = []
    for oct in oct_list:
        row = []
        for TILE in tile_list:
            p = grid(args.size, span) / TILE
            h = heat(p, args.t, oct)
            step = max(px_blocks / TILE, 1e-5)
            ox = np.zeros_like(p)
            ox[0] = step
            oy = np.zeros_like(p)
            oy[1] = step
            hx = heat(p + ox, args.t, oct)
            hy = heat(p + oy, args.t, oct)
            grad = np.maximum(
                np.sqrt((hx - h) ** 2 + (hy - h) ** 2) / step * TILE, 1e-9
            )
            d = (h - cfg["LAVA_CRUST_LEVEL"]) / grad
            heatv = ss_np(-cw * 2.0, cw * 2.0, d)
            seam = 1.0 - ss_np(0.0, cw, np.abs(d))
            sw = seam * cfg["LAVA_SEAM"]
            col = lava_ramp(heatv) * (1 - sw[..., None]) + lava_ramp(
                np.minimum(heatv + 0.32, 1.0)
            ) * sw[..., None]
            col = col * mix_scalar(
                0.75 + 0.5 * (h / cfg["LAVA_CRUST_LEVEL"]), 1.0, heatv
            )[..., None]
            lum = col @ np.array([0.21, 0.72, 0.07])
            molten = 100.0 * float((heatv > 0.5).mean())
            crust = 100.0 * float((heatv < 0.1).mean())
            row.append((col, molten, crust, float(np.median(grad))))
            print(
                "  oct %2d  TILE %5.2f | plate spacing %6.3f bl | molten %5.1f%%  crust %5.1f%%"
                % (oct, TILE, float(h.std()) / float(np.median(grad)), molten, crust)
            )
        tiles.append(row)

    # Assemble: one row per octave count, one column per tile size.
    img = np.zeros((args.size * len(oct_list), args.size * len(tile_list), 3))
    for i, row in enumerate(tiles):
        for j, (col, _, _, _) in enumerate(row):
            img[i * args.size : (i + 1) * args.size, j * args.size : (j + 1) * args.size] = col
    px = (to_srgb(tonemap(img)) * 255.0 + 0.5).astype(np.uint8)
    n = write_png(args.out, px)
    print("\n  wrote %s (%d bytes, %dx%d)" % (args.out, n, px.shape[1], px.shape[0]))
    print("  rows are octaves %s, left to right TILE %s"
          % (list(oct_list), list(tile_list)))
    return 0


def ss_np(a, b, x):
    u = np.clip((x - a) / (b - a), 0.0, 1.0)
    return u * u * (3.0 - 2.0 * u)


def sweep(args):
    """Sweep CRACK_WIDTH and CRUST_LEVEL, and report what each one does.

    Both are in units that cannot be reasoned about in the abstract - one is a
    distance in blocks through a field whose local gradient varies by 5x across
    the surface, the other is a percentile of a distribution that changes shape
    with the octave count. So this measures them instead.
    """
    cfg, enabled = read_settings(args.settings)
    if not enabled:
        print("lava_sweep: LAVA is off in settings.glsl")
        return 1

    span = args.span if args.span else cfg["LAVA_TILE"] * 2.0
    px_blocks = span / args.size
    octaves = args.octaves
    print("sweep: span %.1f blocks, %d octaves, %.4f blocks/pixel"
          % (span, octaves, px_blocks))
    p = grid(args.size, span) / cfg["LAVA_TILE"]

    def ss(a, b, x):
        u = np.clip((x - a) / (b - a), 0.0, 1.0)
        return u * u * (3.0 - 2.0 * u)

    h = heat(p, args.t * cfg["LAVA_SPEED"], octaves)
    step = max(px_blocks / cfg["LAVA_TILE"], 1e-5)
    ox = np.zeros_like(p)
    ox[0] = step
    oy = np.zeros_like(p)
    oy[1] = step
    hx = heat(p + ox, args.t * cfg["LAVA_SPEED"], octaves)
    hy = heat(p + oy, args.t * cfg["LAVA_SPEED"], octaves)
    grad = np.maximum(np.sqrt((hx - h) ** 2 + (hy - h) ** 2) / step * cfg["LAVA_TILE"], 1e-9)

    print("\n|grad h| at this step: p10 %.1f  p50 %.1f  p90 %.1f per block"
          % (np.percentile(grad, 10), np.percentile(grad, 50), np.percentile(grad, 90)))
    print("field std %.3f, so one std is %.4f blocks at the median gradient"
          % (h.std(), h.std() / np.median(grad)))

    print("\nCRACK_WIDTH sweep (blocks). 'crack px' is the width in preview pixels.")
    print("  width    heat grad    molten%   G/R p50   crust%   crack px")
    for cw in (0.005, 0.01, 0.02, 0.04, 0.08, 0.15, 0.3):
        d = (h - cfg["LAVA_CRUST_LEVEL"]) / grad
        heatv = ss(-cw * 2.0, cw * 2.0, d)
        seam = 1.0 - ss(0.0, cw, np.abs(d))
        sw = seam * cfg["LAVA_SEAM"]
        col = lava_ramp(heatv) * (1 - sw[..., None]) + lava_ramp(
            np.minimum(heatv + 0.32, 1.0)
        ) * sw[..., None]
        col = col * (mix_scalar(0.75 + 0.5 * (h / cfg["LAVA_CRUST_LEVEL"]), 1.0, heatv))[..., None]
        lum = col @ np.array([0.21, 0.72, 0.07])
        hot = lum > 0.10
        gr = (col[..., 1][hot] / np.maximum(col[..., 0][hot], 1e-6)).mean() if hot.any() else 0.0
        molten = 100.0 * float((heatv > 0.5).mean())
        crust = 100.0 * float((heatv < 0.1).mean())
        # a full-width crack spans 2*cw blocks; preview is span blocks wide
        px = 2.0 * cw / px_blocks
        print("  %6.3f   %6.2f    %6.1f    %6.3f   %6.1f   %7.1f"
              % (cw, 2 * cw / (h.std() / np.median(grad)), molten, gr, crust, px))

    print("\nCRUST_LEVEL sweep. The level picks WHICH contour; the width above")
    print("decides how wide it is.")
    print("  level    molten%   G/R p50   field pctl")
    for lv in (0.50, 0.60, 0.65, 0.70, 0.75, 0.80, 0.90):
        cfg["LAVA_CRUST_LEVEL"] = lv
        d = (h - lv) / grad
        heatv = ss(-cfg["LAVA_CRACK_WIDTH"] * 2.0, cfg["LAVA_CRACK_WIDTH"] * 2.0, d)
        col = lava_ramp(heatv)
        lum = col @ np.array([0.21, 0.72, 0.07])
        hot = lum > 0.10
        gr = (col[..., 1][hot] / np.maximum(col[..., 0][hot], 1e-6)).mean() if hot.any() else 0.0
        print("  %.2f     %6.1f    %6.3f     p%.0f"
              % (lv, 100.0 * float((heatv > 0.5).mean()), gr,
                 100.0 * float((h <= lv).mean())))
    return 0

if __name__ == "__main__":
    sys.exit(main())
