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

# What the loader emits, per stage. The pack writes its stages without a version
# and the engine supplies one, so a compute stage has to be compiled above 430 for
# imageLoad/imageStore and the packing intrinsics to exist at all - none of which
# are in the 130 the fragment and vertex stages are checked at.
TARGET = "#version 130"
TARGET_COMPUTE = "#version 460 core"

INCLUDE_RE = re.compile(r'^\s*#include\s+[<"]([^>"]+)[>"]')

# Vitrail's rename table, read out of dev/vitrail/glsl/LegacyGlsl's constant
# pool rather than guessed. Longest first, so texture2DProjLod is not eaten by
# texture2D. `\b` on both sides means order does not actually matter within a
# family - `shadow2D` cannot match the `shadow2D` in `shadow2DLod` - but the
# order is kept as the engine has it so the two can be compared by eye.
#
# Two entries in this table cause real failures in this pack, and neither is
# visible without applying them:
#
#   shadow2D -> texture      `shadow2D` does not exist in the core profile, so
#                            this pack's 200-odd shadow comparisons need it.
#   texture2D -> texture     collides with a sampler this pack literally calls
#                            `texture`. See RENAME_COLLISION_RE.
RENAMES = [
    ("texture2DProjLod", "textureProjLod"),
    ("texture2DLodOffset", "textureLodOffset"),
    ("texture2DProj", "textureProj"),
    ("texture2DGradARB", "textureGrad"),
    ("texture2DGrad", "textureGrad"),
    ("texture2DOffset", "textureOffset"),
    ("texture2DLod", "textureLod"),
    ("textureCubeLod", "textureLod"),
    ("texture3DLod", "textureLod"),
    ("textureCube", "texture"),
    ("texture3D", "texture"),
    ("texture2D", "texture"),
    ("texelFetch2D", "texelFetch"),
    ("texelFetch3D", "texelFetch"),
    ("shadow2DLod", "textureLod"),
    ("shadow2DProj", "textureProj"),
    ("shadow2D", "texture"),
    # The fixed-function names become `of_`-prefixed ones. Only gl_FogFragCoord
    # appears literally in the class; the rest are built as "gl_" + a suffix at
    # runtime, which is why they are listed here by hand - the target half is
    # straight out of the constant pool.
    ("gl_FogFragCoord", "of_FogFragCoord"),
    ("gl_Fog", "of_Fog"),
    ("gl_Vertex", "of_Vertex"),
    ("gl_Color", "of_Color"),
    ("gl_Normal", "of_Normal"),
    ("gl_ModelViewMatrixInverse", "of_ModelViewMatrixInverse"),
    ("gl_ProjectionMatrixInverse", "of_ProjectionMatrixInverse"),
    ("gl_ModelViewProjectionMatrix", "of_ModelViewProjectionMatrix"),
    ("gl_ModelViewMatrix", "of_ModelViewMatrix"),
    ("gl_ProjectionMatrix", "of_ProjectionMatrix"),
    ("gl_NormalMatrix", "of_NormalMatrix"),
    ("gl_TextureMatrix", "of_TextureMatrix"),
]
for _i in range(8):
    RENAMES.append(("gl_MultiTexCoord%d" % _i, "of_MultiTexCoord%d" % _i))

