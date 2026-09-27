# gen_programs.py
# ---------------------------------------------------------------------------
# FauxTracer's entry points, generated from one template each.
#
# The G-buffer programs differ only in which attributes they declare and which
# material they write, so they are generated rather than maintained as four
# near-copies that drift apart. The generated files are what ships; run this
# after changing the template.

import os

HERE = os.path.dirname(os.path.abspath(__file__))
SHADERS = os.path.join(HERE, "..", "shaders")

GB_INCLUDES = [
    "/lib/options.glsl",
    "/lib/common.glsl",
    "/lib/targets.glsl",
    "/lib/pbr.glsl",
    "/lib/gbuffer.glsl",
]

# stem -> the feature macros that program is compiled with.
#
# Only these five are real programs. Everything else the world needs - entities,
# particles, lines, the hand, the weather, block entities, the glint - falls back
# to gbuffers_basic through the loader's own program tree, and gbuffers_basic is
# exactly the right code for all of them: an atlas lookup, a colour tint and a
# lightmap. Shipping more would be more ways to fail.
GBUFFERS = {
    "gbuffers_basic": ["FX_TANGENT"],
    "gbuffers_terrain": ["FX_TANGENT", "FX_BLOCK_ID", "FX_SEPARATE_AO"],
    "gbuffers_water": ["FX_TANGENT", "FX_BLOCK_ID", "FX_WATER"],
    # Distant Horizons. The loader gives its programs their own attribute set, so
    # it gets its own build; dh_water then falls back to this one.
    "dh_terrain": ["FX_BLOCK_ID", "FX_SEPARATE_AO"],
}

SKY = ["gbuffers_skybasic", "gbuffers_skytextured"]


def write(path, lines):
    with open(path, "w", encoding="utf-8") as f:
        f.write("\n".join(lines) + "\n")


def gbuffer_program(stem, defines):
    defs = ["#define " + d for d in defines]
    write(os.path.join(SHADERS, stem + ".vsh"),
          ["#version 120"] + defs + ['#include "%s"' % i for i in GB_INCLUDES]
          + ['#include "/lib/gbuffer_vertex.glsl"'])
    write(os.path.join(SHADERS, stem + ".fsh"),
          ["#version 120", "/* RENDERTARGETS: 0,1,2,3 */"] + defs
          + ['#include "%s"' % i for i in GB_INCLUDES]
          + ['#include "/lib/gbuffer_fragment.glsl"'])


def sky_program(stem):
    inc = ['#include "%s"' % i for i in
           ["/lib/options.glsl", "/lib/common.glsl", "/lib/targets.glsl", "/lib/sky.glsl"]]
    write(os.path.join(SHADERS, stem + ".vsh"),
          ["#version 120"] + inc + ['#include "/lib/sky_program.glsl"'])
    write(os.path.join(SHADERS, stem + ".fsh"),
          ["#version 120", "/* RENDERTARGETS: 0 */"] + inc + ['#include "/lib/sky_fragment.glsl"'])


def main():
    for stem, defines in GBUFFERS.items():
        gbuffer_program(stem, defines)
    for stem in SKY:
        sky_program(stem)
    print("generated %d gbuffer programs and %d sky programs"
          % (len(GBUFFERS), len(SKY)))


if __name__ == "__main__":
    main()
