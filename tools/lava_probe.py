#!/usr/bin/env python3
"""Probe the lava field from Shadertoy Dt33z7, so its constants are measured.

lib/lava.glsl is a port of I11212's Shadertoy "Dt33z7". The shader's own
output is `length(col/3.0) * vec3(1.0, 0.25, 0.0)` - a magnitude, times one
fixed hue. That is enough to look like plasma and not enough to look like lava:
there is no crust and no heat scale, and both of the numbers lib/lava.glsl needs
(the level the crust sits at, and how wide a crack is) are thresholds on a field
whose range nobody has measured. Guessing them is how you get a lava pool that is
either uniformly white or uniformly black.

So this is a NumPy port of the same loop, and it answers three questions:

  * What is the range of `length(col/3.0)`, and how is it distributed? That sets
    LAVA_CRUST, the level the dark plates sit at.
  * How fast does the field move, per unit of time, at each octave? The original
    adds `t/64` inside a loop that scales the domain by 1.5 every pass, so the
    drift compounds to `t/64 * 1.5^i`. By the last octave it is ~7 units per
    second, which on its own is the reason the Shadertoy version reads as a zoom.
    LAVA_SPEED has to be scaled to that, not guessed.
  * What is the feature size per octave, in blocks? The loop magnifies the domain
    1.5^16 = 657x across the span, so the last few octaves are far below one
    block and have to be dropped with distance. This is what picks the octave
    fade's start distance.

Usage:
    python3 tools/lava_probe.py
    python3 tools/lava_probe.py --span 8 --octaves 16
"""

import argparse

import numpy as np

# rot(1.0) from the shader: mat2(cos(x), -sin(x), sin(x), cos(x)).
#
# GLSL builds a matrix from its columns, so that constructor is
#
#     [ cos  sin ]
#     [-sin  cos ]
#
# which is a rotation by -1 radian, not +1. Getting this backwards is invisible
# in a still and obvious in motion, so it is written out here the same way the
# shader has it and checked against a direct rotation below.
_COS1 = np.cos(1.0)
_SIN1 = np.sin(1.0)

OCTAVES = 16
ZOOM = 1.5


def getlava(x, t, octaves=OCTAVES):
    """Port of getlava() from Dt33z7. x is (2, ...) -> (3, ...)."""
    x = x.copy()
    col_r = np.zeros(x.shape[1:])
    col_g = np.zeros(x.shape[1:])
    col_b = np.zeros(x.shape[1:])

    for i in range(octaves):
        x = x * ZOOM
        x[0] += t / 64.0
        # column-major mat2(cos, -sin, sin, cos) times x
        x = np.array(
            [
                _COS1 * x[0] + _SIN1 * x[1],
                -_SIN1 * x[0] + _COS1 * x[1],
            ]
        )
        x[0] += (np.sin(x[0] + x[1] + x[0] * 2.0 - t / 4.0) + np.cos(x[0] * 4.0)) / 16.0
        x[1] += (np.sin(x[0] + x[1] + x[0] * 2.0 - t / 4.0) + np.cos(x[0] * 4.0)) / 16.0

        fi = float(i)
        col_r += np.sin(x[0] * 2.0) * np.cos(x[1] + t)
        col_g += np.cos(
            x[0] + x[1] - np.cos(x[0] - x[1] + t * fi - x[1] + x[0] * 4.0)
        )
        # iTime appears twice in the original. Kept: it is the same function,
        # and cos(A + 2t + cos(B)) is what the shader computes.
        col_b += np.cos(x[0] + x[1] + t + np.cos(x[0] - x[1]) + t)

    return np.array([col_r, col_g, col_b])


def heat(x, t, octaves=OCTAVES, norm=3.0):
    """length(col/norm) - the scalar the original shader turns into colour.

    norm=3.0 is the original shader's own divisor and is kept as the default so
    this stays a faithful port. See NORM below for why lib/lava.glsl does not
    use it.
    """
    return np.sqrt((getlava(x, t, octaves) ** 2).sum(axis=0)) / norm


