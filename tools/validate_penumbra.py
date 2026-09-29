#!/usr/bin/env python3
"""Offline validation for the Penumbra shader pack.

Penumbra is written in the legacy OptiFine dialect: `attribute`, `varying`,
`texture2D`, `texelFetch2D`, `ftransform`, and `#version 120`. None of that
survives contact with a compiler, and none of it may be handed to one: the game
rewrites it before the driver ever sees it, and the rewrite is the contract.
This stands in for that rewrite, then compiles the result, so a mistake is
caught here rather than as a black screen in game.

What the loader does, and what this mirrors:

  * #include is expanded the way the loader expands it - a leading slash against
    the shaders root, anything else against the including file. A missing one is
    an error, not a shrug.
  * The version line is replaced with the one the loader emits (460 core).
    Compiling at 120 would pass things the real chain refuses, and refuse things
    it accepts; neither answer is useful.
  * `attribute` becomes `in` (vertex stages only), `varying` becomes `out` in a
    vertex stage and `in` in a fragment stage, matching the direction of travel.
  * `texture2D`/`texture2DLod` become `texture`/`textureLod`.
  * `texelFetch2D(s, p, l)` becomes `texelFetch(s, p, l)`. The trailing lod
    argument is dead in the core profile, so it is dropped.
  * `ftransform()` is rewritten to the projection of the modelview position,
    which is what it expands to.
  * The fixed-function inputs the loader supplies (gl_Vertex, gl_Normal,
    gl_Color, gl_MultiTexCoord*, gl_TextureMatrix, gl_VertexID) and the matrices
    are declared under fx_-prefixed names, because `gl_` is reserved and cannot
    be declared. gl_FragData becomes located outputs.

Programs: the world0/world1/world-1 stub files, which are what the loader
actually loads. The files under dimensions/ and lib/ are includes and are not
separately loadable.

Usage:
    python3 tools/validate_penumbra.py            # everything
    python3 tools/validate_penumbra.py terrain    # only matching programs
    python3 tools/validate_penumbra.py --no-profiles
"""

import argparse
import os
import re
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
PACK = os.environ.get("FX_PACK") or os.path.join(ROOT, "shaders")

STAGES = {
    ".vsh": "vert",
    ".fsh": "frag",
    ".csh": "comp",
    ".gsh": "geom",
    ".tcs": "tesc",
    ".tes": "tese",
}

# The version the loader emits, and therefore what is actually compiled.
TARGET_VERSION = "#version 460 core"

