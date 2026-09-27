#!/usr/bin/env python3
"""Check that PT_SCALE and size.buffer agree.

Why this is a script and not a comment
-------------------------------------
The path tracer renders into colortex9 and colortex10, and the resolution of
those two targets is set in shaders.properties by `size.buffer`. The resolution
the tracer *believes* it is rendering at is PT_SCALE, a #define in
lib/settings.glsl, because a pass cannot ask the loader how big its own target
is in this dialect.

Nothing connects the two. If they disagree, the tracer computes its own texel
size wrongly, the estimate lands on the wrong pixels, and the result is a
reflection that is subtly, plausibly misaligned - the kind of thing that gets
"fixed" by nudging an unrelated constant.

So: one number, stated twice, in two files that do not include each other. This
reads both and fails if they have drifted.

Usage:
    python3 tools/check_pt_scale.py
"""

import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
SHADERS = os.path.join(ROOT, "shaders")

BUFFERS = ("colortex9", "colortex10")


def declared_scale():
    """PT_SCALE out of lib/settings.glsl."""
    path = os.path.join(SHADERS, "lib", "settings.glsl")
    with open(path, "r", encoding="utf-8") as f:
        m = re.search(r"^#define\s+PT_SCALE\s+([0-9.]+)", f.read(), re.M)
    if not m:
        raise SystemExit("PT_SCALE is not defined in lib/settings.glsl")
    return float(m.group(1))


def declared_sizes():
    """{buffer: scale} out of the size.buffer directives."""
    path = os.path.join(SHADERS, "shaders.properties")
    sizes = {}
    with open(path, "r", encoding="utf-8") as f:
        for line in f:
            m = re.match(r"\s*size\.buffer\.(\w+)\s*=\s*([0-9.]+)\s+([0-9.]+)", line)
            if m and m.group(1) in BUFFERS:
                sizes[m.group(1)] = (float(m.group(2)), float(m.group(3)))
    return sizes


def main():
    scale = declared_scale()
    sizes = declared_sizes()

    print("PT_SCALE in lib/settings.glsl: %g" % scale)
    problems = []

    for buf in BUFFERS:
        if buf not in sizes:
            problems.append(
                "%s has no size.buffer directive, so it is full resolution "
                "while the pass believes it is %g - every sample is off by a "
                "factor of %g" % (buf, scale, 1.0 / scale))
            continue
        w, h = sizes[buf]
        if abs(w - scale) > 1e-6 or abs(h - scale) > 1e-6:
            problems.append(
                "%s is %g x %g but the pass believes it is %g; the estimate "
                "would be sampled at the wrong scale"
                % (buf, w, h, scale))
        else:
            print("%-12s size.buffer %g x %g  ok" % (buf, w, h))

    print()
    if problems:
        print("%d mismatch(es):" % len(problems))
        for p in problems:
            print("  " + p)
        return 1
    print("the pass and the loader agree on the tracer's resolution")
    return 0


if __name__ == "__main__":
    sys.exit(main())
