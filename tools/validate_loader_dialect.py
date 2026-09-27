#!/usr/bin/env python3
"""Compile this pack's programs with Vitrail's own name rewrites applied.

Why this exists
---------------
Vitrail does not have a macro layer. It has a *rename table* - a map from the
OpenGL-era spelling to the modern one - and `texelFetch2D` is in it, mapped
straight to `texelFetch`:

    "texelFetch2D" -> "texelFetch"
    "texelFetch3D" -> "texelFetch"

So `texelFetch2D` is not a convenience wrapper that converts its arguments. It
is `texelFetch` spelled the old way, and it therefore needs an integer
coordinate, exactly as `texelFetch` does. Under Iris the same source works,
because Iris's `texelFetch2D` is a real macro that does convert.

This pack is full of calls like

    texelFetch2D(depth, posDepth + radius * scaling + pos * scaling, 0)

which is a float coordinate. Under Vitrail that becomes

    texelFetch(depth, posDepth + radius * scaling + pos * scaling, 0)

and glslang answers `no matching overloaded function found`, which names a line
in the *translated* source and not the file you would open to fix it.

It went unnoticed because the pack loads through a module cache: a program
whose source has not changed is not recompiled, so a stale module built from
different source keeps working until an unrelated edit invalidates it. That is
the worst possible failure mode - the bug is real, the symptom appears on a
change that did not cause it, and reverting the change hides it again.

So this harness applies the loader's rewrites and compiles, which turns a
mystery line number in a generated file into a file and line you can open.

What it does not do is reproduce the loader's translation to SPIR-V. Only the
game can do that.

Usage:
    python3 tools/validate_loader_dialect.py              # every program
    python3 tools/validate_loader_dialect.py composite1   # matching only
"""

import argparse
import os
import re
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
SHADERS = os.path.join(ROOT, "shaders")

INCLUDE_RE = re.compile(r'^\s*#include\s+[<"]([^>"]+)[>"]')

# Vitrail's rename table, from dev/vitrail/glsl/LegacyGlsl. Applied longest
# first so texture2DProjLod is not eaten by texture2D.
RENAMES = [
    ("texelFetch2D", "texelFetch"),
    ("texelFetch3D", "texelFetch"),
    ("texture2DProjLod", "textureProjLod"),
    ("texture2DLodOffset", "textureLodOffset"),
    ("texture2DProj", "textureProj"),
    ("texture2DGradEXT", "textureGrad"),
    ("texture2DGradARB", "textureGrad"),
    ("texture2DLod", "textureLod"),
    ("texture2DOffset", "textureOffset"),
    ("textureCubeLod", "textureLod"),
    ("texture2D", "texture"),
]

# Names the engine supplies, so the pack is entitled to read them undeclared.
# Found by compiling: each of these was an "undeclared identifier" until it was
# declared here, which is how a harness proves it is standing in for the engine
# rather than papering over a missing declaration in the pack.
SUPPLIED = """
uniform float MC_HAND_DEPTH;
uniform float nightVision;
"""

# The engine binds these as comparison samplers, and says so at load time:
#   "3 samplers this chain read the shadow map: [shadow, shadowtex0, shadowtex1]"
#   "asked the hardware to compare [shadow, shadowtex0, shadowtex1], which the
#    binding carries as a comparison sampler"
#
# Two consequences, and this file is built on having been bitten by the second:
#
#  * A program may read one of these with shadow2D(), which needs the comparison
#    type, and must declare it sampler2DShadow to match.
#  * A program may NOT read one with texelFetch or texture(), because neither has
#    an overload for a comparison sampler. It compiles only while the declaration
#    lies and says sampler2D, which is why the engine's warning about it is worth
#    reading rather than silencing: "declares shadowtexN as a comparison sampler in
#    one stage and an ordinary one in another" was the honest description of an
#    ordinary texelFetch on a comparison binding, and "fixing" the declaration is
#    what turned it into a hard error.
COMPARISON_BOUND = ("shadow", "shadowtex0", "shadowtex1")

# Reads that are only legal on an ordinary sampler.
ORDINARY_READ_RE = re.compile(r'\b(texelFetch2D|texelFetch3D|texelFetch|'
                              r'texture2DGradEXT|texture2DGradARB)\s*\(\s*'
                              r'(shadow|shadowtex0|shadowtex1)\b')

# The pack is written at #version 120, where texelFetch does not exist, so the
# unit is compiled at 130. 130 is still the compatibility profile, so
# gl_FragData, texture2D and ftransform all still mean what they mean at 120 -
# and texture2D is gone by then anyway, which is why it is renamed above.
TARGET = "#version 130"


def expand(path, seen=None):
    seen = seen or []
    real = os.path.realpath(path)
    if real in seen:
        raise RecursionError("cyclic #include: %s" % " -> ".join(seen + [real]))
    out = []
    with open(path, "r", encoding="utf-8") as f:
        for line in f:
            m = INCLUDE_RE.match(line)
            if not m:
                out.append(line.rstrip("\n"))
                continue
            target = m.group(1)
            resolved = (os.path.join(SHADERS, target[1:]) if target.startswith("/")
                        else os.path.join(os.path.dirname(path), target))
            if not os.path.isfile(resolved):
                raise FileNotFoundError(
                    "%s: cannot resolve #include \"%s\" -> %s" % (path, target, resolved))
            out.append(expand(resolved, seen + [real]))
    return "\n".join(out)