# What the engine defines before the pack source, and the sampler/macro names
# the loader substitutes. Nothing here is GLSL: a unit that reaches the compiler
# with one of these as live code fails naming it, and in game the message points
# at the symptom rather than at the construct that caused it.
#
# shadow2D(s, p) becomes texture(s, p).r against a plain sampler2D shadow, which
# is what the loader turns it into; the pack reads the depth and compares it
# itself, so the hardware comparison the core profile would give is not what it
# wants here.
ENGINE_DEFINES = r"""
#define MC_VERSION 12605
#define MC_RENDER_QUALITY 0
#define MC_HAND_DEPTH 0

#define MC_RENDER_STAGE_NONE                   0
#define MC_RENDER_STAGE_SKY                    1
#define MC_RENDER_STAGE_SUNSET                 2
#define MC_RENDER_STAGE_CUSTOM_SKY             3
#define MC_RENDER_STAGE_SUN                    4
#define MC_RENDER_STAGE_MOON                   5
#define MC_RENDER_STAGE_STARS                  6
#define MC_RENDER_STAGE_VOID                   7
#define MC_RENDER_STAGE_TERRAIN_SOLID          8
#define MC_RENDER_STAGE_ENTITIES               9
#define MC_RENDER_STAGE_BLOCK_ENTITIES         10
#define MC_RENDER_STAGE_DESTROY                11
#define MC_RENDER_STAGE_OUTLINE                12
#define MC_RENDER_STAGE_DEBUG                  13
#define MC_RENDER_STAGE_HAND_SOLID             14
#define MC_RENDER_STAGE_TERRAIN_TRANSLUCENT    15
#define MC_RENDER_STAGE_TRIPWIRE               16
#define MC_RENDER_STAGE_PARTICLES              17
#define MC_RENDER_STAGE_CLOUDS                 18
#define MC_RENDER_STAGE_RAIN_SNOW              19
#define MC_RENDER_STAGE_WORLD_BORDER           20
#define MC_RENDER_STAGE_HAND_TRANSLUCENT       21
#define MC_RENDER_STAGE_TERRAIN_CUTOUT         22
#define MC_RENDER_STAGE_TERRAIN_CUTOUT_MIPPED  23

#define MC_GL_VERSION 460
#define MC_GL_VENDOR_AMD 0
#define MC_GL_VENDOR_INTEL 1
#define MC_GL_VENDOR_NVIDIA 2
#define MC_GL_VENDOR_QUALCOMM 3
#define MC_GL_VENDOR_IMG 4
#define MC_GL_VENDOR_APPLE 5
#define MC_GL_RENDERER_AMD 0
#define MC_GL_RENDERER_INTEL 1
#define MC_GL_RENDERER_NVIDIA 2
#define MC_GL_RENDERER_QUALCOMM 3
#define MC_GL_RENDERER_IMG 4
#define MC_GL_RENDERER_APPLE 5

#define IS_IRIS 1
#define IRIS_VERSION 12605
#define IRIS_FEATURE_CUSTOM_IMAGES 1
#define IRIS_FEATURE_BLOCK_EMISSION_ATTRIBUTE 1
#define IRIS_FEATURE_FADE_VARIABLE 1
#define IRIS_FEATURE_TESSELLATION_SHADERS 1
#define IRIS_FEATURE_SSBO 1
#define IRIS_FEATURE_COMPUTE_SHADERS 1
#define IRIS_FEATURE_VERTEX_FORMAT 1
#define IRIS_FEATURE_MULTI_DRAW 1
#define IRIS_FEATURE_TEXTURE_VARIABLES 1
#define IRIS_FEATURE_SAMPLER_OBJECTS 1
#define IRIS_FEATURE_IMAGE_LOAD_STORE 1

// Distant Horizons' own block classification, as its pack-facing header defines
// it. The pack reads DH_BLOCK_* in dimensions/DH_solid.vsh, DH_solid.fsh and
// DH_translucent.vsh but never defines them, so the DH programs name an
// undeclared identifier and fail to load. They are declared here so those
// programs can be checked at all; see the note on the DH programs.
#define DH_BLOCK_AIR 0
#define DH_BLOCK_ILLUMINATED 1
#define DH_BLOCK_SOLID 2
#define DH_BLOCK_LEAVES 3
#define DH_BLOCK_GRASS 4
#define DH_BLOCK_WATER 5
#define DH_BLOCK_SNOW 6
uniform int dhMaterialId;

#define IS_LUNAR 0
#define IS_CIT 0
#define IS_CHOCO 0
#define IS_COMO 0
#define IS_OLD 0
#define IS_TERRA 0
#define IS_SEASONS 0
#define IS_MINEJ 0
#define IS_OGS 0
#define IS_BETTER 0
#define IS_BLISS 0
#define IS_RUBIUM 0
#define IS_SLAB 0
#define IS_ONYX 0
#define IS_PENTAGED 0
#define IS_SOAREX 0

"""

INCLUDE_RE = re.compile(r'^\s*#include\s+[<"]([^>"]+)[>"]')

# name -> (type, stages) for the fixed-function inputs the loader supplies.
# "v" = vertex stages, "b" = both. gl_Vertex is a vec4 here because Vitrail
# declares it as one (LegacyGlsl.fixedAttributes: "vec4 of_Vertex").
SUPPLIED = {
    "gl_Vertex":              ("vec4", "v"),
    "gl_Normal":              ("vec3", "v"),
    "gl_Color":               ("vec4", "v"),
    "gl_MultiTexCoord0":      ("vec4", "v"),
    "gl_MultiTexCoord1":      ("vec4", "v"),
    "gl_MultiTexCoord2":      ("vec4", "v"),
    "gl_MultiTexCoord3":      ("vec4", "v"),
    "gl_TextureMatrix":       ("mat4[2]", "v"),
    "gl_VertexID":            ("int", "v"),
    "gl_ModelViewMatrix":     ("mat4", "b"),
    "gl_ModelViewMatrixInverse": ("mat4", "b"),
    "gl_ProjectionMatrix":    ("mat4", "b"),
    "gl_ProjectionMatrixInverse": ("mat4", "b"),
    "gl_ModelViewProjectionMatrix": ("mat4", "b"),
    "gl_NormalMatrix":        ("mat3", "b"),
}