# The capability macros the engine defines for every program, from
# dev/vitrail/pack/option/EngineDefines. These are not pack options and cannot be
# found by reading lib/settings.glsl, which is how they were missed for so long.
#
# It matters a great deal. `IS_LPV_ENABLED` is defined as
#
#     #ifdef LPV_ENABLED
#         #ifdef IRIS_FEATURE_CUSTOM_IMAGES
#             #define IS_LPV_ENABLED
#
# so without this macro the whole light-propagation volume is `#ifdef`'d out of
# the fragment stages too. The harness reported those clean because it was
# compiling a pack with the volume switched off, which is not the pack the game
# builds - and a block that has never been compiled is a block nobody knows
# compiles.
#
# The engine does provide these. The log shows the 3D storage images allocated and
# bound, which is what the first three assert, and shadowcomp being dispatched,
# which is the second. NVIDIA, Vulkan 1.4.351, an RTX 3050. The pack branches on
# none of them, so only their presence matters here.
ENGINE_DEFINES = [
    ("IRIS_VERSION", "11102"),
    ("MC_VERSION", "1264"),
    ("MC_GL_VERSION", "460"),
    ("MC_GLSL_VERSION", "460"),
    ("MC_RENDER_QUALITY", "1.0"),
    ("MC_SHADOW_QUALITY", "1.0"),
    ("MC_HAND_DEPTH", "0.125"),
    ("MAX_COLOR_BUFFERS", "32"),
    ("IS_IRIS", "1"),
    ("DISTANT_HORIZONS", "1"),
    # The engine puts these three in unconditionally - there is no `if` around them
    # in EngineDefines - so `#ifdef MC_NORMAL_MAP` is true whether or not a PBR
    # resource pack is installed, and the pack's normal and specular map paths are
    # always compiled. The *value* carries the capability; this pack only ever
    # tests the name with #ifdef, so the value is 0 here and the code is in.
    #
    # That is worth knowing on its own: the reason reflective materials show
    # nothing is not that their code is switched off. It is compiled, it runs, and
    # the `normals` and `specular` textures it reads are one pixel of flat grey
    # because no PBR pack is installed. See PATHTRACER.md.
    ("MC_MIPMAP_LEVEL", "0"),
    ("MC_NORMAL_MAP", "0"),
    ("MC_SPECULAR_MAP", "0"),
    ("PPT_NONE", "0"),
    ("PPT_RAIN", "1"),
    ("PPT_SNOW", "2"),
    ("MC_OS_LINUX", "1"),
    # Feature flags. The engine sets these from what it actually supports, and the
    # log shows it supports all of these: the 3D storage images were allocated and
    # bound, shadowcomp was dispatched, and the per-buffer blend directives parsed.
    ("IRIS_FEATURE_CUSTOM_IMAGES", "1"),
    ("IRIS_FEATURE_BLOCK_EMISSION_ATTRIBUTE", "1"),
    ("IRIS_FEATURE_ENTITY_TRANSLUCENT", "1"),
    ("IRIS_FEATURE_SEPARATE_HARDWARE_SAMPLERS", "1"),
    ("IRIS_FEATURE_HIGHER_SHADOWCOLOR", "1"),
    ("IRIS_FEATURE_SSBO", "1"),
    ("IRIS_FEATURE_COMPUTE_SHADERS", "1"),
    ("IRIS_FEATURE_PER_BUFFER_BLENDING", "1"),
    ("MC_GL_VENDOR_NVIDIA", "1"),
    ("MC_GL_RENDERER_GEFORCE", "1"),
]
# The Distant Horizons block ids, with the values the engine gives them. The pack
# compares against these by equality in DH_solid.fsh and DH_translucent.vsh, so
# unlike the flags above they need real numbers to be worth declaring at all.
ENGINE_DH_BLOCKS = {
    "DH_BLOCK_UNKNOWN": 0, "DH_BLOCK_LEAVES": 1, "DH_BLOCK_STONE": 2,
    "DH_BLOCK_WOOD": 3, "DH_BLOCK_METAL": 4, "DH_BLOCK_DIRT": 5,
    "DH_BLOCK_LAVA": 6, "DH_BLOCK_DEEPSLATE": 7, "DH_BLOCK_SNOW": 8,
    "DH_BLOCK_SAND": 9, "DH_BLOCK_TERRACOTTA": 10, "DH_BLOCK_NETHER_STONE": 11,
    "DH_BLOCK_WATER": 12, "DH_BLOCK_GRASS": 13, "DH_BLOCK_AIR": 14,
    "DH_BLOCK_ILLUMINATED": 15,
}

