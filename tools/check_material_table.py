#!/usr/bin/env python3
"""Check that the reflective-material id table is internally consistent.

Three things have to agree or the table silently does nothing:

  1. every BLOCK_MAT_* macro in lib/blocks.glsl has a block.<id>= entry in
     block.properties (otherwise the macro never matches anything),
  2. every block.<id>= entry at 1000+ has a BLOCK_MAT_* macro (otherwise the
     block gets an id nothing reads, and it silently stops being the block it
     used to be for every OTHER consumer of mc_Entity.x),
  3. no block name appears under two different ids (the loader takes the first,
     so one of the two would be dead).

Also asserts the thing this rebuild exists to guarantee: quartz resolves to no
id at all, and every id in the table is outside the [100, 300) emissive range
that all_solid.vsh:277 uses.

Usage: python3 tools/check_material_table.py
"""

import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BLOCKS = os.path.join(ROOT, "shaders", "lib", "blocks.glsl")
PROPS = os.path.join(ROOT, "shaders", "block.properties")

# all_solid.vsh:277 - anything in this range is marked EMISSIVE = 0.5.
EMISSIVE_MIN, EMISSIVE_MAX = 100, 300

# The block families this rebuild must never touch. Quartz has no entry in
# v0.4.2 and must not acquire one.
FORBIDDEN_SUBSTRINGS = ("quartz",)


def read(path):
    with open(path, "r", encoding="utf-8", errors="replace") as fh:
        return fh.read().replace("\r\n", "\n").replace("\r", "\n")


def main():
    blocks = read(BLOCKS)
    props = read(PROPS)

    macros = dict(
        (name, int(value))
        for name, value in re.findall(r"#define\s+(BLOCK_MAT_[A-Z_]+)\s+(\d+)", blocks)
    )

    # block.<id>=<names> possibly continued with a trailing backslash.
    entries = {}
    pending = None
    for line in props.split("\n"):
        m = re.match(r"^block\.(\d+)=", line)
        if m:
            pending = int(m.group(1))
            entries.setdefault(pending, [])
            body = line.split("=", 1)[1]
        elif pending is not None:
            body = line
        else:
            continue
        if body.rstrip().endswith("\\"):
            entries[pending].extend(body.rstrip().rstrip("\\").split())
            continue
        entries[pending].extend(body.split())
        pending = None

    problems = []

    # 1. macro -> properties
    for name, bid in sorted(macros.items(), key=lambda kv: kv[1]):
        if bid not in entries:
            problems.append("%s = %d has no block.%d= entry" % (name, bid, bid))

    # 2. properties -> macro
    ids = set(macros.values())
    for bid in sorted(entries):
        if bid >= 1000 and bid not in ids:
            problems.append("block.%d= has no BLOCK_MAT_* macro" % bid)

    # 3. no block name under two ids
    seen = {}
    for bid in sorted(k for k in entries if k >= 1000):
        for block in entries[bid]:
            if block in seen:
                problems.append(
                    "block %r is listed under both %d and %d" % (block, seen[block], bid)
                )
            seen[block] = bid

    # The guarantee this rebuild is for.
    for bid in sorted(k for k in entries if k >= 1000):
        for block in entries[bid]:
            low = block.lower()
            for bad in FORBIDDEN_SUBSTRINGS:
                if bad in low:
                    problems.append("block.%d= lists %r, which must stay unlisted" % (bid, block))
    for name, bid in macros.items():
        if "QUARTZ" in name:
            problems.append("%s exists; quartz must have no id" % name)
        if EMISSIVE_MIN <= bid < EMISSIVE_MAX:
            problems.append(
                "%s = %d is inside [%d, %d), the emissive range" % (name, bid, EMISSIVE_MIN, EMISSIVE_MAX)
            )
        if bid < 1000:
            problems.append("%s = %d is below 1000 and would move an existing id" % (name, bid))

    print("BLOCK_MAT_* macros: %d" % len(macros))
    print("block.<id> entries at 1000+: %d" % len([k for k in entries if k >= 1000]))
    print("block names covered: %d" % len(seen))
    print("id range: %d..%d" % (min(macros.values()), max(macros.values())))
    print("quartz entries found: %d" % sum(
        1 for bid in entries if bid >= 1000
        for b in entries[bid] if "quartz" in b.lower()))

    if problems:
        print("\n%d problem(s):" % len(problems))
        for p in problems:
            print("  " + p)
        return 1
    print("\nconsistent")
    return 0


if __name__ == "__main__":
    sys.exit(main())
