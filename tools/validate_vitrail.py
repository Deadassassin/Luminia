#!/usr/bin/env python3
"""Offline validation for the FauxTracer OptiFine-format pack.

A Vulkan shader pack is written in the OpenGL-era GLSL dialect and translated to
SPIR-V by the loader, so the pack cannot be compiled to SPIR-V as written. What
this does instead is stand in for the loader, which is more useful than a plain
syntax check:

  * #include is expanded the way the loader expands it - a leading slash against
    the shaders root, anything else against the including file - and a missing
    one is an error, not a shrug.
  * The fixed-function names the loader *supplies* (gl_Vertex, gl_Normal,
    gl_Color, gl_MultiTexCoord*, gl_TextureMatrix, the model view and projection
    family, gl_NormalMatrix, gl_VertexID) are renamed to pack-safe names and
    declared, and gl_FragData is turned into located outputs. Those names cannot
    be declared under their own spelling, because the gl_ prefix is reserved, so
    a plain glslang run would reject a perfectly correct pack.
  * The unit is then compiled at the version the loader emits (460 core) rather
    than the version the pack writes, which is what actually gets compiled. A
    construct the loader would refuse therefore fails here too.
  * A lint pass catches the dialect the loader cannot rewrite at all.

Usage:
    python3 tools/validate_vitrail.py            # everything
    python3 tools/validate_vitrail.py deferred   # only matching files
    python3 tools/validate_vitrail.py --keep     # keep the expanded sources
"""

import argparse
import os
import re
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)

# The pack is edited where the game loads it from, so a change is one hot reload
# away rather than a repackage and a drag. Override with FX_PACK.
PACK = os.environ.get("FX_PACK") or os.path.join(
    os.path.expanduser("~"),
    ".local/share/PrismLauncher/instances/26.2withmmv/minecraft/"
    "shaderpacks/fauxtracer/shaders")
if not os.path.isdir(PACK):
    PACK = os.path.join(ROOT, "vitrail", "shaders")
STAGES = {".vsh": "vert", ".fsh": "frag", ".csh": "comp"}

INCLUDE_RE = re.compile(r'^\s*#include\s+[<"]([^>"]+)[>"]')
GUARD_RE = re.compile(r"^#if !defined\((FXLIB_\w+_INCLUDED)\)\s*$", re.M)

# What the loader emits, and therefore what the unit is actually compiled as.
TARGET_VERSION = "#version 460 core"

# Image formats, as the loader's <buffer>Format const directive expects them.
PRELUDE_CONSTS = """
#define RGBA 0x1908
#define RGBA8 0x8058
#define RGB8 0x8051
#define RGBA16 0x805B
#define R8 0x8229
#define RG8 0x822B
#define R16 0x822A
#define RG16 0x822C
#define RGB16 0x8054
#define R16F 0x822D
#define RG16F 0x822F
#define RGB16F 0x881B
#define RGBA16F 0x881A
#define R32F 0x822E
#define RG32F 0x8230
#define RGB32F 0x8815
#define RGBA32F 0x8814
#define RGB10_A2 0x8059
#define RGBA4 0x8056
#define RGB5_A1 0x8057
#define RGB565 0x8D62
#define R11F_G11F_B10F 0x8C3A
"""

# name -> (type, stage) for the fixed-function inputs the loader supplies.
# "v" = vertex only, "f" = fragment only, "b" = both.
SUPPLIED = {
    # Types must match the loader's own declarations exactly. Vitrail supplies
    # gl_Vertex as a vec4 (see LegacyGlsl.fixedAttributes: "vec4 of_Vertex"), so
    # the shim declares it vec4 here: with vec3 the harness would accept
    # vec4(gl_Vertex, 1.0), which is five components under the real translation
    # and fails to parse in game.
    "gl_Vertex":                        ("vec4", "vert"),
    "gl_Normal":                        ("vec3", "vert"),
    "gl_Color":                         ("vec4", "vert"),
    "gl_MultiTexCoord0":                ("vec4", "vert"),
    "gl_MultiTexCoord1":                ("vec4", "vert"),
    "gl_MultiTexCoord2":                ("vec4", "vert"),
    "gl_MultiTexCoord3":                ("vec4", "vert"),
    "gl_TextureMatrix":                 ("mat4[2]", "vert"),
    "gl_VertexID":                      ("int", "vert"),
    "gl_ModelViewMatrix":               ("mat4", "both"),
    "gl_ModelViewMatrixInverse":        ("mat4", "both"),
    "gl_ProjectionMatrix":              ("mat4", "both"),
    "gl_ProjectionMatrixInverse":       ("mat4", "both"),
    "gl_ModelViewProjectionMatrix":     ("mat4", "both"),
    "gl_NormalMatrix":                  ("mat3", "both"),
}

