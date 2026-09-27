#!/usr/bin/env python3
"""Compile the programs the path tracer touches, with it forced on and off.

Why both
--------
`PATH_TRACER` is a preprocessor switch that removes a large amount of code from
`lib/specular.glsl` and enables a whole extra pass, so the two configurations
compile to genuinely different programs. Checking only the default means a
tracer-only typo reaches the game as a pack that will not draw, and the error
names a generated line in a file nobody thinks to open.

The tracer is off by default at the moment, which makes this the *only* thing
that checks the code path the option actually turns on.

Why not every program
---------------------
Because this harness cannot stand in for the loader faithfully enough to judge
the ones it does not care about. The pack declares samplers of its own named
`texture`, which shadows the builtin the moment `texture2D` is renamed to
`texture` - the engine renames the pack's sampler to avoid exactly that, and
this harness does not. Several programs also read colortexes the engine binds
without the pack declaring them. Those are harness gaps, not pack defects, and
failing on them would bury the one result that matters.

So this covers the tracer and its consumer, which is the set `PATH_TRACER`
actually changes:

  deferred3.fsh / .vsh   the trace itself
  composite1.fsh / .vsh  the only program that includes lib/specular.glsl

Usage:
    python3 tools/validate_pt_modes.py
"""

import os
import re
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
SHADERS = os.path.join(ROOT, "shaders")
DIMS = os.path.join(SHADERS, "dimensions")

# The only programs PATH_TRACER changes. See the module docstring.
SCOPE = [("deferred3.fsh", "frag"), ("deferred3.vsh", "vert"),
         ("composite1.fsh", "frag"), ("composite1.vsh", "vert")]

INCLUDE_RE = re.compile(r'^\s*#include\s+[<"]([^>"]+)[>"]')

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

SUPPLIED = """
uniform float MC_HAND_DEPTH;
uniform float nightVision;
"""

# Loader-supplied names this harness does not stand in for. Their absence is a
# limitation of the harness, not a defect in the pack, and listing them keeps
# that distinction out of the report.
KNOWN_UNSUPPORTED = ("MC_RENDER_QUALITY", "nightVision", "MC_HAND_DEPTH")


def expand(path, seen=None):
    seen = seen or []
    real = os.path.realpath(path)
    if real in seen:
        raise RecursionError(real)
    out = []
    with open(path, "r", encoding="utf-8") as f:
        for line in f:
            m = INCLUDE_RE.match(line)
            if not m:
                out.append(line.rstrip("\n"))
                continue
            t = m.group(1)
            r = (os.path.join(SHADERS, t[1:]) if t.startswith("/")
                 else os.path.join(os.path.dirname(path), t))
            if not os.path.isfile(r):
                raise FileNotFoundError(r)
            out.append(expand(r, seen + [real]))
    return "\n".join(out)


def compile_one(name, stage, extra_defines, tmp):
    src = expand(os.path.join(DIMS, name))
    body = "\n".join(l for l in src.split("\n") if not l.lstrip().startswith("#version"))
    body = re.sub(r"\bvarying\b", "out" if stage == "vert" else "in", body)
    for a, b in RENAMES:
        body = re.sub(r"\b%s\b" % a, b, body)
    dst = os.path.join(tmp, name.replace(".", "_") + "." + stage)
    with open(dst, "w", encoding="utf-8") as f:
        f.write("\n".join(["#version 130", extra_defines, SUPPLIED, body]))
    p = subprocess.run(["glslangValidator", "-S", stage, dst],
                       capture_output=True, text=True)
    os.unlink(dst)
    if p.returncode == 0:
        return None
    errs = []
    for line in (p.stdout + p.stderr).split("\n"):
        if "ERROR" not in line:
            continue
        if any(k in line for k in KNOWN_UNSUPPORTED) and "texelFetch" not in line:
            continue
        errs.append(line.replace(dst, name))
    return errs


def main():
    failed = 0
    with tempfile.TemporaryDirectory(prefix="fauxtracer_modes_") as tmp:
        for label, defines in (("PATH_TRACER off", ""),
                               ("PATH_TRACER on ", "#define PATH_TRACER 1\n")):
            print("== %s ==" % label)
            bad = 0
            for name, stage in SCOPE:
                try:
                    errs = compile_one(name, stage, defines, tmp)
                except (FileNotFoundError, RecursionError) as e:
                    print("  FAIL %-24s %s" % (name, e))
                    bad += 1
                    continue
                if errs:
                    print("  FAIL %s" % name)
                    for e in errs[:3]:
                        print("       " + e)
                    bad += 1
                else:
                    print("  ok   %s" % name)
            print("   %d/%d compiled" % (len(SCOPE) - bad, len(SCOPE)))
            failed += bad
            print()

    if failed:
        print("%d program/configuration combination(s) failed" % failed)
        return 1
    print("both configurations of the tracer and its consumer compile clean")
    print()
    print("This does not exercise the loader's GLSL-to-SPIR-V translation. Only")
    print("the game can do that: reload the pack and read the log.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
