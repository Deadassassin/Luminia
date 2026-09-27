#!/usr/bin/env python3
"""Check that the path tracer's targets are the same size as everything else.

Why this is a script and not a comment
-------------------------------------
The loader refuses to draw a pass that binds targets of two different scales,
and it says which one is wrong:

    deferred3 writes targets of two sizes, 0.500 by 0.500 of the screen and
    1.000 by 1.000 of the screen for colortex1

The tracer reads the G-buffer and the depth buffer, which are full resolution
and cannot be made otherwise, so the only size it can run at is the screen's.
That is a real constraint rather than a preference - it was found by putting a
size.buffer directive on the tracer's own targets and having the whole pack
refuse to load.

So the invariant is: the tracer's targets carry no size.buffer directive, and
PT_SCALE is 1.0. Reintroducing either one reintroduces the failure, and nothing
in game would say so beyond a red line of text on the loading screen.

Usage:
    python3 tools/check_pt_scale.py
"""

import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
SHADERS = os.path.join(ROOT, "shaders")

# Targets the tracer owns. Anything sized here is a size the loader will
# eventually refuse to reconcile with the G-buffer this pass reads.
BUFFERS = ("colortex9", "colortex10")


def main():
    problems = []

    with open(os.path.join(SHADERS, "lib", "settings.glsl"), "r", encoding="utf-8") as f:
        settings = f.read()
    m = re.search(r"^#define\s+PT_SCALE\s+([0-9.]+)", settings, re.M)
    if not m:
        print("PT_SCALE is not defined in lib/settings.glsl")
        return 1
    scale = float(m.group(1))
    if abs(scale - 1.0) > 1e-9:
        problems.append(
            "PT_SCALE is %g. This pass reads the G-buffer and the depth buffer, "
            "which are full resolution, and a pass cannot bind targets of two "
            "scales - the loader refuses to draw it. PT_SCALE has to be 1.0 "
            "unless the depth and the G-buffer are first downsampled into "
            "targets of the tracer's own." % scale)
    else:
        print("ok    PT_SCALE is 1.0, the only size this pass can run at")

    sized = {}
    with open(os.path.join(SHADERS, "shaders.properties"), "r", encoding="utf-8") as f:
        for line in f:
            m = re.match(r"\s*size\.buffer\.(\w+)\s*=\s*([0-9.]+)\s+([0-9.]+)", line)
            if m:
                sized[m.group(1)] = (float(m.group(2)), float(m.group(3)))

    for buf in BUFFERS:
        if buf in sized:
            problems.append(
                "%s is %g x %g of the screen. That is what made the whole pack "
                "refuse to load: this pass also reads full-resolution targets, "
                "and one pass cannot bind both scales. Remove the directive."
                % (buf, sized[buf][0], sized[buf][1]))
        else:
            print("ok    %-11s has no size.buffer directive" % buf)

    print()
    if problems:
        print("%d problem(s):" % len(problems))
        for p in problems:
            print("  " + p)
        return 1
    print("the tracer's targets are the same size as the G-buffer it reads")
    return 0


if __name__ == "__main__":
    sys.exit(main())