# Longest first, so gl_ModelViewMatrixInverse is not eaten by gl_ModelViewMatrix.
SUPPLIED_ORDER = sorted(SUPPLIED, key=len, reverse=True)

# Texture lookups the loader renames rather than rewrites.
DEPRECATED_TEXTURE = [
    ("texture2DProjLod", "textureProjLod"),
    ("texture2DLod", "textureLod"),
    ("texture2DProj", "textureProj"),
    ("texture2DGradEXT", "textureGrad"),
    ("texture2D", "texture"),
    ("textureCubeLod", "textureLod"),
    ("textureCube", "texture"),
]

# Constructs the loader either refuses outright or cannot rewrite. Each entry is
# (pattern, why).
LINT = [
    (r"\bgl_FragColor\b",
     "core profile only; the fragment output is gl_FragData or a named out"),
    (r"\bgl_FragDepth\b",
     "the loader converts the scene depth convention itself; writing it fights that"),
    (r"\btexture2Dlod\b|\btexture2DLodEXT\b",
     "use textureLod, which the loader renames"),
    (r"\bimageLoad\(|\bimageStore\(",
     "storage images are refused through the game's shader facade"),
    (r"\bbuffer\s+\w+\s*;",
     "shader storage blocks are refused through the game's shader facade"),
    (r"\bsampler1D\b|\bsampler2DRect\b|\bsamplerCubeArray\b",
     "only 2D and cube samplers are bound by the loader"),
    (r"vec4\s*\(\s*gl_Vertex",
     "gl_Vertex is already a vec4 under the loader's translation; wrapping it "
     "makes five components and fails to parse in game - use gl_Vertex directly"),
    (r"\bgl_VertexIndex\b",
     "the game's compiler defines gl_VertexID into gl_VertexIndex, never the reverse"),
    (r"#version\s+\d+\s+core",
     "the loader emits its own version; a profile token here is a parse error"),
    (r"#extension\s+(?!ARB_shader_texture_lod\b)",
     "the loader hoists and re-emits extensions itself; an unexpected one is dropped"),
    (r"\bdiscard\b.*\bgl_FragData\[(\d)\]",
     "a discard after a fragment write is not reordered for you"),
]


def expand(path, seen=None):
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
                    "%s: cannot resolve #include \"%s\" -> %s" % (path, target, resolved))
            out.append("// ---- %s ----" % target)
            out.append(expand(resolved, seen))
    return "\n".join(out)