def stand_in_for_loader(source, stage):
    """Apply the engine's rewrites the way it applies them."""
    body = "\n".join(l for l in source.split("\n")
                     if not l.lstrip().startswith("#version"))
    body = re.sub(r"\bvarying\b", "out" if stage == "vert" else "in", body)
    for old, new in RENAMES:
        body = re.sub(r"\b%s\b" % old, new, body)
    return "\n".join([TARGET, SUPPLIED, body])


def programs():
    for name in sorted(os.listdir(os.path.join(SHADERS, "dimensions"))):
        for ext, stage in ((".fsh", "frag"), (".vsh", "vert")):
            if name.endswith(ext):
                yield name, os.path.join(SHADERS, "dimensions", name), stage


def texel_errors(proc, dst, label):
    """The errors this harness exists to find, kept apart from the rest.

    Everything else a program can complain about is either a pre-existing
    problem in a file nobody has touched or a limitation of standing in for the
    engine by hand. The coordinate type of a texelFetch is neither: the rename
    table is read straight out of the engine, so this one is exactly right.
    """
    out = []
    for line in proc.split("\n"):
        if "ERROR" not in line:
            continue
        if "texelFetch" in line and "no matching overloaded function" in line:
            out.append(line.replace(dst, label))
    return out


def comparison_reads(source, label):
    """Ordinary reads of a sampler the engine binds for comparison.

    Not a compile error - it compiles, and it is what the engine's own warning
    is about - so it cannot be found by compiling. It is reported separately
    because it is a real, silent, undefined-behaviour read, and because it is
    the trap that the hard error above sits behind: correcting the declaration
    without correcting the read turns a warning into a pack that will not draw.
    """
    out = []
    for i, line in enumerate(source.split("\n"), 1):
        code = line.split("//")[0]
        for m in ORDINARY_READ_RE.finditer(code):
            out.append("%s:%d  ordinary read of the comparison-bound `%s` - the "
                       "engine binds it for comparison, so this is undefined; "
                       "declare the sampler sampler2D to keep it compiling"
                       % (label, i, m.group(2)))
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("filter", nargs="?", default="")
    ap.add_argument("--all-errors", action="store_true",
                    help="report every error, not just the texelFetch ones")
    args = ap.parse_args()

    targets = [(n, p, s) for n, p, s in programs() if args.filter in n]
    if not targets:
        print("no programs matched %r" % args.filter)
        return 1

    texel_problems, comparison, other, checked = [], [], {}, 0
    with tempfile.TemporaryDirectory(prefix="fauxtracer_ld_") as tmp:
        for name, path, stage in targets:
            try:
                source = expand(path)
            except (FileNotFoundError, RecursionError) as e:
                other.setdefault(name, []).append(str(e))
                continue
            checked += 1
            for note in comparison_reads(source, name):
                comparison.append(note)
                print("WARN  %s" % note)
            dst = os.path.join(tmp, name.replace(".", "_") + "." + stage)
            with open(dst, "w", encoding="utf-8") as f:
                f.write(stand_in_for_loader(source, stage))
            proc = subprocess.run(["glslangValidator", "-S", stage, dst],
                                  capture_output=True, text=True)
            if proc.returncode == 0:
                print("ok    %-34s %d lines" % (name, source.count("\n") + 1))
                continue
            blob = proc.stdout + proc.stderr
            hits = texel_errors(blob, dst, name)
            for h in hits:
                texel_problems.append(h)
                print("FAIL  %-34s %s" % (name, h.split("error:")[-1].strip()))
            rest = [l for l in blob.split("\n")
                    if "ERROR" in l and l not in hits]
            if rest:
                other[name] = rest
            if not hits and not rest:
                print("FAIL  %-34s (no diagnostic)" % name)

    print()
    print("%d programs compiled with Vitrail's rename table applied" % checked)
    if texel_problems:
        print()
        print("texelFetch coordinate errors (%d): the loader maps texelFetch2D "
              "straight to\ntexelFetch, so the coordinate has to be an integer. "
              "Wrap the argument in ivec2()." % len(texel_problems))
        for p in texel_problems:
            print("  " + p)
    if comparison:
        print()
        print("ordinary reads of a comparison-bound sampler (%d): these compile, and "
              "the engine\nwarns about them at load time. They are undefined under "
              "Vulkan and under Iris." % len(comparison))
    if other and args.all_errors:
        print()
        print("other errors (%d programs) - not necessarily this harness's doing:"
              % len(other))
        for name, errs in sorted(other.items()):
            print("  %s" % name)
            for e in errs[:4]:
                print("    " + e)
    elif other:
        print("(%d program(s) reported other diagnostics; re-run with --all-errors)"
              % len(other))
    return 1 if texel_problems else 0


if __name__ == "__main__":
    sys.exit(main())