# Longest first, so gl_ModelViewMatrixInverse is not eaten by gl_ModelViewMatrix.
SUPPLIED_ORDER = sorted(SUPPLIED, key=len, reverse=True)

VERTEX_STAGES = {"vert", "tesc", "tese", "geom"}


def expand(path, seen=None):
    """Resolve #include the way the loader does."""
    if seen is None:
        seen = []
    real = os.path.realpath(path)
    if real in seen:
        raise RecursionError("cyclic #include: %s" % " -> ".join(seen + [real]))
    seen = seen + [real]

    out = []
    with open(path, "r", encoding="utf-8") as f:
        for line in f:
            m = INCLUDE_RE.match(line)
            if not m:
                out.append(line.rstrip("\n"))
                continue
            target = m.group(1)
            resolved = (os.path.join(PACK, target[1:]) if target.startswith("/")
                        else os.path.join(os.path.dirname(path), target))
            if not os.path.isfile(resolved):
                raise FileNotFoundError(
                    '%s: cannot resolve #include "%s" -> %s' % (path, target, resolved))
            out.append("// ---- %s ----" % target)
            out.append(expand(resolved, seen))
    return "\n".join(out)


def rename_calls(body, name, rename, drop_last_arg=False, add_last_arg=None):
    """Rewrite `name(...)` to `rename(...)`, matching parens properly.

    A regex cannot do this. The arguments are GLSL expressions, so they contain
    commas, brackets and further calls, and the only thing that identifies the
    end of an argument list is the paren that closes it. Getting this wrong is
    not a compile error at the call site - it is a rewrite that stops in the
    middle of an expression, and the diagnostic that comes back names something
    a few lines later than the mistake.
    """
    out = []
    i = 0
    while True:
        m = re.search(r"\b%s\s*\(" % re.escape(name), body[i:])
        if not m:
            out.append(body[i:])
            return "".join(out)
        start = i + m.start()
        open_paren = i + m.end() - 1
        depth = 0
        end = None
        for j in range(open_paren, len(body)):
            if body[j] == "(":
                depth += 1
            elif body[j] == ")":
                depth -= 1
                if depth == 0:
                    end = j
                    break
        if end is None:
            out.append(body[i:])
            return "".join(out)

        args = body[open_paren + 1:end]
        parts = split_top_level(args)
        if drop_last_arg:
            parts = parts[:-1]
        elif add_last_arg is not None:
            # Normalise an existing trailing lod rather than appending a second
            # one: the legacy form already carries it, and the point is to reach
            # the core profile's three-argument form, not to add to it.
            parts[-1:] = [add_last_arg]
        if parts:
            new_args = ", ".join(parts)
        else:
            new_args = ""

        out.append(body[i:start])
        out.append("%s(%s)" % (rename, new_args))
        i = end + 1


def split_top_level(args):
    """Split a GLSL argument list on the commas that are not nested."""
    parts, depth, start = [], 0, 0
    for i, ch in enumerate(args):
        if ch in "([":
            depth += 1
        elif ch in ")]":
            depth -= 1
        elif ch == "," and depth == 0:
            parts.append(args[start:i].strip())
            start = i + 1
    parts.append(args[start:].strip())
    return [p for p in parts if p != ""] or [""]


def ftransform_replacement():
    """What ftransform() expands to once the matrices are named fx_*.

    gl_Vertex arrives as a vec4, so the position is taken from its xyz and w is
    set to 1 - the same thing ftransform does.
    """
    return ("(fx_gl_ProjectionMatrix * (fx_gl_ModelViewMatrix * "
            "vec4(fx_gl_Vertex.xyz, 1.0)))")


def texelFetch2D_repl(m):
    """Kept for symmetry with the other call renames; see rename_calls."""
    return m.group(0)