def stand_in_for_loader(source, stage):
    """Rewrite the OptiFine dialect into something a compiler can read.

    This mirrors what the loader does to the text: the fixed-function names it
    supplies are renamed, gl_FragData becomes located outputs, and the unit is
    compiled at the version the loader emits.
    """
    body = "\n".join(l for l in source.split("\n") if not l.startswith("#version"))

    # gl_FragData[n] -> a located output. The number of attachments comes from the
    # highest index the pack actually writes, so a program writing nowhere still
    # compiles rather than tripping over a missing declaration.
    indices = [int(n) for n in re.findall(r"\bgl_FragData\[(\d)\]", body)]
    top = max(indices) if indices else 0

    body = re.sub(r"\bgl_FragData\[(\d)\]", lambda m: "fxOut" + m.group(1), body)

    # The loader hoists a varying into the header and spells it as an in or an out.
    # `varying` itself does not exist at the version it emits, so it has to go here
    # too or every program fails on a word the pack is entitled to write.
    body = re.sub(r"\bvarying\b", "out" if stage == "vert" else "in", body)

    decls = []
    for name in SUPPLIED_ORDER:
        type_, where = SUPPLIED[name]
        if where in (stage, "both"):
            decls.append("uniform %s fx_%s;" % (type_, name))
    for i in range(top + 1):
        decls.append("layout(location = %d) out vec4 fxOut%d;" % (i, i))

    header = [TARGET_VERSION, PRELUDE_CONSTS] + decls
    text = "\n".join(header) + "\n" + body

    for name in SUPPLIED_ORDER:
        text = re.sub(r"\b%s\b" % re.escape(name), "fx_" + name, text)

    # The deprecated texture spellings are renamed rather than rewritten: same
    # arguments, same meaning, and they do not exist at the version the loader
    # emits. Doing it here means a pack may write them freely, which is the whole
    # point of the dialect.
    for old, new in DEPRECATED_TEXTURE:
        text = re.sub(r"\b%s\b" % old, new, text)
    return text


# Loader image-format names. These are not GLSL: no compiler defines them, and a
# unit that reaches the compiler with one as live code fails naming it.
FORMAT_TOKENS = ["RGBA8", "RGBA16", "RGBA16F", "RGBA32F", "RGB8", "RGB16",
                 "RGB16F", "R11F_G11F_B10F", "RGB10_A2", "R8", "RG8"]


def check_format_tokens(problems):
    """Bare format names may only appear inside the format directive block.

    A colortexNFormat directive names a format the compiler has never heard of, so
    it only stands inside a block comment. In game a format token that reaches the
    compiler as live code fails the whole program naming it, and the message points
    at the symptom rather than at the comment it escaped from - which is exactly
    how an earlier version of this pack lost every G-buffer program. The rule: a
    format token may appear only inside a /* */ block that also holds a
    colortexNFormat directive. Anywhere else it is one translator quirk away from
    becoming live.
    """
    for dirpath, _d, filenames in os.walk(PACK):
        for name in sorted(filenames):
            if not name.endswith((".glsl", ".vsh", ".fsh")):
                continue
            path = os.path.join(dirpath, name)
            with open(path, "r", encoding="utf-8") as f:
                text = f.read()

            def hide(m):
                return "" if "colortex" in m.group(0) and "Format" in m.group(0) else m.group(0)
            scrubbed = re.sub(r"/\*.*?\*/", hide, text, flags=re.S)
            rel = os.path.relpath(path, PACK)
            for tok in FORMAT_TOKENS:
                for m in re.finditer(r"\b%s\b" % tok, scrubbed):
                    line = scrubbed.count("\n", 0, m.start()) + 1
                    problems.append("%s:%d  bare format token %s outside a format "
                                    "directive block - reword or move it" % (rel, line, tok))
    if len([p for p in problems if "bare format token" in p]) == 0:
        print("ok    %-40s no stray format tokens" % "format tokens")


def programs():
    for dirpath, _d, filenames in os.walk(PACK):
        for name in sorted(filenames):
            if os.path.splitext(name)[1] in STAGES:
                yield os.path.join(dirpath, name)


VARYING_RE = re.compile(r"^varying\s+(\w+)\s+(\w+)\s*;", re.M)
PROFILE_RE = re.compile(r"^profile\.([^=\s]+)\s*=\s*(.*)$", re.M)


def profiles():
    """Every profile in shaders.properties, as {option: value} maps.

    A profile is a second set of option values, and a second set of option values
    is a second set of preprocessor branches. Compiling only the defaults proves
    nothing about a profile that turns a feature off, and a reference to something
    that only exists inside an #ifdef is exactly the kind of bug that reaches a
    player as a black screen on the Potato preset and nowhere else.
    """
    path = os.path.join(PACK, "shaders.properties")
    with open(path, "r", encoding="utf-8") as f:
        text = f.read()
    out = {}
    for name, body in PROFILE_RE.findall(text):
        overrides = {}
        for token in body.split():
            if ":" in token:
                key, _, val = token.partition(":")
                overrides[key] = val
        if overrides:
            out[name] = overrides
    return out


