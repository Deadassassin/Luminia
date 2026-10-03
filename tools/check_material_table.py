#!/usr/bin/env python3
"""Check that the reflective-material id table is internally consistent.

Five things have to agree, or the table silently does nothing - or, worse, does
something nobody asked for:

  1. every BLOCK_MAT_* macro in lib/blocks.glsl has a block.<id>= entry in
     block.properties (otherwise the macro never matches anything),
  2. every block.<id>= entry has a BLOCK_MAT_* macro (otherwise the block gets an
     id nothing reads, and silently stops being the block it used to be for every
     OTHER consumer of mc_Entity.x),
  3. no block name appears under two different ids (the loader takes the first, so
     one of the two would be dead),
  4. NO ID COLLIDES WITH ANOTHER ID SPACE. This is the one that actually bites.
     mc_Entity.x is not block-only: block.properties, item.properties and
     entity.properties all feed it, and ptBlockLightData() in lib/lpv_blocks.glsl
     matches ITEM_* and ENTITY_* cases against the same number to decide what
     emits light. The first version of this table used 1000 and up, which is the
     item band, and 23 of its 45 blocks came back as torches, lanterns, beacons
     and glowstone - each of which is then given a non-zero lightRange, and
     ptBlockLightData's last act is
         if (lightRange > 0.0) mixMask = BuildLpvMask(1,1,1,1,1,1);
     i.e. all six faces opened so the light can escape. Those blocks glowed AND
     let sunlight straight through them. So: every BLOCK_MAT_* id is checked
     against every id in all three properties files and against every ITEM_*/ENTITY_*
     macro, not just against block.properties.
  5. no id falls in the [100, 300) range all_solid.vsh:277 marks emissive.

Usage: python3 tools/check_material_table.py
"""

import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# all_solid.vsh:277 - anything in this range is marked EMISSIVE = 0.5.
EMISSIVE_MIN, EMISSIVE_MAX = 100, 300

# The block families this rebuild must never touch. Quartz has no entry in
# v0.4.2 and must not acquire one.
FORBIDDEN_SUBSTRINGS = ("quartz",)


def read(path):
    with open(path, "r", encoding="utf-8", errors="replace") as fh:
        return fh.read().replace("\r\n", "\n").replace("\r", "\n")


def macros(path, pattern):
    return dict(
        (name, int(value)) for name, value in re.findall(pattern, read(path))
    )


def properties_ids(path, prefix):
    """Every id the file defines, plus the id -> [block names] map."""
    ids, names, pending = set(), {}, None
    for line in read(path).split("\n"):
        m = re.match(r"^%s\.(\d+)=" % prefix, line)
        if m:
            pending = int(m.group(1))
            ids.add(pending)
            names.setdefault(pending, [])
            body = line.split("=", 1)[1]
        elif pending is not None:
            body = line
        else:
            continue
        if body.rstrip().endswith("\\"):
            names[pending].extend(body.rstrip().rstrip("\\").split())
            continue
        names[pending].extend(body.split())
        pending = None
    return ids, names


def main():
    problems = []

    block_ids, block_names = properties_ids(
        os.path.join(ROOT, "shaders", "block.properties"), "block")
    item_ids, _ = properties_ids(
        os.path.join(ROOT, "shaders", "item.properties"), "item")
    entity_ids, _ = properties_ids(
        os.path.join(ROOT, "shaders", "entity.properties"), "entity")

    mat = macros(os.path.join(ROOT, "shaders", "lib", "blocks.glsl"),
                 r"#define\s+(BLOCK_MAT_[A-Z_]+)\s+(\d+)")
    items = macros(os.path.join(ROOT, "shaders", "lib", "items.glsl"),
                   r"#define\s+(ITEM_[A-Z_]+)\s+(\d+)")
    entities = macros(os.path.join(ROOT, "shaders", "lib", "entities.glsl"),
                      r"#define\s+(ENTITY_[A-Z_]+)\s+(\d+)")

    # ---- 1. macro -> block.properties
    for name, bid in sorted(mat.items(), key=lambda kv: kv[1]):
        if bid not in block_names:
            problems.append("%s = %d has no block.%d= entry" % (name, bid, bid))

    # ---- 2. block.properties -> macro, for the ids this table owns
    owned = set(mat.values())
    for bid in sorted(owned):
        if bid not in block_ids:
            problems.append("block.%d= has no BLOCK_MAT_* macro" % bid)

    # ---- 3. no block name under two ids
    seen = {}
    for bid in sorted(owned):
        for block in block_names.get(bid, []):
            if block in seen:
                problems.append(
                    "block %r is listed under both %d and %d"
                    % (block, seen[block], bid))
            seen[block] = bid

    # ---- 4. THE COLLISION CHECK
    # Every other id space mc_Entity.x can carry, keyed by number.
    others = {}
    for name, val in items.items():
        others.setdefault(val, []).append(name)
    for name, val in entities.items():
        others.setdefault(val, []).append(name)
    for label, ids in (("item.properties", item_ids),
                       ("entity.properties", entity_ids)):
        for bid in ids:
            if bid in owned:
                others.setdefault(bid, []).append(label)

    for name, bid in sorted(mat.items(), key=lambda kv: kv[1]):
        hits = others.get(bid)
        if hits:
            problems.append(
                "%s = %d COLLIDES with %s - that id is a light source, so this "
                "block would emit and pass light through itself"
                % (name, bid, ", ".join(sorted(hits))))

    # A collision with any *other* block id would also be wrong.
    other_block_ids = block_ids - owned
    for name, bid in sorted(mat.items(), key=lambda kv: kv[1]):
        if bid in other_block_ids:
            problems.append("%s = %d collides with another block.%d= entry"
                            % (name, bid, bid))

    # ---- 5. emissive range, and the guarantee this rebuild exists for
    for name, bid in mat.items():
        if EMISSIVE_MIN <= bid < EMISSIVE_MAX:
            problems.append(
                "%s = %d is inside [%d, %d), the emissive range"
                % (name, bid, EMISSIVE_MIN, EMISSIVE_MAX))
        if "QUARTZ" in name:
            problems.append("%s exists; quartz must have no id" % name)
    for bid in sorted(owned):
        for block in block_names.get(bid, []):
            for bad in FORBIDDEN_SUBSTRINGS:
                if bad in block.lower():
                    problems.append(
                        "block.%d= lists %r, which must stay unlisted" % (bid, block))

    print("BLOCK_MAT_* macros: %d" % len(mat))
    print("block names covered: %d" % len(seen))
    print("id range: %d..%d" % (min(mat.values()), max(mat.values())))
    print("other id spaces: block <=%d, item %d..%d, entity %d..%d"
          % (max(b for b in block_ids if b < 1000),
             min(item_ids), max(item_ids),
             min(entity_ids), max(entity_ids)))
    print("ids colliding with another id space: %d"
          % sum(1 for b in mat.values() if b in others))
    print("quartz entries found: %d" % sum(
        1 for bid in owned for b in block_names.get(bid, [])
        if "quartz" in b.lower()))

    if problems:
        print("\n%d problem(s):" % len(problems))
        for p in problems:
            print("  " + p)
        return 1
    print("\nconsistent")
    return 0


if __name__ == "__main__":
    sys.exit(main())