# The original divides by 3 while summing 16 terms, so the field is not
# normalised at all: it is centred near 1.34 with a max near 5. That is fine on
# Shadertoy, where the result goes straight to the screen and clips. It is not
# fine here, because the crust threshold has to be a number a person can reason
# about, so the field is divided by 8 instead and comes out centred near 0.50.
NORM = 8.0


def grid(n, span, ox=0.0, oy=0.0):
    a = np.linspace(ox, ox + span, n, endpoint=False)
    b = np.linspace(oy, oy + span, n, endpoint=False)
    xx, yy = np.meshgrid(a, b)
    return np.array([xx, yy])


def pct(a, qs=(0, 1, 5, 25, 50, 75, 95, 99, 100)):
    return "  ".join("p%-3d %7.4f" % (q, np.percentile(a, q)) for q in qs)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--n", type=int, default=512)
    ap.add_argument(
        "--span",
        type=float,
        default=8.0,
        help="blocks spanned by one unit of the shader's uv, i.e. LAVA_TILE",
    )
    ap.add_argument("--octaves", type=int, default=OCTAVES)
    args = ap.parse_args()

    n = args.n
    print("lava_probe: %dx%d over a %.3f block span, %d octaves\n" % (n, n, args.span, args.octaves))

    # --- the rotation, checked rather than trusted -------------------------
    v = np.array([1.0, 0.0])
    got = np.array([_COS1 * v[0] + _SIN1 * v[1], -_SIN1 * v[0] + _COS1 * v[1]])
    want = np.array([np.cos(-1.0) * v[0] - np.sin(-1.0) * v[1],
                     np.sin(-1.0) * v[0] + np.cos(-1.0) * v[1]])
    assert np.allclose(got, want), (got, want)
    print("rotation: mat2(cos,-sin,sin,cos) x (1,0) == rotation by -1 rad  ok")

    g = grid(n, args.span)

    # --- range and distribution --------------------------------------------
    h = heat(g, 0.0, args.octaves)
    print("\nlength(col/3.0) at t=0")
    print("  min %.4f  max %.4f  mean %.4f  std %.4f" % (h.min(), h.max(), h.mean(), h.std()))
    print("  " + pct(h))
    print("\n  -> LAVA_CRUST is a threshold on this. A level that leaves roughly")
    print("     25%% of the surface molten sits near p75 = %.4f." % np.percentile(h, 75))

    # how much of the surface is above a few candidate levels
    print("\n  molten fraction by threshold")
    for lv in (0.30, 0.40, 0.50, 0.60, 0.70, 0.80, 0.90, 1.00):
        print("    level %.2f -> %5.1f%% of the surface" % (lv, 100.0 * (h > lv).mean()))

    # --- drift per octave ---------------------------------------------------
    # The domain is scaled by ZOOM every pass and then t/64 is added to x only, so
    # by the end of pass i the accumulated drift is t/64 * ZOOM^i. This is the
    # number LAVA_SPEED has to be set against.
    print("\n  drift of the pattern, per second of t, in domain units")
    print("    the added offset compounds as 1/64 * 1.5^i:")
    for i in (0, 2, 4, 6, 8, 10, 12, 14, 15):
        print(
            "      octave %2d: %9.4f units/s  = %8.3f blocks/s at a %.1f block span"
            % (i, ZOOM**i / 64.0, ZOOM**i / 64.0 * args.span, args.span)
        )

    # measured, to confirm the compounding and not just the arithmetic
    print("\n  measured drift of the coarse structure (cross-correlation)")
    for dt in (0.25, 1.0, 4.0):
        a = heat(grid(n // 2, args.span), 0.0, 4)
        b = heat(grid(n // 2, args.span), dt, 4)
        d = a - a.mean()
        best, bestlag = -2.0, 0.0
        for lag in np.arange(-0.5, 0.5, 0.002):
            shifted = np.roll(np.roll(b, int(round(lag * (n / 2) / args.span)), axis=0),
                              int(round(lag * (n / 2) / args.span)), axis=1)
            sd = shifted - shifted.mean()
            denom = np.sqrt((d * d).sum() * (sd * sd).sum())
            c = float((d * sd).sum() / denom) if denom > 0 else 0.0
            if c > best:
                best, bestlag = c, lag
        print(
            "    dt=%4.2fs: best match at a shift of %+.3f domain units (r=%.3f)"
            % (dt, bestlag, best)
        )
        print(
            "               -> %.3f units/s, i.e. %.3f blocks/s"
            % (bestlag / dt, abs(bestlag) / dt * args.span)
        )

    # --- feature size per octave -------------------------------------------
    # Pass i works on a domain ZOOM^i times larger than the input, so one unit of
    # the *input* domain is ZOOM^i input units at that pass. A cos() of its
    # argument has a period of 2*pi in that pass's domain.
    print("\n  feature size per octave, in blocks (half a period of the cosines)")
    for i in (0, 4, 8, 10, 12, 13, 14, 15):
        # The sin/cos in pass i are evaluated at x after i transforms, and x is
        # ZOOM^i times the input, so a feature spans 2*pi / ZOOM^i input units.
        units = 2.0 * np.pi / ZOOM**i
        print(
            "      octave %2d: %10.4f blocks" % (i, units / 2.0 * args.span)
        )
    print("\n  Anything below ~0.05 blocks is sub-voxel on a lava surface and")
    print("  has to go with distance. That is what the octave fade is for.")

    # --- octave count vs appearance ----------------------------------------
    print("\n  effect of dropping octaves (std of the field, and its correlation")
    print("  with the full 16 - 1.0 means the coarse structure survived)")
    full = heat(g, 0.0, args.octaves)
    for k in (4, 6, 8, 10, 12, 14, 16):
        hk = heat(g, 0.0, k)
        d = full - full.mean()
        e = hk - hk.mean()
        denom = np.sqrt((d * d).sum() * (e * e).sum())
        c = float((d * e).sum() / denom) if denom > 0 else 0.0
        print(
            "      %2d octaves: std %.4f  (%.1f%% of full)  r vs full %.4f"
            % (k, hk.std(), 100.0 * hk.std() / full.std(), c)
        )

    # --- the normalised field, which is what the shader actually uses -------
    hn = heat(g, 0.0, args.octaves, NORM)
    print(
        "\nlength(col/%.1f) - the normalisation lib/lava.glsl uses instead of 3"
        % NORM
    )
    print("  min %.4f  max %.4f  mean %.4f  std %.4f" % (hn.min(), hn.max(), hn.mean(), hn.std()))
    print("  " + pct(hn))
    print("\n  molten fraction by threshold, in the normalised field")
    for lv in (0.45, 0.50, 0.55, 0.60, 0.65, 0.70, 0.75, 0.80, 0.90, 1.00):
        print(
            "    LAVA_CRUST %.2f -> %5.1f%% molten   (band half-width %.3f: %5.1f%% on the level set)"
            % (lv, 100.0 * (hn > lv).mean(), 0.02, 100.0 * (np.abs(hn - lv) < 0.02).mean())
        )

    # --- gradient, so a field-unit crack width means something -------------
    # A crack is the level set of the field, so its width in blocks is
    # (band width in field units) / |grad h| in field units per block. Without
    # this the crack slider is in units nobody can picture.
    print("\n  |grad h| in field units per block, at LAVA_TILE = %.1f" % args.span)
    for k in (6, 8, 10, 12, 14, 16):
        step = args.span / n
        off_x = np.zeros_like(g)
        off_x[0] = step
        off_y = np.zeros_like(g)
        off_y[1] = step
        hx = heat(g, 0.0, k, NORM)
        hdx = heat(g + off_x, 0.0, k, NORM)
        hdy = heat(g + off_y, 0.0, k, NORM)
        gx = (hdx - hx) / step
        gy = (hdy - hx) / step
        mag = np.sqrt(gx * gx + gy * gy)
        finite = mag[np.isfinite(mag) & (mag > 0)]
        print(
            "      %2d octaves: median %.3f  p10 %.3f  p90 %.3f"
            % (k, np.median(mag), np.percentile(finite, 10), np.percentile(finite, 90))
        )
    print(
        "\n  -> a band half-width of 0.05 in the normalised field is roughly"
    )
    print("     0.05/median|grad h| blocks wide, so ~0.1-0.5 blocks depending on")
    print("     how many octaves are running. That is the right order for a crack.")


if __name__ == "__main__":
    main()