def stand_in_for_loader(source, stage):
    """Rewrite the legacy dialect into something a compiler can read."""
    body = "\n".join(l for l in source.split("\n")
                     if not l.startswith("#version"))

    # gl_FragData[n] -> a located output. The attachment count comes from the
    # highest index the unit writes, so a program that writes nowhere still
    # compiles rather than tripping over a missing declaration. A compute stage
    # has no such output at all, and declaring one there is an error, so the
    # located-output declarations are skipped for it below.
    indices = [int(n) for n in re.findall(r"\bgl_FragData\[(\d)\]", body)]
    top = max(indices) if indices else 0
    body = re.sub(r"\bgl_FragData\[(\d)\]", lambda m: "fxOut" + m.group(1), body)

    # `varying`/`attribute` do not exist at the version the loader emits, and the
    # direction of travel is what decides which they become. A compute stage has
    # no stage-to-stage varyings at all.
    if stage in VERTEX_STAGES:
        body = re.sub(r"\bvarying\b", "out", body)
        body = re.sub(r"\battribute\b", "in", body)
    elif stage == "frag":
        body = re.sub(r"\bvarying\b", "in", body)

    # texture2D etc are renamed rather than rewritten: same arguments, same
    # meaning, and they do not exist at the version the loader emits.
    #
    # The pack declares a sampler literally named `texture`, which would then
    # shadow the builtin and make every `texture(...)` call a syntax error. The
    # loader resolves this by renaming the declaration, so that is what is
    # mirrored here: fx_sampler0 stands in for the pack's `texture`, and the
    # builtin keeps its own name.
    body = re.sub(r"\btexture2DProjLod\b", "textureProjLod", body)
    body = re.sub(r"\btexture2DLod\b", "textureLod", body)
    body = re.sub(r"\btexture2DProj\b", "textureProj", body)
    body = re.sub(r"\btexture2D\b", "texture", body)
    body = re.sub(r"(\buniform\s+sampler\w*\s+)texture\s*;", r"\1fx_sampler0;", body)
    body = re.sub(r"\btexture2DGradARB\b", "textureGrad", body)
    body = re.sub(r"\btexture2DGradEXT\b", "textureGrad", body)
    # gl_FragColor is the single-attachment form of gl_FragData[0]. The pack uses
    # it in one program; the loader rewrites it to a located output.
    body = re.sub(r"\bgl_FragColor\b", "fxOut0", body)
    # gl_Fog is a struct in the legacy profile, so the pack reaches through
    # `.color` to a vec4. It is declared here as the flat vec4 the loader leaves,
    # and `.color` is folded away with it.
    body = re.sub(r"\bgl_Fog\.color\b", "fx_gl_Fog", body)
    body = re.sub(r"\bgl_Fog\b", "fx_gl_Fog", body)
    # texelFetch in the core profile takes a third argument and has no overload
    # without it, so the lod the legacy form carries is normalised to 0 rather
    # than dropped.
    body = rename_calls(body, "texelFetch2D", "texelFetch", add_last_arg="0")
    body = re.sub(r"\bshadow2D\b", "fx_shadow2D", body)
    body = re.sub(r"\bftransform\s*\(\s*\)", ftransform_replacement(), body)

    # Loader-substituted, not compiler-defined: shadow2D is a depth read, and
    # the loader turns it into one. The pack binds its shadow samplers as either
    # sampler2D or sampler2DShadow depending on which coloured-shadow path is
    # compiled in, so both spellings are declared. It returns the depth rather
    # than folding in a comparison because the pack does its own compare against
    # pos.z - a sampler2DShadow returning shadow2D's 0/1 answer would take that
    # away from the shader.
    #
    # Fragment stages only: no vertex stage in this pack calls shadow2D, and a
    # sampler2DShadow cannot be read with an implicit lod in a vertex stage, so
    # declaring the overload everywhere would fail units that never use it.
    shadow2D_decl = ""
    if stage == "frag":
        # shadow2D in the legacy profile returns a vec4 whose `.x` is the answer,
        # and the pack writes it that way, so both return shapes are offered.
        # Both are functions rather than macros so that a `.x` after the call
        # still reads as a swizzle - a macro would expand to a parenthesised
        # expression and `.x` would bind to the whole of it.
        #
        # texture() on a sampler2DShadow takes a vec3 whose z is the reference
        # and folds in the comparison, which is precisely what shadow2D did, so
        # the vec3 is passed straight through. The sampler2D overload has no such
        # argument, so the depth is read and handed back raw - the pack does its
        # own compare against p.z, and must not be given shadow2D's 0/1 answer
        # from a sampler that has no reference to compare against.
        shadow2D_decl = (
            "vec4 fx_shadow2D(sampler2D s, vec3 p) "
            "{ return vec4(texture(s, p.xy).r, 0.0, 0.0, 0.0); }\n"
            "float fx_shadow2D(sampler2DShadow s, vec3 p) "
            "{ return texture(s, p); }")

    decls = []
    for name in SUPPLIED_ORDER:
        type_, where = SUPPLIED[name]
        stages = VERTEX_STAGES if "v" in where else None
        if where == "b" or (stages and stage in stages):
            decls.append("uniform %s fx_%s;" % (type_, name))
    if stage == "comp":
        # A compute stage writes through image stores, not colour attachments.
        pass
    else:
        for i in range(top + 1):
            decls.append("layout(location = %d) out vec4 fxOut%d;" % (i, i))
        if re.search(r"\bgl_FragColor\b", source):
            decls.append("vec4 fx_gl_Fog;")
        elif re.search(r"\bgl_Fog\b", source):
            decls.append("vec4 fx_gl_Fog;")

    text = "\n".join([TARGET_VERSION, ENGINE_DEFINES, shadow2D_decl]
                     + decls + [body])

    for name in SUPPLIED_ORDER:
        text = re.sub(r"\b%s\b" % re.escape(name), "fx_" + name, text)
    # Uses of the pack's `texture` sampler, now that its declaration has been
    # renamed above. Deliberately after the gl_* renames, and it must not touch
    # a call - `texture(` is the builtin, a bare `texture` is the sampler.
    text = re.sub(r"\btexture\b(?!\s*\()", "fx_sampler0", text)
    return text