def apply_overrides(source, overrides):
    """Rewrite the option declarations a profile changes, leaving the rest alone.

    A value option is declared either way - `#define NAME 2` or `const int NAME = 2`
    - and both are legal, so both are matched. The type is read off the
    declaration being replaced rather than guessed from the profile line, which
    has no idea what kind of thing it is setting.
    """
    for name, value in overrides.items():
        if value in ("true", "false"):
            # A boolean option is declared as a bare #define, usually with a
            # trailing comment explaining what it turns on.
            pattern = re.compile(r"^#define\s+%s\s*(?://.*)?$" % re.escape(name), re.M)
            repl = ("#define " + name) if value == "true" else "// %s: off in this profile" % name
        else:
            pattern = re.compile(
                r"^(?:#define\s+%s\s+\S+"
                r"|const\s+(?:int|float|bool)\s+%s\s*(?:=\s*)?[^;\n/]*;?)"
                % (re.escape(name), re.escape(name)), re.M)
            repl = "#define %s %s" % (name, value)
        new, n = pattern.subn(repl, source, count=1)
        if n == 0:
            raise ValueError("profile sets %s, which nothing declares" % name)
        source = new
    return source


def varyings(source):
    return {name: type_ for type_, name in VARYING_RE.findall(source)}


def check_varying_pairs(failures, problems):
    """A varying is a link-time contract, and nothing here can link.

    Compiling the two stages separately proves each one is well formed on its own.
    It cannot prove they agree. A fragment stage that declares a varying no vertex
    stage writes is refused at load time with a message that names the pack, not
    the program, which makes it expensive to find. Matching the names here costs
    nothing.
    """
    stems = sorted({os.path.splitext(os.path.basename(p))[0] for p in programs()})
    for stem in stems:
        vert = os.path.join(PACK, stem + ".vsh")
        frag = os.path.join(PACK, stem + ".fsh")
        if not (os.path.isfile(vert) and os.path.isfile(frag)):
            continue
        try:
            vs = varyings(expand(vert))
            fs = varyings(expand(frag))
        except (FileNotFoundError, RecursionError) as e:
            problems.append("%s  %s" % (stem, e))
            continue

        missing = set(vs) - set(fs)
        extra = set(fs) - set(vs)
        if missing:
            failures.append(stem)
            problems.append("%s.vsh  writes %s, which %s.fsh never declares"
                            % (stem, ", ".join(sorted(missing)), stem))
        if extra:
            failures.append(stem)
            problems.append("%s.fsh  declares %s, which %s.vsh never writes"
                            % (stem, ", ".join(sorted(extra)), stem))
        for name in sorted(set(vs) & set(fs)):
            if vs[name] != fs[name]:
                failures.append(stem)
                problems.append("%s  varying %s is %s in the vertex stage and %s "
                                "in the fragment stage" % (stem, name, vs[name], fs[name]))
        if not missing and not extra:
            print("ok    %-40s %d varyings agree" % (stem + ".*", len(fs)))


def lint(source, name, problems):
    for pattern, why in LINT:
        for i, line in enumerate(source.split("\n"), 1):
            if re.search(pattern, line):
                problems.append("%s  %s\n      -> %s" % (name, line.strip(), why))


def compile_one(source, ext, label, outdir, quiet=False):
    """Compile one already-expanded unit. Returns (ok, error lines)."""
    dst = os.path.join(outdir, label.replace("/", "_") + "." + ext[1:])
    with open(dst, "w", encoding="utf-8") as f:
        f.write(stand_in_for_loader(source, STAGES[ext]))
    proc = subprocess.run(
        ["glslangValidator", "-S", STAGES[ext], dst],
        capture_output=True, text=True)
    if proc.returncode == 0:
        return True, []
    errors = [l.replace(dst, label) for l in proc.stdout.split("\n")
              if "ERROR" in l or "WARNING" in l]
    if proc.stderr.strip():
        errors.append(proc.stderr.strip())
    return False, errors


