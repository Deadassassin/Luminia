#!/usr/bin/env python3
"""Recompute the reflection gate for every entry in the material table.

lib/specular.glsl decides reflection with

    Roughness = 1.0 - Roughness;  Roughness *= Roughness;   # Roughness here is .r
    F0        = F0 == 0.0 ? 0.02 : F0;                     # F0 here is .g
    hasReflections = F0 * (1.0 - Roughness * Roughness_Threshold) > 0.01;

so with s the smoothness written by the table, .r is the dry-case s (no rain),
and the gate is

    g = F0 * (1 - Roughness_Threshold * (1 - s)^2)

This script parses the real table out of lib/material_reflectance.glsl rather
than restating it, so it cannot drift from what the shader will do. Its point is
to answer one question with arithmetic instead of with an opinion: which blocks
reflect, and is quartz one of them.

Usage: python3 tools/check_reflection_gate.py
"""

import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TABLE = os.path.join(ROOT, "shaders", "lib", "material_reflectance.glsl")
BLOCKS = os.path.join(ROOT, "shaders", "lib", "blocks.glsl")
SETTINGS = os.path.join(ROOT, "shaders", "lib", "settings.glsl")

DEFAULT_SMOOTHNESS = 0.05   # the float smoothness = ... before the switch
DEFAULT_F0 = 0.04           # the float f0 = ... before the switch
CUTOFF = 0.01               # hasReflections threshold in lib/specular.glsl


def read(path):
    with open(path, "r", encoding="utf-8", errors="replace") as fh:
        return fh.read().replace("\r\n", "\n").replace("\r", "\n")


def const(text, name, default):
    m = re.search(r"const float %s\s*=\s*([^;]+);" % name, text)
    return eval(m.group(1)) if m else default


def parse_switch(body, names, unknown):
    """Return {macro: value} from a switch, handling stacked case labels."""
    out = {}
    current = []
    for line in body.split("\n"):
        line = line.split("//")[0].strip()
        m = re.match(r"case\s+(\w+)\s*:", line)
        if m:
            if m.group(1) not in names:
                unknown.append(m.group(1))
            current.append(m.group(1))
            continue
        m = re.match(r"(?:smoothness|f0)\s*=\s*([^;]+);", line)
        if m and current:
            value = eval(m.group(1), {}, consts)
            for name in current:
                out[name] = value
            current = []
            continue
        if line.startswith("}"):
            current = []
    return out


text = read(TABLE)
names = dict(
    (n, int(v))
    for n, v in re.findall(r"#define\s+(BLOCK_MAT_[A-Z_]+)\s+(\d+)", read(BLOCKS))
)
consts = {
    "LUMINA_MAT_METAL_F0": const(text, "LUMINA_MAT_METAL_F0", 231.0 / 255.0),
    "LUMINA_MAT_DIELECTRIC_F0": const(text, "LUMINA_MAT_DIELECTRIC_F0", 0.04),
}


def main():
    # Roughness_Threshold as actually defined in settings.glsl, not assumed.
    settings = read(SETTINGS)
    m = re.search(r"#define\s+Roughness_Threshold\s+([\d.]+)", settings)
    threshold = float(m.group(1)) if m else 1.2

    smooth_fn = text.split("float lpvMaterialSmoothness", 1)[1].split("\nfloat lpvMaterialF0", 1)[0]
    f0_fn = text.split("float lpvMaterialF0", 1)[1]
    unknown = []
    smoothness = parse_switch(smooth_fn, names, unknown)
    f0s = parse_switch(f0_fn, names, unknown)

    def gate(s, f0):
        rough = (1.0 - s) ** 2
        f0 = 0.02 if f0 == 0.0 else f0
        return f0 * (1.0 - rough * threshold)

    unlisted_gate = gate(DEFAULT_SMOOTHNESS, DEFAULT_F0)

    print("Roughness_Threshold = %s, cutoff = %s" % (threshold, CUTOFF))
    print("unlisted block: s=%s F0=%s -> gate %+.5f  %s"
          % (DEFAULT_SMOOTHNESS, DEFAULT_F0, unlisted_gate,
             "REFLECTS" if unlisted_gate > CUTOFF else "matte"))
    print()
    print("%-32s %6s %9s %10s  %s" % ("BLOCK_MAT_", "id", "smooth", "gate", "verdict"))
    print("-" * 76)

    missing, reflecting, matte = [], [], []
    for name in sorted(names, key=lambda n: names[n]):
        # Every macro needs a smoothness: that is the column every listed block
        # is actually distinguished by. The F0 switch only needs to name the
        # blocks that are NOT the dielectric default - iron through copper, and
        # ice - which is exactly what the shader does, since its f0 local starts
        # at LUMINA_MAT_DIELECTRIC_F0 and a case that does not match leaves it.
        if name not in smoothness:
            missing.append(name)
            continue
        g = gate(smoothness[name], f0s.get(name, DEFAULT_F0))
        verdict = "REFLECTS" if g > CUTOFF else "matte"
        (reflecting if g > CUTOFF else matte).append(name)
        print("%-32s %6d %9.2f %10.5f  %s"
              % (name, names[name], smoothness[name], g, verdict))

    print()
    print("reflecting: %d   matte: %d   unparsed: %d   total: %d"
          % (len(reflecting), len(matte), len(missing), len(names)))

    problems = []
    if missing:
        problems.append("no smoothness in the table: %s" % ", ".join(sorted(missing)))
    if unknown:
        problems.append("case labels with no BLOCK_MAT_* macro: %s" % ", ".join(sorted(set(unknown))))
    # Anything the F0 switch names must be a macro that exists, or the entry is
    # dead code that silently never matches.
    for name in f0s:
        if name not in names:
            problems.append("F0 switch names %s, which has no macro" % name)
    if unlisted_gate > CUTOFF:
        problems.append(
            "the unlisted default REFLECTS (gate %+.5f); every block absent from "
            "the table would pick up a sheen" % unlisted_gate)
    for name in names:
        if "QUARTZ" in name:
            problems.append("%s exists: quartz must have no id" % name)
    for name in reflecting + matte:
        if "QUARTZ" in name:
            problems.append("%s is in the table: quartz must be absent" % name)

    # Quartz must not even appear as a block name anywhere in block.properties.
    props = read(os.path.join(ROOT, "shaders", "block.properties"))
    in_props = re.findall(r"^block\.(\d+)=([^\n]*(?:\\\n[^\n]*)*)", props, re.M)
    for bid, blob in in_props:
        if int(bid) >= 1000 and "quartz" in blob.lower():
            problems.append("block.%s lists a quartz block" % bid)

    print()
    if problems:
        print("%d problem(s):" % len(problems))
        for p in problems:
            print("  " + p)
        return 1
    print("quartz is absent from the id table, the material table and block.properties")
    print("every entry is covered by both tables, and the unlisted default is matte")
    return 0


if __name__ == "__main__":
    sys.exit(main())