def _class_utf8_constants(data):
    """Every CONSTANT_Utf8 entry in a class file, in pool order.

    A class file's constant pool is a flat run of tagged, fixed-or-variable
    length entries, and the only way to walk it is to honour each tag's size -
    which is the whole difficulty. Scanning the bytes for a string instead finds
    it in whichever entry mentions it first, and in a class file the enum's own
    names share the pool with descriptors that spell all of them out.
    """
    if data[:4] != b"\xca\xfe\xba\xbe":
        return []
    count = int.from_bytes(data[8:10], "big")
    i, out, seen = 10, [], 1
    # tag -> extra bytes after the tag. Long and double take two slots.
    fixed = {7: 2, 8: 2, 16: 2, 19: 2, 20: 2, 15: 3, 3: 4, 4: 4, 9: 4, 10: 4,
             11: 4, 12: 4, 17: 4, 18: 4}
    while seen < count and i < len(data):
        tag = data[i]
        i += 1
        if tag == 1:
            length = int.from_bytes(data[i:i + 2], "big")
            i += 2
            out.append(data[i:i + length].decode("utf-8", "replace"))
            i += length
        elif tag in (5, 6):        # Long, Double
            i += 8
            seen += 1
        elif tag in fixed:
            i += fixed[tag]
        else:
            return []              # unknown tag: not a class file we can read
        seen += 1
    return out


