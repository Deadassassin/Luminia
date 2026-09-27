#!/usr/bin/env python3
"""Reproduce FauxTracer's lighting and display chain in Python and print what
actually lands on screen for a set of reference surfaces.

The chain is a set of constants that only mean anything together: sun intensity,
the 1/pi from Lambert's law, the sky level, the exposure and the tone map. Tuning
them by reloading the game one at a time is a slow feedback loop, and a wrong
constant in this set does not look wrong, it looks like a *different constant* is
wrong. So the chain is evaluated here instead, against a table of surfaces whose
correct answer is known.

Reference points, for a clear day with the sun at 45 degrees:
  sunlit mid grey (albedo 0.18)   should land near 0.55
  sunlit white    (albedo 0.80)   should land near 0.80
  sunlit black    (albedo 0.05)   should land near 0.24
  shaded mid grey                  should land in 0.15 .. 0.30
Those are not arbitrary. They are what a photograph of a grey card and a white
card in daylight looks like, and they pin both ends of the curve: if black is not
dark enough the shadows are lifted, and if white is not bright enough the whole
image is grey.

Usage:  python3 tools/calibrate.py
"""
import math

FX_PI = math.pi
FX_INV_PI = 1.0 / math.pi

# ---- settings (must match lib/options.glsl) --------------------------------
EXPOSURE = 1.0
SATURATION = 1.0
VIBRANCE = 1.0
# The AgX look, in brdf.glsl's order: slope, offset, power, then saturation. The
# power term is what stops the sigmoid's lifted toe from putting a black block and
# a shaded mid grey on the same value, so it is part of the calibration and not a
# taste knob - the harness cross-checks it against the GLSL.
LOOK_SLOPE = 1.0
LOOK_OFFSET = 0.0
LOOK_POWER = 1.05
LOOK_SATURATION = 1.25
CONTRAST = 1.3
TONEMAP = 0

# ---- clouds.glsl: the cloud solve -------------------------------------------
# These were absent from this harness entirely, which is the whole reason the
# clouds could be two hundred times too bright and still report a clean run. The
# extinction was 0.0021, an opaque cloud read near 200 where sunlit white stone
# reads 0.9, and every number in the table above still agreed with the pack.
#
# The model, and why it is three terms rather than one lobe:
#
#   body      isotropic, decaying as exp(-tau/2) - this is what makes a cloud with
#             the sun in front of it read as a dark base. An angle-independent
#             term cannot: neither it nor any isotropic-only model knows which
#             side the sun is on, so a backlit core comes out as bright as a lit
#             one.
#   edge      the normalised g=0.76 forward lobe, gated by transmittance to the
#             sun, because the silver lining can only appear where light gets all
#             the way through.
#   ambient   no angle dependence at all, for light that scattered too many times
#             to have a direction left. This is the floor that stops a cloud from
#             going black at ninety degrees to the sun.
#
# The three weights and the albedo are solved against the five surfaces below, not
# chosen. Note that "thin sunlit edge" and "silver lining" are the same cloud at
# the same optical depth and differ only in whether the sun is behind or in front
# of it, with deliberately disjoint bands: with overlapping bands the solver
# correctly reports that the forward lobe is not needed, and the cloud silently
# loses its lining.
CLOUD_EXTINCTION = 0.4
CLOUD_ALBEDO = 0.95
CLOUD_PHASE_ISO = 1.330
CLOUD_PHASE_FORWARD = 1.625
CLOUD_PHASE_AMBIENT = 0.020

# ---- sky.glsl: fxGetAtmosphere ---------------------------------------------
class Atm:
    pass

def atmosphere(sun_elevation=0.7071, rain=0.0):
    a = Atm()
    a.sunDir = (0.0, sun_elevation, math.sqrt(max(1 - sun_elevation**2, 0.0)))
    rain = min(max(rain, 0.0), 1.0)
    a.day = 1.0 - min(max((0.22 - sun_elevation) / (0.22 + 0.16), 0.0), 1.0)
    a.night = 1.0 - a.day
    dusk = 1.0 - abs(min(max((sun_elevation + 0.30) / 0.46, 0.0), 1.0) * 2.0 - 1.0)
    a.twilight = max(0.0, min(1.0, dusk * (1.0 - abs(sun_elevation) * 1.6)))
    a.sunIntensity = min(max((sun_elevation + 0.13) / 0.23, 0.0), 1.0) * (1 - rain * 0.8)
    sc = (1.0, 0.97, 0.915)
    k = 3.14159265   # pi: a white surface in direct sun then has radiance 1.0
    a.sunColour = tuple(c * a.sunIntensity * k * SUN_LEVEL for c in sc)
    return a