RENDERTARGETS_RE = re.compile(r"/\*\s*(?:RENDERTARGETS|DRAWBUFFERS)\s*:?\s*([0-9,\s]*)\*/", re.I)

# The pass that writes the game's own target rather than a pack target, and so
# names no colortex at all.
WRITES_THE_SCREEN = {"final"}

# The shadow program is also exempt, for a different reason: it writes the shadow
# colour target, never a colortex, and the loader tells the two apart by the file
# name rather than by anything the pack writes.
WRITES_SHADOWCOLOR = {"shadow"}

# The other end of the chain: a geometry program that names nothing is taken to be
# the single-attachment case, which is the sky.
GEOMETRY = {"gbuffers_terrain", "gbuffers_water", "gbuffers_basic", "gbuffers_hand",
            "gbuffers_skybasic", "gbuffers_skytextured",
            "dh_terrain", "dh_water", "shadow"}


def declared_targets(path):
    with open(path, "r", encoding="utf-8") as f:
        text = f.read()
    found = RENDERTARGETS_RE.findall(text)
    if not found:
        return None
    # Last occurrence wins, over live lines only.
    last = found[-1].strip()
    if not last:
        return []
    return [int(n) for n in re.findall(r"\d+", last)]


def check_write_targets(problems):
    """Every fullscreen pass must say which target it writes.

    A fullscreen program with no directive is inferred to write colortex0. Nothing
    is reported, the pass runs, and the image is wrong in a way that looks like a
    lighting bug: a reflection pass that quietly overwrites the albedo buffer is
    not something anyone would think to look for.
    """
    for src in sorted(programs()):
        name = os.path.basename(src)
        stem = os.path.splitext(name)[0]
        if not name.endswith(".fsh"):
            continue
        targets = declared_targets(src)
        if stem in WRITES_THE_SCREEN:
            if targets is not None:
                problems.append("%s writes the game's own target but names %s"
                                % (stem, targets))
            else:
                print("ok    %-40s writes the game's target" % (stem + ".fsh"))
            continue
        if stem in WRITES_SHADOWCOLOR:
            if targets is not None:
                problems.append("%s writes the shadow colour target but names %s"
                                % (stem, targets))
            else:
                print("ok    %-40s writes the shadow colour target" % (stem + ".fsh"))
            continue
        if targets is None:
            problems.append(
                "%s.fsh names no RENDERTARGETS, so it is inferred to write colortex0\n"
                "      -> add /* RENDERTARGETS:N */ naming the colortex it writes" % stem)
        elif stem in GEOMETRY:
            if targets != [0, 1, 2, 3][:len(targets)] and targets != [0]:
                problems.append("%s.fsh names %s; a geometry program writes the "
                                "G-buffer from zero with no gaps" % (stem, targets))
            else:
                print("ok    %-40s writes %s" % (stem + ".fsh", targets))
        else:
            print("ok    %-40s writes colortex %s" % (stem + ".fsh", targets))