def engine_render_stage():
    """Vitrail's RenderStage order, read out of the mod jar.

    The pack defines MC_RENDER_STAGE_* itself, because this engine supplies
    renderStage but not the macros, so the values are a hand-copied table. It is
    worth checking against the real thing: the table looks like Iris's enum but
    is NOT the same order, and Iris's documentation gives the Iris order. Reading
    the ordering off Iris's docs and "fixing" the pack to match produces a
    volume that is populated from the wrong render stages - which shows up as
    lighting and shadows that change as the camera turns, because the volume
    stops agreeing with what is actually on screen.

    The enum's declaration order is the ordinal order, and the class file stores
    the constant names in that order in its constant pool. The jar is the only
    authority; the pack's existing table is correct against it.
    """
    jar = os.environ.get("FX_ENGINE_JAR")
    if not jar:
        root = os.path.expanduser(
            "~/.local/share/PrismLauncher/instances/26.2withmmv/minecraft/mods")
        if os.path.isdir(root):
            for name in sorted(os.listdir(root)):
                if name.startswith("vitrail") and name.endswith(".jar"):
                    jar = os.path.join(root, name)
                    break
    if not jar or not os.path.isfile(jar):
        return None
    try:
        import zipfile
        with zipfile.ZipFile(jar) as z:
            data = z.read("dev/vitrail/pack/model/RenderStage.class")
    except (KeyError, OSError, zipfile.BadZipFile):
        return None

    # The names are CONSTANT_Utf8 entries in the class file's constant pool, in
    # declaration order, and the declaration order is the enum's ordinal order.
    # A proper walk of the pool is needed rather than a scan for the bare names:
    # the pool also holds Utf8 entries for the descriptors that mention every one
    # of them ("[Ldev/vitrail/pack/model/RenderStage;" and so on), and a scan
    # finds whichever comes first in the file, which is not the enum's order.
    pool = _class_utf8_constants(data)
    # Filter to the enum's own names, keeping pool order, which is the order they
    # are declared in, which is the order their ordinals run in.
    wanted = ("NONE SKY SUNSET CUSTOM_SKY SUN MOON STARS VOID TERRAIN_SOLID "
              "TERRAIN_CUTOUT_MIPPED TERRAIN_CUTOUT ENTITIES BLOCK_ENTITIES "
              "DESTROY OUTLINE DEBUG HAND_SOLID TERRAIN_TRANSLUCENT TRIPWIRE "
              "PARTICLES CLOUDS RAIN_SNOW WORLD_BORDER HAND_TRANSLUCENT").split()
    known = set(wanted)
    order = []
    for s in pool:
        if s in known and s not in order:
            order.append(s)
    return order if len(order) == len(wanted) else None


def check_render_stage_enum(problems):
    """The pack's copy of the engine's render-stage enum must match the engine."""
    real = engine_render_stage()
    if real is None:
        print("skip  %-40s engine jar not found" % "render stage enum")
        return
    values = {("MC_RENDER_STAGE_" + n): i for i, n in enumerate(real)}

    path = os.path.join(PACK, "lib", "voxel_write.glsl")
    if not os.path.isfile(path):
        return
    with open(path, "r", encoding="utf-8") as f:
        text = f.read()
    declared = {name: int(value) for name, value in re.findall(
        r"#define (MC_RENDER_STAGE_\w+) (\d+)", text)}

    wrong = []
    for name, want in values.items():
        got = declared.get(name)
        if got != want:
            wrong.append("%s is %s, the engine's is %d"
                         % (name, "absent" if got is None else got, want))
    for name in sorted(set(declared) - set(values)):
        wrong.append("%s is not in the engine's enum" % name)

    if wrong:
        for w in wrong:
            problems.append("lib/voxel_write.glsl  render stage: " + w)
    else:
        print("ok    %-40s %d constants match the engine"
              % ("render stage enum", len(values)))


def check_option_use(problems):
    """Every option must actually change something.

    An option that is declared, shown on the settings screen and then never read
    is worse than no option at all: the user moves a slider, the picture does not
    change, and the only conclusion available is that the pack is broken.
    """
    settings = os.path.join(PACK, "lib", "settings.glsl")
    if not os.path.isfile(settings):
        return
    with open(settings, "r", encoding="utf-8") as f:
        declared = set(re.findall(r"^#define\s+([A-Z][A-Z0-9_]*)\b", f.read(), re.M))

    bodies = []
    for dirpath, _d, filenames in os.walk(PACK):
        for name in sorted(filenames):
            if not name.endswith((".glsl", ".fsh", ".vsh", ".csh", ".gsh")):
                continue
            path = os.path.join(dirpath, name)
            if os.path.realpath(path) == os.path.realpath(settings):
                continue
            try:
                bodies.append(expand(path))
            except (FileNotFoundError, RecursionError):
                pass

    for name in sorted(declared):
        if name.endswith("_INCLUDED"):
            continue
        # The declaration itself is stripped before counting, or the number means
        # "how many programs include settings.glsl".
        decl = re.compile(r"^[ \t]*#define\s+%s\b[^\n]*$" % re.escape(name), re.M)
        token = re.compile(r"\b%s\b" % re.escape(name))
        uses = sum(len(token.findall(decl.sub("", b))) for b in bodies)
        if uses == 0:
            problems.append("option %s is declared and offered to the user but "
                            "never read; the slider would do nothing" % name)