# ---- atmosphere.glsl: measured, daylit, sky up ----------------------------
# Values ported from tools/calibrate_sky.py, which is the offline port of
# fxSkyScattering. Zenith through horizon band for a clear day.
SKY_BRIGHTNESS = 1.0

# These are the pack's own palette values, and they are the single most important
# thing in this file. An earlier version of the harness carried measured samples
# from a scattering integral the pack no longer uses, so AMBIENT_LEVEL came out
# calibrated against a sky roughly seven times dimmer than the real one - and the
# symptom in game was an entirely white world under a correct sky. If the palette
# below is edited, re-solve AMBIENT_LEVEL with this harness; do not carry a
# number over from a sky that is no longer being drawn.
DAY_ZENITH  = (0.085, 0.230, 0.560)
DAY_HORIZON = (0.470, 0.610, 0.840)
NIGHT_ZENITH  = (0.0035, 0.0060, 0.0170)
NIGHT_HORIZON = (0.0100, 0.0150, 0.0320)
DUSK_ZENITH  = (0.055, 0.085, 0.230)
DUSK_HORIZON = (0.940, 0.330, 0.090)

# The ambient the diffuse term sees, relative to the visible sky. Two separate
# numbers on purpose: the sky you can see and the hemisphere integral lighting a
# surface are not the same quantity, and tying them together means fixing the shade
# by making the sky brighter, which is a worse picture. Solved, not chosen.
AMBIENT_LEVEL = 2.6
SUN_LEVEL = 1.0


def mix3(a, b, t):
    return tuple(x + (y - x) * t for x, y in zip(a, b))


def sky_gradient(direction, atm):
    """Port of fxSkyGradient, for the day and the down-tap. The twilight and Mie
    terms are folded into the palette already, so this is the daytime path only -
    which is the only case the reference table measures."""
    t = max(min(direction[1], 1.0), 0.0)
    zenith = mix3(NIGHT_ZENITH, DAY_ZENITH, atm.day)
    horizon = mix3(NIGHT_HORIZON, DAY_HORIZON, atm.day)
    col = mix3(zenith, horizon, (1.0 - t) ** 5.0)
    return col


def sky_irradiance(normal_world, atm):
    """Port of fxSkyIrradiance, in radiance units before AMBIENT_LEVEL."""
    upness = normal_world[1] * 0.5 + 0.5
    up = sky_gradient((0.0, 1.0, 0.0), atm)
    side_dir = (normal_world[0], 0.15, normal_world[2])
    n = (side_dir[0] ** 2 + side_dir[1] ** 2 + side_dir[2] ** 2) ** 0.5
    side = sky_gradient(tuple(c / n for c in side_dir), atm)
    down = sky_gradient((0.0, -1.0, 0.0), atm)
    ground = tuple(c * 0.35 for c in down)
    return tuple(
        (g + (s - g) * upness) * AMBIENT_LEVEL * SKY_BRIGHTNESS
        for g, s in zip(ground, mix3(tuple(h * 0.35 for h in side),
                                     tuple(h * 0.65 for h in up), 1.0))
    )

# ---- lighting.glsl: fxShadeOpaque ------------------------------------------
def shade(albedo, normal_world=(0.0, 1.0, 0.0), sky_light=1.0, in_sun=True, atm=None):
    atm = atm or atmosphere()
    nw = normal_world
    nl = max(sum(nw[i] * atm.sunDir[i] for i in range(3)), 0.0)
    diffuse = [0.0, 0.0, 0.0]

    if in_sun and nl > 0 and atm.sunIntensity > 0:
        wrap = (nl + 0.25) / (1.0 + 0.25)
        for k in range(3):
            diffuse[k] += albedo[k] * wrap * atm.sunColour[k] * FX_INV_PI

    irr = sky_irradiance(nw, atm)
    for k in range(3):
        diffuse[k] += albedo[k] * irr[k] * sky_light
    return tuple(diffuse)