# What the engine hands a program before the pack's own source, read out of
# dev/vitrail/glsl/Emitter and LegacyGlsl. The pack is entitled to use all of it
# undeclared, and a harness that does not supply it stops at the first line that
# does.
#
# Each entry is (declaration, the names it provides), and an entry is emitted only
# when the program has not declared the name itself. Several of these are both
# engine-supplied *and* declared by the pack - `nightVision`,
# `ambientOcclusionLevel` - and declaring both is a redefinition that halts the
# compile before it reaches the code under test.
#
# `OfFog` is the engine's own struct, copied exactly:
#     struct OfFog { vec4 color; float density; float start; float end; float scale; };
# The pack reads `gl_Fog.color`, which the rename table turns into `of_Fog.color`,
# and `.color` is a vec4 - so `.rgb` on it is a swizzle, not a conversion.
SUPPLIED = [
    ("struct OfFog { vec4 color; float density; float start; float end; float scale; };\n"
     "uniform OfFog of_Fog;\n"
     "uniform mat4 of_ModelViewMatrix;\n"
     "uniform mat4 of_ModelViewProjectionMatrix;\n"
     "uniform mat4 of_ProjectionMatrix;\n"
     "uniform mat4 of_ModelViewMatrixInverse;\n"
     "uniform mat4 of_ProjectionMatrixInverse;\n"
     "uniform mat3 of_NormalMatrix;\n"
     "uniform mat4 of_TextureMatrix[8];\n"
     "uniform vec4 of_FogFragCoord;",
     ("of_Fog", "of_ModelViewMatrix", "of_ModelViewProjectionMatrix",
      "of_ProjectionMatrix", "of_ModelViewMatrixInverse",
      "of_ProjectionMatrixInverse", "of_NormalMatrix", "of_TextureMatrix",
      "of_FogFragCoord")),
    # Vertex attributes the engine supplies. `FlatNormals` is a bool the vertex
    # stages read to decide whether normals arrive flat; the two DH_ ones are
    # Distant Horizons' block ids, and the pack's dh_terrain and dh_water passes
    # compare against them.
    ("", ()),
    # The vertex attributes, and the fixed-function values built from them. This
    # is the Emitter's own block, including the defines rather than uniforms,
    # because a pack that *writes* gl_Color has to be able to.
    ("in vec3 mc_h_Position;\n"
     "in vec2 mc_h_UV0;\n"
     "#define of_Vertex vec4(mc_h_Position, 1.0)\n"
     "#define of_MultiTexCoord0 vec4(mc_h_UV0, 0.0, 1.0)\n"
     "#define of_MultiTexCoord1 vec4(0.0, 0.0, 0.0, 1.0)\n"
     "#define of_MultiTexCoord2 vec4(0.0, 0.0, 0.0, 1.0)\n"
     "#define of_MultiTexCoord3 vec4(0.0, 0.0, 0.0, 1.0)\n"
     "#define of_MultiTexCoord4 vec4(0.0, 0.0, 0.0, 1.0)\n"
     "#define of_MultiTexCoord5 vec4(0.0, 0.0, 0.0, 1.0)\n"
     "#define of_MultiTexCoord6 vec4(0.0, 0.0, 0.0, 1.0)\n"
     "#define of_MultiTexCoord7 vec4(0.0, 0.0, 0.0, 1.0)\n"
     "#define of_Color vec4(1.0)\n"
     "#define of_Normal vec3(0.0, 0.0, 1.0)\n"
     "#define ftransform() (of_ModelViewProjectionMatrix * of_Vertex)",
     ("of_Vertex", "of_Normal", "of_Color", "ftransform")),
    # Uniforms the engine supplies under the pack's own name. MC_HAND_DEPTH and
    # MC_RENDER_QUALITY are *not* here: EngineDefines supplies them as #defines
    # (MC_HAND_DEPTH 0.125), so declaring them as uniforms too is a redefinition.
    ("uniform float nightVision;", ("nightVision",)),
    ("uniform float ambientOcclusionLevel;", ("ambientOcclusionLevel",)),
    ("uniform int entityId;", ("entityId",)),
    ("uniform int blockEntityId;", ("blockEntityId",)),
    ("uniform int currentRenderedItemId;", ("currentRenderedItemId",)),
    ("uniform int dhMaterialId;", ("dhMaterialId",)),
    ("uniform mat4 modelViewMatrix;", ("modelViewMatrix",)),
    ("uniform mat4 projectionMatrix;", ("projectionMatrix",)),
]

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

# `gl_FragData[n]` has no meaning in the core profile; the engine's Emitter turns
# each one into a real output. This harness does the same, so that a program using
# it can be type-checked instead of stopping at the first write.
FRAGDATA_RE = re.compile(r"\bgl_FragData\[(\d+)\]")

# The pack is written at #version 120. The engine emits `#version 460 core`
# (dev/vitrail/glsl/Emitter), and the gap between the two is not cosmetic: the
# core profile removed implicit conversions, so a return of the wrong type, or an
# int where a float is wanted, is accepted at 130 and rejected at 460. That is
# the whole difference in this error:
#
#   0:4699: error: 'return' : cannot convert return value to function return type
#
# A harness compiling at 130 cannot see it. So the default here is the engine's
# version, and 130 is offered only as a fallback for when the emulation of the
# Emitter is the thing in doubt.
TARGET = "#version 460 core"
TARGET_COMPAT = "#version 130"


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