def check_target_coverage(problems):
    """Every colour target should be written by someone and read by someone.

    A target nobody reads is a pass whose whole cost buys nothing. A target nobody
    writes is worse: it reads back whatever the frame left in it, which is a
    plausible-looking image rather than an error, and the stale-content bug that
    follows is close to untraceable once the image looks mostly right.
    """
    written, read = {}, {}
    for src in sorted(programs()):
        name = os.path.basename(src)
        try:
            source = expand(src)
        except (FileNotFoundError, RecursionError):
            continue
        blob = "\n".join(l for l in source.split("\n") if not l.lstrip().startswith("//"))

        if name.endswith(".fsh"):
            for slot in (declared_targets(src) or []):
                written.setdefault("colortex" + str(slot), set()).add(
                    os.path.splitext(name)[0])

        for target in set(re.findall(r"\bcolortex(\d+)\b", blob)):
            t = "colortex" + target
            if re.search(r"texture2D\(\s*" + t + r"\s*,", blob) or \
               re.search(r"textureSize\(\s*" + t + r"\s*,", blob):
                read.setdefault(t, set()).add(os.path.splitext(name)[0])

    # A colortex a texture directive rebinds is an input, never an output: the
    # pack supplied a file for that name, so it neither needs a writer nor is
    # missing one. The capture already carries the "colortex" prefix, so it is
    # stored whole - prefixing it a second time is how this check spent a while
    # failing to notice the very thing it was added for.
    props = os.path.join(PACK, "shaders.properties")
    inputs = set()
    if os.path.isfile(props):
        with open(props, "r", encoding="utf-8") as f:
            for line in f:
                m = re.match(r"\s*texture\.[A-Za-z0-9_]+\.(colortex\d+)\s*=", line)
                if m:
                    inputs.add(m.group(1))

    everything = sorted((set(written) | set(read)) - inputs, key=lambda t: int(t[8:]))
    if not everything:
        return
    print()
    for t in everything:
        w = written.get(t, set())
        r = read.get(t, set())
        if not w:
            problems.append("%s is read by %s but no program writes it"
                            % (t, ", ".join(sorted(r))))
        elif not r:
            problems.append("%s is written by %s but nothing reads it"
                            % (t, ", ".join(sorted(w))))
        else:
            print("ok    %-40s written by %s, read by %d"
                  % (t, ", ".join(sorted(w)), len(r)))


def check_option_use(problems):
    """Every option must actually change something.

    An option that is declared, shown on the settings screen and then never read
    is worse than no option at all: the user moves a slider, the picture does not
    change, and the only conclusion available is that the pack is broken. The
    compiler cannot catch it and neither can a human reading the screen, so it is
    checked here.
    """
    options = os.path.join(PACK, "lib", "options.glsl")
    if not os.path.isfile(options):
        return
    with open(options, "r", encoding="utf-8") as f:
        declared = [n for n in re.findall(r"^#define\s+([A-Z][A-Z0-9_]*)\b", f.read(), re.M)
                  if not n.endswith("_INCLUDED")]

    bodies = []
    for dirpath, _d, filenames in os.walk(PACK):
        for name in sorted(filenames):
            path = os.path.join(dirpath, name)
            if path == options or not name.endswith((".glsl", ".fsh", ".vsh")):
                continue
            try:
                bodies.append(expand(path))
            except (FileNotFoundError, RecursionError):
                pass

    for name in declared:
        # The declaration appears in every program that includes options.glsl, so
        # it is stripped before counting; otherwise the number means "how many
        # programs include the options file".
        decl = re.compile(r"^[ \t]*#define\s+%s\b[^\n]*$" % re.escape(name), re.M)
        token = re.compile(r"\b%s\b" % re.escape(name))
        uses = sum(len(token.findall(decl.sub("", b))) for b in bodies)
        if uses == 0:
            problems.append("option %s is declared and offered to the user but "
                            "never read; the slider would do nothing" % name)
        else:
            print("ok    %-40s read in %d place%s"
                  % (name, uses, "" if uses == 1 else "s"))