# ---- brdf.glsl: display transform ------------------------------------------
def agx_curve(x):
    x2 = x * x
    x4 = x2 * x2
    return (15.5 * x4 * x2 - 40.14 * x4 * x + 31.96 * x4 - 6.868 * x2 * x
            + 0.4298 * x2 + 0.1191 * x - 0.00232)

def agx_look(v):
    """Port of the look stage in fxTonemapAgX, in the same order: power first, then
    the saturation lift. Order matters - saturating before the power curve and
    clamping afterwards is not the same transform, and the harness would then be
    grading a picture the pack never draws."""
    v = [max(c * LOOK_SLOPE + LOOK_OFFSET, 0.0) ** LOOK_POWER for c in v]
    l = 0.2126 * v[0] + 0.7152 * v[1] + 0.0722 * v[2]
    return [l + LOOK_SATURATION * (c - l) for c in v]

def agx(c):
    inset = ((0.842479062253094, 0.0423282422610123, 0.0423756549057051),
             (0.0784335999999992, 0.878468636469772, 0.0784336),
             (0.0792237451477643, 0.0791661274605434, 0.879142973793104))
    outset = ((1.19687900512017, -0.0528968517574562, -0.0529716355144438),
              (-0.0980208811401368, 1.15190312990417, -0.0980434501171241),
              (-0.0990297440797205, -0.0989611768448433, 1.15107367264116))
    lo, hi = -12.47393, 4.026069
    v = [sum(inset[r][k] * c[k] for k in range(3)) for r in range(3)]
    import math
    v = [(min(max(math.log2(max(x, 1e-5)), lo), hi) - lo) / (hi - lo) for x in v]
    v = [agx_curve(x) for x in v]
    v = agx_look(v)
    v = [sum(outset[r][k] * v[k] for k in range(3)) for r in range(3)]
    return [min(max(x ** 2.2, 0.0), 1.0) for x in v]

def aces(x):
    a, b, c, d, e = 2.51, 0.03, 2.43, 0.59, 0.14
    return min(max((x * (a * x + b)) / (x * (c * x + d) + e), 0.0), 1.0)

def linear_to_srgb(x):
    x = max(x, 0.0)
    return x * 12.92 if x < 0.0031308 else 1.055 * min(x, 1.0) ** (1 / 2.4) - 0.055

def luma(c):
    return 0.2126 * c[0] + 0.7152 * c[1] + 0.0722 * c[2]

def vibrance(c):
    gv = (c[0] + c[1] + c[2]) / 3.0
    gs = luma(c)
    mn = min(c)
    mx = max(c)
    sat = (1.0 - (mx - mn)) * (1.0 - mx) * gv * 5.0
    light = (mn + mx) * 0.5
    c = [a + (b - a) * sat for a, b in zip(c, [x + (light - x) * (1.0 - VIBRANCE) for x in c])]
    m = (2.0 - VIBRANCE) / 2.0 * abs(VIBRANCE - 1.0)
    c = [a + (light - a) * (1.0 - light) * m for a in c]
    return [a * SATURATION - gs * (SATURATION - 1.0) for a in c]

def cloud_saturated(cos_to_sun, optical_depth, density, height_light=0.8):
    """The radiance of a fully opaque cloud, in the same units as a surface.

    A dense medium accumulates in-scattered radiance towards lit/extinction once
    the optical depth is large, so "a cloud you cannot see through" is exactly the
    saturated case and is the one worth specifying. sunColour/FX_PI is 1.0 at full
    daylight with the sun at 45 degrees, the same normalisation the terrain's
    albedo * E * NdotL / pi gets.
    """
    t_sun = math.exp(-optical_depth)
    powder = 0.35 + 0.65 * (1.0 - math.exp(-density * 8.0))
    g = 0.76
    hg = (1.0 - g * g) / (4.0 * math.pi
                          * max(1.0 + g * g - 2.0 * g * cos_to_sun, 1e-4) ** 1.5)
    phase = (CLOUD_PHASE_ISO * math.exp(-optical_depth * 0.5)
             + CLOUD_PHASE_FORWARD * hg * t_sun * powder
             + CLOUD_PHASE_AMBIENT)
    return phase * CLOUD_ALBEDO * height_light / CLOUD_EXTINCTION


