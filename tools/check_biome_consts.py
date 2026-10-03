#!/usr/bin/env python3
"""Check that shaders.properties only uses biome constants Iris actually defines.

A wrong constant here does not fail the way a typo in GLSL does. Iris defines
CAT_* from the BiomeCategories enum at pack load:

    common/src/main/java/net/irisshaders/iris/shaderpack/IrisDefines.java
        define(s, "CAT_" + categories[i].name().toUpperCase(Locale.ROOT), ...)

A name that is not in the enum is never defined, so the C preprocessor passes it
through as a bare identifier into the expression, the expression fails to parse,
and Iris logs an error and leaves that uniform at its fallback. The pack still
loads and still looks plausible, which is the worst possible failure mode: the
feature is silently dead rather than obviously broken.

That is not hypothetical here - the first draft of this check was going to use
CAT_NETHER_WASTES, CAT_SOUL_SAND_VALLEY and friends, and none of those exist.
There is exactly one Nether category. The full list, in enum (== value) order:

    CAT_NONE 0          CAT_ICY 7            CAT_MUSHROOM 15
    CAT_TAIGA 1         CAT_THE_END 8        CAT_NETHER 16
    CAT_EXTREME_HILLS 2 CAT_BEACH 9          CAT_MOUNTAIN 17
    CAT_JUNGLE 3        CAT_FOREST 10        CAT_UNDERGROUND 18
    CAT_MESA 4          CAT_OCEAN 11
    CAT_PLAINS 5        CAT_DESERT 12
    CAT_SAVANNA 6       CAT_RIVER 13
                         CAT_SWAMP 14

Two of those deserve a note rather than silent use:

  CAT_UNDERGROUND (18) is defined but NEVER RETURNED by Iris - the branch that
  would produce it is commented out in BiomeUniforms with a TODO. The macro
  expands fine and always compares false. Logic depending on it is dead code that
  looks alive.

  CAT_MOUNTAIN (17) is returned for BiomeTags.IS_MOUNTAIN, but is undocumented;
  the Iris source comments that it is "in Optifine, but undocumented".

Usage: python3 tools/check_biome_consts.py
"""

import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PROPS = os.path.join(ROOT, "shaders", "shaders.properties")

# Iris: common/src/main/java/net/irisshaders/iris/parsing/BiomeCategories.java
CATEGORIES = {
    "CAT_NONE": 0,
    "CAT_TAIGA": 1,
    "CAT_EXTREME_HILLS": 2,
    "CAT_JUNGLE": 3,
    "CAT_MESA": 4,
    "CAT_PLAINS": 5,
    "CAT_SAVANNA": 6,
    "CAT_ICY": 7,
    "CAT_THE_END": 8,
    "CAT_BEACH": 9,
    "CAT_FOREST": 10,
    "CAT_OCEAN": 11,
    "CAT_DESERT": 12,
    "CAT_RIVER": 13,
    "CAT_SWAMP": 14,
    "CAT_MUSHROOM": 15,
    "CAT_NETHER": 16,
    "CAT_MOUNTAIN": 17,
    "CAT_UNDERGROUND": 18,
}

# Defined but never produced by Iris. Usable in a comparison, always false.
DEAD = {"CAT_UNDERGROUND"}

# Returned by Iris, but not in the published docs.
UNDOCUMENTED = {"CAT_MOUNTAIN"}

# PTP_* exist in Iris but are missing from the Oculus fork
# (Asek3/Oculus branch 1.20.1-new omits them from createIrisReplacements), so
# they expand on one loader and break on the other.
PPT_PORTABILITY = {"PPT_NONE", "PPT_RAIN", "PPT_SNOW"}

# The uniforms this file is allowed to read. Anything else is a typo or an
# assumption.
KNOWN_UNIFORMS = {
    "biome", "biome_category", "biome_precipitation",
    "rainfall", "temperature", "rainStrength", "thunderStrength",
    "wetness",
}


def main():
    with open(PROPS, "r", encoding="utf-8", errors="replace") as fh:
        text = fh.read().replace("\r\n", "\n").replace("\r", "\n")

    problems, notes = [], []

    used_cats = set(re.findall(r"\bCAT_[A-Z_]+\b", text))
    for name in sorted(used_cats):
        if name not in CATEGORIES:
            problems.append(
                "%s does not exist in Iris's BiomeCategories enum; it would not "
                "expand and the expression would silently fail" % name)
        elif name in DEAD:
            problems.append(
                "%s is defined but Iris never returns it (the branch is "
                "commented out), so it always compares false" % name)
        elif name in UNDOCUMENTED:
            notes.append("%s is undocumented in Iris's own source comments" % name)

    for name in sorted(set(re.findall(r"\bPPT_[A-Z_]+\b", text))):
        if name in PPT_PORTABILITY:
            problems.append(
                "%s is absent from the Oculus fork, so it breaks on that loader; "
                "use the literal 0/1/2 for biome_precipitation instead" % name)

    # biome_precipitation literals, checked against Iris's switch.
    for line in text.split("\n"):
        if "biome_precipitation" not in line:
            continue
        for lit in re.findall(r"biome_precipitation\s*(?:==|!=)\s*(\d+)", line):
            if lit not in ("0", "1", "2"):
                problems.append(
                    "biome_precipitation == %s on line: Iris only defines 0 "
                    "(none), 1 (rain), 2 (snow)" % lit)

    # Which of the documented biome uniforms are actually referenced.
    referenced = set()
    for line in text.split("\n"):
        if not line.strip().startswith(("uniform.", "variable.")):
            continue
        for name in KNOWN_UNIFORMS:
            if re.search(r"\b%s\b" % re.escape(name), line):
                referenced.add(name)
    unknown = set(re.findall(r"\b(?:biome|rain|thunder)[A-Za-z_]*\b", text)) - KNOWN_UNIFORMS

    print("shaders.properties references %d distinct CAT_* constants" % len(used_cats))
    print("  used: %s" % ", ".join(sorted(used_cats)))
    print("biome/weather uniforms used: %s" % ", ".join(sorted(referenced)))
    if unknown:
        print("unrecognised biome/rain identifiers: %s" % ", ".join(sorted(unknown)))

    if notes:
        print("\nnotes:")
        for n in notes:
            print("  " + n)

    if problems:
        print("\n%d problem(s):" % len(problems))
        for p in problems:
            print("  " + p)
        return 1
    print("\nevery biome constant used is one Iris defines and can return")
    return 0


if __name__ == "__main__":
    sys.exit(main())