def check_reachable_options(problems):
    """Every option that is on by default must be reachable from the settings screen.

    An option that is switched on and not on any screen is one the player can
    never turn off. That is only ever what was meant for a build-time constant,
    and it is silent: the pack loads, the option works, and there is no way back.
    """
    settings = os.path.join(PACK, "lib", "settings.glsl")
    props = os.path.join(PACK, "shaders.properties")
    if not (os.path.isfile(settings) and os.path.isfile(props)):
        return
    with open(props, "r", encoding="utf-8") as f:
        text = f.read()
    # A screen body is one line, or several joined by a trailing backslash. The
    # lines are indented, and a body that ends in a continuation is the common
    # case rather than the exception, so the anchor has to allow the indent and
    # the continuation has to be consumed greedily.
    offered = set()
    for body in re.findall(r"^\s*screen\.[\w.]+\s*=\s*((?:.*\\\n)*.*)$",
                            text, re.M):
        offered.update(body.replace("\\\n", " ").split())

    with open(settings, "r", encoding="utf-8") as f:
        on = set(re.findall(r"^#define\s+([A-Z][A-Z0-9_]*)\b", f.read(), re.M))

    missing = sorted(n for n in on - offered
                     if not n.endswith("_INCLUDED")
                     # Build-time constants, not settings.
                     and not n.startswith("SHADOW_")
                     and n not in ("IS_IRIS", "IRIS_VERSION"))
    for name in missing:
        problems.append("option %s is enabled but is on no settings screen, so it "
                        "cannot be turned off by the player" % name)
    if not missing:
        print("ok    %-40s %d enabled, all reachable"
              % ("option screens", len(on)))


def programs():
    """The stub files the loader loads, i.e. the ones with a real stage."""
    for world in ("world0", "world1", "world-1", "worldx"):
        d = os.path.join(PACK, world)
        if not os.path.isdir(d):
            continue
        for name in sorted(os.listdir(d)):
            if os.path.splitext(name)[1] in STAGES:
                yield os.path.join(d, name)


def compile_one(source, ext, label, outdir):
    dst = os.path.join(outdir, label.replace("/", "_") + ext)
    with open(dst, "w", encoding="utf-8") as f:
        f.write(stand_in_for_loader(source, STAGES[ext]))
    proc = subprocess.run(
        ["glslangValidator", "-S", STAGES[ext], dst],
        capture_output=True, text=True)
    if proc.returncode == 0:
        return True, []
    errors = [l.replace(dst, label) for l in proc.stdout.split("\n")
              if "ERROR" in l]
    if proc.stderr.strip():
        errors.append(proc.stderr.strip())
    return False, errors


def profile_lines():
    """{profile name: [(option, value_or_None)]} from shaders.properties.

    A profile is a second set of option values, and a second set of option
    values is a second set of preprocessor branches. Compiling only the defaults
    proves nothing about a profile that turns a feature off, and a reference to
    something that only exists inside an #ifdef is exactly the kind of bug that
    reaches a player as a black screen on the low preset and nowhere else.
    """
    path = os.path.join(PACK, "shaders.properties")
    if not os.path.isfile(path):
        return {}
    out = {}
    with open(path, "r", encoding="utf-8") as f:
        for line in f:
            m = re.match(r"^\s*profile\.(\w+)\s*=\s*(.*)$", line)
            if not m:
                continue
            items = []
            for token in m.group(2).split():
                if ":" in token:
                    key, _, val = token.partition(":")
                    items.append((key, val))
                elif token.startswith("!"):
                    items.append((token[1:], "false"))
                else:
                    items.append((token, "true"))
            if items:
                out[m.group(1)] = items
    return out