def display_transform(hdr, day, underwater=0.0):
    curve = (1.85 + (1.0 - 1.85) * day) * EXPOSURE
    c = [min(max(v * curve, 0.0), 64.0) for v in hdr]
    if TONEMAP == 0:
        c = agx(c)
    else:
        c = [aces(v) for v in c]
    c = [linear_to_srgb(v) for v in c]
    c = vibrance(c)
    c = [max((v - 0.42) * CONTRAST + 0.42, 0.0) for v in c]
    return c

# The sky is a radiance written into the image, never multiplied by an irradiance,
# so it is graded rather than shaded. The directions are the two that matter: what
# is overhead, and what the fog colour is sampled from.
SKY_SURFACES = [
    ("sky, zenith",  (0.0, 1.0, 0.0), (0.18, 0.55)),
    ("sky, horizon", (0.0, 0.05, -1.0), (0.30, 0.80)),
]

# ---- the table -------------------------------------------------------------
def check_against_the_shaders():
    """The numbers above are only useful if they are the numbers in the pack.

    A calibration harness that drifts from the thing it calibrates is worse than
    none, because it reports a green light on a broken image. So the constants are
    read out of the GLSL and compared with the ones used here, and a mismatch is
    a failure.
    """
    import os
    import re
    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    pack = os.environ.get("FX_PACK") or os.path.join(
        os.path.expanduser("~"),
        ".local/share/PrismLauncher/instances/26.2withmmv/minecraft/"
        "shaderpacks/fauxtracer/shaders")
    if not os.path.isdir(pack):
        pack = os.path.join(root, "vitrail", "shaders")
    options = os.path.join(pack, "lib", "options.glsl")
    if not os.path.isfile(options):
        print("  (no lib/options.glsl found; skipping the cross-check)")
        return 0
    with open(options, "r", encoding="utf-8") as f:
        text = f.read()

    def declared(name):
        m = re.search(r"^#define\s+%s\s+([0-9.]+)" % re.escape(name), text, re.M)
        return float(m.group(1)) if m else None

    def declared_vec(name, source=None):
        # The palette is assigned as "a.dayZenith = vec3(...)" inside fxGetAtmosphere,
        # not declared bare, so match either form.
        m = re.search(r"^\s*(?:a\.)?%s\s*=\s*vec3\(([^)]*)\)" % re.escape(name),
                      source if source is not None else text, re.M)
        if not m:
            return None
        return tuple(float(v) for v in m.group(1).split(","))

    pairs = [("EXPOSURE", EXPOSURE), ("SKY_BRIGHTNESS", SKY_BRIGHTNESS),
             ("AMBIENT_LEVEL", AMBIENT_LEVEL), ("SUN_LEVEL", SUN_LEVEL),
             ("SATURATION", SATURATION), ("VIBRANCE", VIBRANCE)]
    bad = 0
    print()
    print("cross-check against lib/options.glsl")
    for name, mine in pairs:
        theirs = declared(name)
        if theirs is None:
            print("  %-16s not declared in the pack" % name)
            bad += 1
        elif abs(theirs - mine) > 1e-6:
            print("  %-16s harness %g, pack %g  - MISMATCH" % (name, mine, theirs))
            bad += 1
        else:
            print("  %-16s %g, agrees" % (name, mine))

    # The sun normalisation is the one that has to be pi for the exposure numbers
    # to mean anything, so it is checked against the file rather than trusted. The
    # sky source is kept because the palette check below reads from it.
    sky = os.path.join(pack, "lib", "sky.glsl")
    skysrc = ""
    if os.path.isfile(sky):
        with open(sky, "r", encoding="utf-8") as f:
            skysrc = f.read()
        if "FX_PI * SUN_LEVEL" not in skysrc:
            print("  sun is not normalised by FX_PI in lib/sky.glsl - the exposure "
                  "calibration assumes it is")
            bad += 1
        else:
            print("  %-16s normalised by FX_PI, agrees" % "sun")

    # The palette is checked as well, because a number solved against a palette the
    # pack no longer draws is worse than no number at all. This check is the one
    # that would have caught the white world: AMBIENT_LEVEL had been solved against
    # samples from a scattering integral that had since been replaced by a closed
    # form seven times brighter, and every scalar in the list above still agreed
    # with the pack while the picture was unusable.
    palette = [("dayZenith", DAY_ZENITH), ("dayHorizon", DAY_HORIZON),
               ("nightZenith", NIGHT_ZENITH), ("nightHorizon", NIGHT_HORIZON),
               ("duskZenith", DUSK_ZENITH), ("duskHorizon", DUSK_HORIZON)]
    for name, mine in palette:
        theirs = declared_vec(name, skysrc)
        if theirs is None:
            print("  %-16s not declared in the pack" % name)
            bad += 1
        elif max(abs(a - b) for a, b in zip(mine, theirs)) > 1e-4:
            print("  %-16s harness %s, pack %s  - MISMATCH" % (name, mine, theirs))
            bad += 1
        else:
            print("  %-16s %s, agrees" % (name, theirs))

    # Same argument for the look constants, which live in the library rather than
    # the options file and so are the easiest of all to change without noticing
    # that the harness now describes a different image.
    brdf = os.path.join(pack, "lib", "brdf.glsl")
    if os.path.isfile(brdf):
        with open(brdf, "r", encoding="utf-8") as f:
            brdfsrc = f.read()
        for glsl_name, mine in [("lookSlope", LOOK_SLOPE),
                                ("lookOffset", LOOK_OFFSET),
                                ("lookPower", LOOK_POWER),
                                ("lookSaturation", LOOK_SATURATION)]:
            m = re.search(r"const\s+float\s+%s\s*=\s*([0-9.]+)" % glsl_name, brdfsrc)
            theirs = float(m.group(1)) if m else None
            if theirs is None:
                print("  %-16s not found in lib/brdf.glsl" % glsl_name)
                bad += 1
            elif abs(theirs - mine) > 1e-6:
                print("  %-16s harness %g, pack %g  - MISMATCH" % (glsl_name, mine, theirs))
                bad += 1
            else:
                print("  %-16s %g, agrees" % (glsl_name, mine))
    cloudsrc = os.path.join(pack, "lib", "clouds.glsl")
    if os.path.isfile(cloudsrc):
        with open(cloudsrc, "r", encoding="utf-8") as f:
            csrc = f.read()
        for glsl_name, mine in [("FX_CLOUD_EXTINCTION", CLOUD_EXTINCTION),
                                ("FX_CLOUD_ALBEDO", CLOUD_ALBEDO),
                                ("FX_CLOUD_PHASE_ISO", CLOUD_PHASE_ISO),
                                ("FX_CLOUD_PHASE_FORWARD", CLOUD_PHASE_FORWARD),
                                ("FX_CLOUD_PHASE_AMBIENT", CLOUD_PHASE_AMBIENT)]:
            m = re.search(r"(?:const\s+float|#define)\s+%s\s*=?\s*([0-9.]+)"
                          % glsl_name, csrc)
            theirs = float(m.group(1)) if m else None
            if theirs is None:
                print("  %-24s not found in lib/clouds.glsl" % glsl_name)
                bad += 1
            elif abs(theirs - mine) > 1e-6:
                print("  %-24s harness %g, pack %g  - MISMATCH" % (glsl_name, mine, theirs))
                bad += 1
            else:
                print("  %-24s %g, agrees" % (glsl_name, mine))
    return bad