# A pack option declaration, live or commented out. The name pattern has to admit
# lowercase: this pack mixes cases inside its identifiers - Dirt_Amount,
# Vanilla_like_water, Dirt_Scatter_R - so an upper-case-only class captures `D`
# and leaves `irt_Amount 0.14` as the value, redefining a one-letter macro. The
# engine says the same thing from the other end, warning that "settings differ
# only by case: [A, B, C, D, E, PI, TAU, a, b, c, d, e, pi, tau]".
#
# The lookahead keeps out two things that are not options: the rest of a longer
# identifier, and a function-like macro. lib/settings.glsl defines
# `saturate(x)`, and without the lookahead its name reads as an option called
# `saturate` whose value is `x`, which then redefines the macro as an
# object-like one and every program that includes it fails to compile.
#
# Group 2 is the comment marker, group 3 the name, group 4 the value. The match
# ends where the value ends, so line[m.end():] is the ` // [ ... ]` value list
# the settings screen reads, which is kept verbatim.
OPTION_RE = re.compile(r"^[ \t]*((?://[ \t]*)?)#[ \t]*define[ \t]+"
                       r"([A-Za-z_][A-Za-z0-9_]*)(?![A-Za-z0-9_(])[ \t]*"
                       r"([^/\n]*)", re.M)

# An option declaration line, for rewriting one in an expanded program.
OPTION_LINE_RE = re.compile(r"^[ \t]*(?://[ \t]*)?#[ \t]*define[ \t]+"
                            r"([A-Za-z_][A-Za-z0-9_]*)(?![A-Za-z0-9_(])[ \t]*"
                            r"([^/\n]*)$", re.M)


def pack_options():
    """Every option the pack declares, with its shipped state.

    Returns name -> (value, commented_out).
    """
    with open(os.path.join(SHADERS, "lib", "settings.glsl"), "r", encoding="utf-8") as f:
        settings = f.read()
    out = {}
    for m in OPTION_RE.finditer(settings):
        out[m.group(2)] = (m.group(3).strip(), bool(m.group(1)))
    return out


def load_settings_file(path):
    """The player's saved options, the way the engine reads them.

    The file is the sibling `<pack>.txt` next to the pack folder. `NAME=true` is a
    toggle on, `NAME=false` is a toggle off, anything else is that literal value -
    which is how the engine reads it too, since these are the values it writes
    back when the settings screen is closed.
    """
    out = {}
    with open(path, "r", encoding="utf-8") as f:
        for line in f:
            line = line.split("#")[0].strip()
            if not line or "=" not in line:
                continue
            name, _, value = line.partition("=")
            out[name.strip()] = value.strip()
    return out


def is_off(value):
    return value.lower() in ("false", "off", "0") and value != "0.0"


def inject_options(source, overrides=None, compile_everything=False):
    """Resolve the pack's options into the unit, the way the engine does.

    This matters more than it looks. The pack declares its options in
    lib/settings.glsl, but not every program includes that file - the compute
    stages do not - so the engine supplies the option values to every program
    itself. A harness that does not leaves every option-gated block out of the
    compile, and this pack is almost entirely option-gated: LPV_ENABLED ships
    commented out, so without this the whole light-propagation volume, the
    largest single body of code in the pack, was never being compiled at all.

    Three modes, and the distinction between them has already cost a real bug:

      * with `overrides` (the player's .txt), the compile matches the game. This
        is the one that matters: the player's set is not the pack's set, and
        1015 options interact, so code that is dead by default can be live in
        their save file. That is exactly how shadowcomp.csh passed here and then
        failed in the game.
      * with `compile_everything`, every option is turned on, including the ones
        the pack ships commented out. This is the one that catches code no
        configuration currently reaches.
      * with neither, the pack's own defaults stand.

    Where the pack declares the option itself the declaration is rewritten, since
    two #defines of one name with different values is an error. Where it does not,
    the definition is prepended, which is what the engine does.
    """
    options = pack_options()
    overrides = overrides or {}

    for name in overrides:
        if name not in options:
            # A name the pack does not declare. The engine ignores these, and
            # so does this, but say so rather than pass in silence.
            print("     note: %s is set in the save file but the pack does not "
                  "declare it" % name)

    prepend = []
    for name, (value, commented) in sorted(options.items()):
        if name in overrides:
            raw = overrides[name]
            value, commented = ("" if is_off(raw) else raw), is_off(raw)
        elif compile_everything:
            commented = False
        else:
            value, commented = value, commented

        repl = repl_of(name, value, commented)
        # Find *this* option's declarations, not whichever #define happens to
        # come first in the file. Substituting only when the first one matched
        # silently prepended a second definition with a different value, and the
        # only symptom was "Macro redefined" against a line number in a file
        # nobody was looking at.
        own = re.compile(r"^[ \t]*(?://[ \t]*)?#[ \t]*define[ \t]+%s"
                         r"(?![A-Za-z0-9_(])[^\n]*$" % re.escape(name), re.M)
        hits = list(own.finditer(source))
        if hits:
            # Back to front, so each replacement leaves the earlier spans valid.
            for m in reversed(hits):
                source = source[:m.start()] + repl + source[m.end():]
        elif not commented and re.search(r"\b%s\b" % re.escape(name), source):
            # The program mentions the option but does not declare it, so it
            # needs it supplied.
            prepend.append(repl)

    return "\n".join(prepend) + ("\n" if prepend else "") + source