def check_reachable_options(problems):
    """Every enabled option must be reachable from the settings screen.

    An option that is switched on and not on any screen is one the player can
    never turn off. That is only ever what was meant for a build-time constant, and
    it is silent: the pack loads, the option works, and there is no way back. The
    failure this actually caused was a diagnostic test pattern left enabled, which
    replaced the entire frame with three flat bands - and nothing in the pack, the
    log or the validator said so.
    """
    props = os.path.join(PACK, "shaders.properties")
    options = os.path.join(PACK, "lib", "options.glsl")
    if not (os.path.isfile(props) and os.path.isfile(options)):
        return
    with open(props, "r", encoding="utf-8") as f:
        text = f.read()
    offered = set()
    for body in re.findall(r"^screen\.\w+\s*=\s*(.*)$", text, re.M):
        offered.update(body.split())

    with open(options, "r", encoding="utf-8") as f:
        opts = f.read()
    on = set(n for n in re.findall(r"^#define\s+([A-Z][A-Z0-9_]*)\b", opts, re.M)
          if not n.endswith("_INCLUDED"))

    missing = sorted(on - offered)
    for name in missing:
        problems.append("option %s is enabled but is on no settings screen, so it "
                        "cannot be turned off by the player" % name)
    if not missing:
        print("ok    %-40s %d enabled, all reachable" % ("option screens", len(on)))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("filter", nargs="?", default="")
    ap.add_argument("--keep", action="store_true",
                    help="keep the expanded sources")
    ap.add_argument("--no-profiles", action="store_true",
                    help="only compile the default option values")
    args = ap.parse_args()

    targets = sorted(p for p in programs() if args.filter in os.path.basename(p))
    if not targets:
        print("no programs matched %r" % args.filter)
        return 1

    outdir = tempfile.mkdtemp(prefix="fauxtracer_glsl_")
    failures, problems, checked = [], [], 0

    expanded = {}
    for src in targets:
        ext = os.path.splitext(src)[1]
        name = os.path.relpath(src, PACK)
        try:
            expanded[src] = expand(src)
        except (FileNotFoundError, RecursionError) as e:
            print("FAIL  %-40s %s" % (name, e))
            failures.append(name)
            continue

        checked += 1
        before = len(problems)
        lint(expanded[src], name, problems)

        ok, errors = compile_one(expanded[src], ext, name, outdir)
        if ok:
            print("ok    %-40s (%d lines%s)"
                  % (name, expanded[src].count("\n") + 1,
                     ", %d lint" % (len(problems) - before) if len(problems) > before else ""))
        else:
            failures.append(name)
            print("FAIL  %s" % name)
            for line in errors:
                print("      " + line)

    print("\n%d/%d programs compiled at %s" % (checked - len(failures), checked, TARGET_VERSION))
    defaults_ok = checked - len(failures)

    # Every profile is a different set of preprocessor branches, so every profile
    # is a different compilation.
    if not args.no_profiles:
        profs = profiles()
        if profs:
            print()
            for pname, overrides in sorted(profs.items()):
                bad = 0
                for src, source in sorted(expanded.items()):
                    ext = os.path.splitext(src)[1]
                    name = os.path.relpath(src, PACK)
                    # A unit that never includes the options file has no options to
                    # override - the shadow programs are minimal by design, and
                    # applying a profile to them would fail naming the option rather
                    # than testing anything. What matters is that every unit that
                    # DOES take options compiles under every profile.
                    with open(src, "r", encoding="utf-8") as f:
                        raw = f.read()
                    if "options.glsl" not in raw:
                        continue
                    try:
                        variant = apply_overrides(source, overrides)
                    except ValueError as e:
                        problems.append("profile %s  %s" % (pname, e))
                        bad += 1
                        continue
                    ok, errors = compile_one(variant, ext, "%s_%s" % (pname, name), outdir)
                    if not ok:
                        bad += 1
                        failures.append("%s [%s]" % (name, pname))
                        print("FAIL  %-40s profile %s" % (name, pname))
                        for line in errors[:4]:
                            print("      " + line)
                if bad == 0:
                    print("ok    %-40s %d programs, %d options changed"
                          % ("profile " + pname, len(expanded), len(overrides)))
                else:
                    print("      %d of %d failed under %s" % (bad, len(expanded), pname))

    check_varying_pairs(failures, problems)
    check_format_tokens(problems)
    check_option_use(problems)
    check_reachable_options(problems)
    check_write_targets(problems)
    check_target_coverage(problems)
    print("\n%d/%d programs compiled at %s, %d default, %d failing overall"
          % (checked, checked, TARGET_VERSION, defaults_ok, len(failures)))
    if problems:
        print("\ndialect lint (%d):" % len(problems))
        for p in problems:
            print("  " + p)
    if not args.keep:
        subprocess.run(["rm", "-rf", outdir])
    else:
        print("\nexpanded sources: %s" % outdir)
    return 1 if (failures or problems) else 0


if __name__ == "__main__":
    sys.exit(main())