def main():
    drift = check_against_the_shaders()
    atm = atmosphere()
    cases = [
        ("sunlit mid grey  0.18", (0.18, 0.18, 0.18), True,  1.0, (0.50, 0.62)),
        ("sunlit white     0.80", (0.80, 0.80, 0.80), True,  1.0, (0.72, 0.92)),
        ("sunlit black     0.05", (0.05, 0.05, 0.05), True,  1.0, (0.15, 0.34)),
        ("shaded mid grey  0.18", (0.18, 0.18, 0.18), False, 1.0, (0.12, 0.32)),
    ]
    print("reference surfaces, clear day, sun at 45 degrees")
    print("  exposure curve at noon = %.3f\n" % ((1.85 + (1.0 - 1.85) * atm.day) * EXPOSURE))
    print("  %-24s %-18s %-18s %s" % ("case", "scene linear", "on screen", "expected"))
    print("  " + "-" * 74)
    bad = 0
    for name, albedo, sun, sky_light, (lo, hi) in cases:
        lin = shade(albedo, in_sun=sun, sky_light=sky_light, atm=atm)
        out = display_transform(lin, atm.day)
        g = luma(out)
        ok = lo <= g <= hi
        bad += not ok
        print("  %-24s %-18s %-18s %.2f-%.2f  %s"
              % (name, "%.3f" % luma(lin), "%.3f" % g, lo, hi, "ok" if ok else "OUT"))
    # The sky is a radiance written straight into the image, never multiplied by
    # an irradiance, so it is graded rather than shaded.
    for name, direction, (lo, hi) in SKY_SURFACES:
        radiance = tuple(v * SKY_BRIGHTNESS for v in sky_gradient(direction, atm))
        out = display_transform(radiance, atm.day)
        g = luma(out)
        ok = lo <= g <= hi
        bad += not ok
        print("  %-24s %-18s %-18s %.2f-%.2f  %s"
              % (name, "%.3f" % luma(radiance), "%.3f" % g, lo, hi, "ok" if ok else "OUT"))
    print()
    # The clouds, which is the surface that was missing when they were two hundred
    # times too bright. Graded like the sky, because a cloud is a radiance written
    # into the image rather than a lit surface.
    #
    # These bands are on-screen values. The solve was done in linear against bands
    # obtained by inverting the grade, because AgX compresses this range hard: a
    # lit cloud and a backlit one that differ 1.8:1 in linear land 0.873 and 0.811
    # on screen, which is invisible, so a linear-only specification would happily
    # accept a cloud with no contrast at all in it.
    print("opaque cloud, clear day, sun at 45 degrees")
    print("  %-32s %-10s %s" % ("case", "on screen", "expected"))
    print("  " + "-" * 64)
    clouds = [
        ("cloud, lit core, sun behind",   -0.70, 2.0, 1.0, (0.83, 0.92)),
        ("cloud, lit core, perpendicular",  0.00, 2.0, 1.0, (0.83, 0.92)),
        ("cloud, backlit base",             0.70, 6.0, 0.8, (0.40, 0.56)),
        ("cloud, thin sunlit edge",        -0.70, 0.8, 0.4, (0.93, 1.00)),
        ("cloud, silver lining",            0.70, 0.8, 0.4, (0.94, 1.00)),
    ]
    for name, cos_to_sun, od, density, (lo, hi) in clouds:
        lin = cloud_saturated(cos_to_sun, od, density)
        g = luma(display_transform((lin, lin, lin), atm.day))
        ok = lo <= g <= hi
        bad += not ok
        print("  %-32s %-10s %.2f-%.2f  %s"
              % (name, "%.3f" % g, lo, hi, "ok" if ok else "OUT"))

    # The silver lining is the one requirement a display band cannot carry. Above
    # about 0.95 on screen AgX has nothing left to give, so a lining and a plain
    # lit edge both read 0.97 and the bands above cannot tell them apart - which is
    # exactly how a forward lobe of zero passes a green run. So it is stated in
    # linear, where it means what it says: the same cloud, same optical depth, must
    # be measurably brighter with the sun in front of it than behind it.
    lit_edge = cloud_saturated(-0.70, 0.8, 0.4)
    lining = cloud_saturated(0.70, 0.8, 0.4)
    lift = lining / max(lit_edge, 1e-6)
    ok = lift >= 1.05
    bad += not ok
    print("  %-32s %-10s >= %.2f     %s"
          % ("silver lining over lit edge", "%.3f" % lift, 1.05, "ok" if ok else "OUT"))
    print()
    # Count every surface actually checked. The number used to be len(cases), which
    # was 4 while the table had grown to twelve, so the reassuring summary line
    # understated its own coverage by two thirds.
    total = len(cases) + len(SKY_SURFACES) + len(clouds) + 1
    if bad:
        print("%d of %d outside the expected range - the chain is not calibrated"
              % (bad, total))
    else:
        print("all %d reference surfaces in range" % total)
    if drift:
        print("%d setting(s) differ between the harness and the pack" % drift)
    return 1 if (bad or drift) else 0

if __name__ == "__main__":
    raise SystemExit(main())