def repl_of(name, value, commented=False):
    value = value.strip()
    return "%s#define %s%s" % ("// " if commented else "",
                              name, (" " + value) if value else "")


def stand_in_for_loader(source, stage, overrides=None, compile_everything=False,
                        compat=False, engine_defines=True):
    """Apply the engine's rewrites the way it applies them."""
    body = "\n".join(l for l in source.split("\n")
                     if not l.lstrip().startswith("#version"))

    # A name the program declares itself must be moved out of the way before the
    # rename runs, or the rename builds a name the program cannot use.
    #
    # This pack declares `uniform sampler2D texture;` in four programs and reads
    # it with `texture2D`. The rename table makes `texture2D` into `texture`, so a
    # naive pass produces `texture(texture, uv)` - a call of a variable, which is a
    # hard error at the engine's version:
    #
    #     'texture' : can't use function syntax on variable
    #
    # The engine does not have that error. Those programs load on this engine
    # today, and the module cache has built ten thousand of them this launch. The
    # engine renames through a token stream (GlslTranslator reaches
    # TokenStream.callOpener, so it rewrites an identifier only where it opens a
    # call) and it knows what the program declared, so it does not rename a call
    # into a name the program is using for something else.
    #
    # So: move the declaration and its non-call uses aside, then rename the calls.
    # The result - `texture(of_pack_texture, uv)` - is what the engine must be
    # producing, since it is the only reading under which these programs work.
    #
    # Inferred from observed behaviour rather than read out of the class, and it
    # is the one place in this file where that is true.
    declared = {}
    for m in re.finditer(r"^\s*(?:uniform|in|out|flat|const|attribute|varying|"
                         r"buffer|shared|layout\s*\([^)]*\)\s*)*"
                         r"(?:lowp|mediump|highp|flat|smooth)?\s*"
                         r"(?:[A-Za-z_]\w*)\s+([A-Za-z_]\w*)\s*(?:\[[^\]]*\])?\s*(?:=|;)",
                         body, re.M):
        declared[m.group(1)] = True

    renamed_as_variable = {}
    for _, target in RENAMES:
        if target in declared and target not in renamed_as_variable:
            safe = "of_pack_%s" % target
            renamed_as_variable[target] = safe
            # Every use that is not a call opener. A call is `name (`, with the
            # pack's own loose spacing.
            body = re.sub(r"\b%s\b(?!\s*\()" % re.escape(target), safe, body)

    if engine_defines:
        # The engine's own defines go in before the pack's options, because a pack
        # option can be gated on one and the gate has to see it.
        defines = ["#define %s %s" % (n, v) for n, v in ENGINE_DEFINES]
        defines += ["#define %s %d" % (n, v) for n, v in
                    sorted(ENGINE_DH_BLOCKS.items())]
        body = "\n".join(defines) + "\n" + body
    if stage != "comp":
        # A compute stage has no interpolants, and hoisting `varying` into it
        # would be wrong rather than merely redundant.
        body = re.sub(r"\bvarying\b", "out" if stage == "vert" else "in", body)
        body = re.sub(r"\battribute\b", "in", body)
    for old, new in RENAMES:
        body = re.sub(r"\b%s\b" % old, new, body)

    supplied_parts = []
    for declaration, names in SUPPLIED:
        # Only if the program has not declared it. nightVision and
        # ambientOcclusionLevel are both engine-supplied and pack-declared, and
        # declaring both stops the compile before it reaches anything under test.
        if stage != "comp" and not any(
                re.search(r"^\s*(?:uniform|in|out|flat|const|attribute|varying)?"
                          r"[\w ]*\b%s\b\s*(?:\[[^\]]*\])?\s*(?:=|;|,)"
                          % re.escape(n), body, re.M) for n in names):
            supplied_parts.append(declaration)
    supplied = "\n".join(supplied_parts)

    if compat:
        # 130 keeps gl_FragData, so the Emitter emulation is not needed and
        # asking for it would only introduce a difference from the engine.
        target = TARGET_COMPAT
    elif stage == "comp":
        target = TARGET_COMPUTE
    else:
        target = TARGET
        if stage == "frag":
            # The engine's Emitter turns each write to a colour target into a real
            # output. Both spellings mean the same thing to it, so both are given
            # one here: gl_FragColor is location 0, and gl_FragData[n] is n.
            extra = []
            if re.search(r"\bgl_FragColor\b", body):
                extra.append("layout(location = 0) out vec4 mc_h_out_FragColor;")
                body = re.sub(r"\bgl_FragColor\b", "mc_h_out_FragColor", body)
            indices = sorted({int(m.group(1)) for m in FRAGDATA_RE.finditer(body)})
            for n in indices:
                if extra and n == 0:
                    continue          # gl_FragColor already owns location 0
                extra.append("layout(location = %d) out vec4 mc_h_out%d;" % (n, n))
                body = FRAGDATA_RE.sub(lambda m: "mc_h_out%s" % m.group(1), body) \
                    if False else re.sub(r"\bgl_FragData\[%d\]" % n,
                                         "mc_h_out%d" % n, body)
            supplied += ("\n" + "\n".join(extra)) if extra else ""

    return "\n".join([target, supplied,
                      inject_options(body, overrides, compile_everything)])