def apply_overrides(source, items):
    """Rewrite the option declarations a profile changes.

    A boolean option is a bare `#define NAME` and is either present or not; a
    value option is declared either way - `#define NAME 2` or `const int NAME = 2`
    - and both are legal, so both are matched. The type is read off the
    declaration being replaced rather than guessed from the profile line, which
    has no idea what kind of thing it is setting.
    """
    for name, value in items:
        if value in ("true", "false"):
            # A boolean can be declared bare, or under an #ifdef. Both are
            # matched, because both are how this pack turns one on.
            pattern = re.compile(
                r"^([ \t]*)#define\s+%s\s*(?://.*)?$" % re.escape(name), re.M)
            if pattern.search(source):
                repl = "\\1#define " + name if value == "true" \
                    else "\\1// %s: off in this profile" % name
            else:
                # Not declared, or declared commented out. Turn it on by
                # uncommenting; fail loudly if the name is unknown, since a
                # profile that silently does nothing is worse than no profile.
                pattern = re.compile(
                    r"^([ \t]*)//\s*#define\s+%s\s*$" % re.escape(name), re.M)
                if not pattern.search(source):
                    raise ValueError("profile sets %s, which nothing declares" % name)
                repl = "\\1#define " + name if value == "true" else m_none(name)
                if value == "false":
                    # Already off; leave the comment in place.
                    continue
            new, n = pattern.subn(repl, source, count=1)
            if n == 0:
                raise ValueError("profile sets %s, which nothing declares" % name)
            source = new
        else:
            pattern = re.compile(
                r"^(?:#define\s+%s\s+\S+"
                r"|const\s+(?:int|float|bool)\s+%s\s*(?:=\s*)?[^;\n/]*;?)"
                % (re.escape(name), re.escape(name)), re.M)
            new, n = pattern.subn("#define %s %s" % (name, value), source, count=1)
            if n == 0:
                raise ValueError("profile sets %s, which nothing declares" % name)
            source = new
    return source


def m_none(name):
    return "// %s: off in this profile" % name


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("filter", nargs="?", default="")
    ap.add_argument("--no-profiles", action="store_true")
    ap.add_argument("--keep", action="store_true")
    args = ap.parse_args()

    if not os.path.isdir(PACK):
        print("no such pack: %s" % PACK)
        return 1

    targets = [p for p in programs() if args.filter in os.path.basename(p)]
    if not targets:
        print("no programs matched %r under %s" % (args.filter, PACK))
        return 1

    outdir = tempfile.mkdtemp(prefix="penumbra_glsl_")
    expanded, failures = {}, []

    for src in targets:
        ext = os.path.splitext(src)[1]
        name = os.path.relpath(src, PACK)
        try:
            expanded[src] = expand(src)
        except (FileNotFoundError, RecursionError) as e:
            print("FAIL  %-44s %s" % (name, e))
            failures.append(name)
            continue
        ok, errors = compile_one(expanded[src], ext, name, outdir)
        if ok:
            print("ok    %-44s %s, %d lines"
                  % (name, STAGES[ext], expanded[src].count("\n") + 1))
        else:
            failures.append(name)
            print("FAIL  %s" % name)
            for line in errors:
                print("      " + line)

    checked = len(targets)
    print("\n%d/%d programs compiled at %s" % (checked - len(failures), checked,
                                               TARGET_VERSION))

    if not args.no_profiles:
        profs = profile_lines()
        if profs:
            print()
            for pname, items in sorted(profs.items()):
                bad = 0
                for src, source in sorted(expanded.items()):
                    raw = open(src, encoding="utf-8").read()
                    # A unit that never includes the settings file has no options
                    # to override. What matters is that every unit that does take
                    # options compiles under every profile.
                    if "settings.glsl" not in raw:
                        continue
                    ext = os.path.splitext(src)[1]
                    name = os.path.relpath(src, PACK)
                    try:
                        variant = apply_overrides(source, items)
                    except ValueError as e:
                        bad += 1
                        print("FAIL  %-44s profile %s: %s" % (name, pname, e))
                        continue
                    ok, errors = compile_one(variant, ext,
                                             "%s_%s" % (pname, name), outdir)
                    if not ok:
                        bad += 1
                        failures.append("%s [%s]" % (name, pname))
                        print("FAIL  %-44s profile %s" % (name, pname))
                        for line in errors[:5]:
                            print("      " + line)
                if bad == 0:
                    print("ok    %-44s %d programs, %d options set"
                          % ("profile " + pname, len(expanded), len(items)))

    problems = []
    check_render_stage_enum(problems)
    check_option_use(problems)
    check_reachable_options(problems)
    if problems:
        print("\n%d problem(s):" % len(problems))
        for p in problems:
            print("  " + p)

    if not args.keep:
        subprocess.run(["rm", "-rf", outdir])
    else:
        print("\nexpanded sources: %s" % outdir)

    print("\n%d failing overall" % (len(failures) + len(problems)))
    return 1 if (failures or problems) else 0


if __name__ == "__main__":
    sys.exit(main())