def programs():
    """Every program the engine actually builds.

    Not `shaders/dimensions/` - that is the shared library directory, and
    compiling it alone misses the programs that break. The real programs are the
    per-dimension wrappers: `world0/composite2.fsh` is three lines that define
    OVERWORLD_SHADER and include `dimensions/composite1.fsh`, and the dimension
    define changes which code compiles. `settings.glsl` even re-branches on it
    (`#if !defined OVERWORLD_SHADER`), so an option's value differs per
    dimension, and `lib/specular.glsl` and `lib/indirect_lighting_effects.glsl`
    both have dimension-specific bodies.

    The engine's own count is the check on this: it reports 122 fragment and 122
    vertex programs recognised, which is 42 + 40 + 40 across the three
    directories, not the 25 in `dimensions/`.

    The dimension convention is the engine's, not OptiFine's: world0 is the
    overworld, world1 the End, world-1 the Nether.
    """
    for dimension in ("world0", "world1", "world-1"):
        directory = os.path.join(SHADERS, dimension)
        if not os.path.isdir(directory):
            continue
        for name in sorted(os.listdir(directory)):
            for ext, stage in ((".fsh", "frag"), (".vsh", "vert"), (".csh", "comp")):
                if name.endswith(ext):
                    yield "%s/%s" % (dimension, name), \
                        os.path.join(directory, name), stage


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
    ap.add_argument("--settings", default="",
                    help="a save file of NAME=value options, to compile the "
                         "configuration the game actually builds rather than the "
                         "pack's defaults")
    ap.add_argument("--no-engine-defines", action="store_true",
                    help="omit IRIS_FEATURE_* and MC_GL_*, which switches off every "
                         "block gated on one - including the whole light propagation "
                         "volume, since IS_LPV_ENABLED requires "
                         "IRIS_FEATURE_CUSTOM_IMAGES")
    ap.add_argument("--compat", action="store_true",
                    help="compile at #version 130 instead of the engine's 460 core, "
                         "which forgives the implicit conversions the core profile "
                         "rejects")
    ap.add_argument("--all-options", action="store_true",
                    help="turn on every option, including the ones the pack ships "
                         "commented out, to reach code no configuration currently does")
    args = ap.parse_args()

    overrides = None
    if args.settings:
        overrides = load_settings_file(args.settings)
        print("resolving %d saved options from %s"
              % (len(overrides), os.path.basename(args.settings)))
    elif args.all_options:
        print("turning on every option, including the commented-out ones")

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
            dst = os.path.join(tmp, name.replace("/", "_").replace(".", "_")
                               + "." + stage)
            with open(dst, "w", encoding="utf-8") as f:
                f.write(stand_in_for_loader(source, stage, overrides,
                                            args.all_options, args.compat,
                                            not args.no_engine_defines))
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
