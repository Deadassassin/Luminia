#!/usr/bin/env python3
"""Compile the path tracer's two programs the way the pack's dialect reads.

Why this exists
---------------
`tools/validate_vitrail.py` in this repository was written for a different pack
and gets 32 of 294 programs through this pack's dialect, because it assumes a
core-profile shim at #version 460 and this pack is written at #version 120 in the
compatibility profile. It is not a usable check here.

So this checks the new passes on their own terms. The pack is written at
`#version 120`, where `gl_FragData`, `texture2D` and `ftransform` all exist and
`texelFetch` does not, so the harness does three things and then hands the unit
to glslang:

  * bumps 120 to 130, which is still the compatibility profile and therefore
    still has `gl_FragData` and `texture2D`, but also has `texelFetch` - the
    one builtin the pack's dialect adds, as `texelFetch2D`
  * declares `far`, which the loader supplies and which every program in this
    pack therefore leaves undeclared
  * checks the varying sets of the two stages against each other, which nothing
    else here can do and which the loader refuses at load time with a message
    that names the pack rather than the program

What this cannot do is stand in for the loader's translation to SPIR-V. Only the
game can do that. What it does catch is every syntax, type, binding and
link-time-varying mistake in the code, which is the large majority of what can
go wrong in a file nobody has run yet.

Usage:
    python3 tools/validate_pt.py
"""

import os
import re
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
SHADERS = os.path.join(ROOT, "shaders")

INCLUDE_RE = re.compile(r'^\s*#include\s+[<"]([^>"]+)[>"]')
VARYING_RE = re.compile(r"^\s*flat\s+varying\s+(\w+)\s+(\w+)\s*;", re.M)
VARYING_RE_LOOSE = re.compile(r"^\s*varying\s+(\w+)\s+(\w+)\s*;", re.M)

# What the loader hands the compiler that the pack is therefore allowed to use
# without declaring.
#
# Only `texelFetch2D` belongs here. An earlier version of this harness also
# declared `far`, which was wrong and hid a real bug: `far` is not engine
# supplied, it is declared by /lib/Shadow_Params.glsl, and a program that reads
# it without declaring it is broken in game even though it compiled clean here.
# Anything the shader is supposed to declare itself has to stay undeclared here,
# or this harness stops being able to catch that class of mistake.
PRELUDE = """
#define texelFetch2D(t, c, l) texelFetch(t, c, l)
"""


def expand(path, seen=None):
    """Expand #include the way the loader does.

    A leading slash resolves against the shaders root, anything else against
    the including file. A missing include is an error rather than a shrug,
    because a pack that silently loses half its library still compiles.
    """
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


def prepare(source, stage):
    """Turn one expanded unit into something a compiler will accept."""
    body = "\n".join(l for l in source.split("\n")
                     if not l.lstrip().startswith("#version"))
    return "\n".join([
        "#version 130",
        PRELUDE,
        body,
    ])


def varyings(source):
    found = {}
    for pattern in (VARYING_RE, VARYING_RE_LOOSE):
        for type_, name in pattern.findall(source):
            found[name] = type_
    return found


def grab_function(relpath, name):
    """The body of one function, comments stripped."""
    path = os.path.join(SHADERS, relpath)
    with open(path, "r", encoding="utf-8") as f:
        src = f.read()
    m = re.search(r"^[^\n;{}]*\b%s\s*\([^)]*\)\s*\{" % re.escape(name), src, re.M)
    if not m:
        return None
    start = m.end() - 1
    depth, i = 0, start
    while i < len(src):
        if src[i] == "{":
            depth += 1
        elif src[i] == "}":
            depth -= 1
            if depth == 0:
                break
        i += 1
    body = re.sub(r"//[^\n]*", "", src[start:i + 1])
    return re.sub(r"\s+", "", re.sub(r"/\*.*?\*/", "", body, flags=re.S))


def canonical(text):
    """Strip a function down to operators, literals and structure.

    Every identifier and type becomes the same placeholder, so a rename cannot
    read as a difference. vec3(uv, depth) and a parameter that already holds
    vec3(uv, depth) are the same expression and have to compare equal, which is
    why the constructor is folded away rather than kept as a call.
    """
    text = re.sub(r"\bvec[234]\s*\(([^()]*)\)", lambda m: m.group(1), text)
    text = re.sub(r"\b(?:vec[234]|mat[234]|float|int|bool)\b", "T", text)
    return re.sub(r"\b[A-Za-z_]\w*\b", "x", text)


def check_geometry(problems):
    """The tracer must reuse the pack's geometry, not re-derive it.

    Every depth comparison in this pack - the GTAO, the SSRT, the old SSR and now
    the tracer - agrees on what a depth sample means because they all call the
    same three functions. Re-deriving the matrices in the tracer was the one way
    to be subtly and invisibly wrong: the pack's projection matrices are stored
    in the OpenGL-era transposed convention, so `projMAD` is the w-row and a
    textbook `P * v` is not the same function.

    The trade is that the tracer now has a dependency it does not own: if
    composite1.fsh's unprojection or ld() is ever changed, ptViewPos and ptLinZ
    have to change with it or the tracer will quietly disagree with the rest of
    the pack. This check is what makes that dependency safe to leave in.
    """
    pairs = [
        ("unprojection", "dimensions/composite1.fsh", "toScreenSpace",
         "lib/pathtracer.glsl", "ptViewPos"),
        ("linear depth", "dimensions/composite1.fsh", "ld",
         "lib/pathtracer.glsl", "ptLinZ"),
        ("projection", "lib/specular.glsl", "toClipSpace3",
         "lib/projections.glsl", "toClipSpace3"),
    ]
    for label, pa, na, pb, nb in pairs:
        a, b = grab_function(pa, na), grab_function(pb, nb)
        if a is None or b is None:
            problems.append("could not find %s / %s to compare" % (na, nb))
            continue
        if canonical(a) != canonical(b):
            problems.append(
                "%s has drifted: %s:%s and %s:%s no longer agree. The tracer has "
                "to be moved with it or the two will read depth differently"
                % (label, pa, na, pb, nb))
        else:
            print("ok    %-24s %s matches the pack's" % ("geometry: " + label, nb))


def main():
    units = [
        ("deferred3.fsh", "frag"),
        ("deferred3.vsh", "vert"),
    ]
    problems = []
    expanded = {}

    with tempfile.TemporaryDirectory(prefix="fauxtracer_pt_") as tmp:
        for name, stage in units:
            src = os.path.join(SHADERS, "dimensions", name)
            try:
                text = expand(src)
            except (FileNotFoundError, RecursionError) as e:
                print("FAIL  %-24s %s" % (name, e))
                problems.append("%s: %s" % (name, e))
                continue
            expanded[name] = text

            dst = os.path.join(tmp, name.replace(".", "_") + "." + stage)
            with open(dst, "w", encoding="utf-8") as f:
                f.write(prepare(text, stage))

            proc = subprocess.run(
                ["glslangValidator", "-S", stage, dst],
                capture_output=True, text=True)
            label = dst.replace(tmp + os.sep, "")
            if proc.returncode == 0:
                print("ok    %-24s %d lines expanded, compiled at #version 130"
                      % (name, text.count("\n") + 1))
            else:
                print("FAIL  %s" % name)
                for line in (proc.stdout + proc.stderr).split("\n"):
                    if "ERROR" in line or "WARNING" in line:
                        print("      " + line.replace(dst, label))
                problems.append("%s failed to compile" % name)

        # The two stages have to agree on every varying. Compiling them proves
        # each is well formed; it cannot prove they match, and a mismatch is
        # refused at load time naming the pack rather than the program.
        if "deferred3.vsh" in expanded and "deferred3.fsh" in expanded:
            vs = varyings(expanded["deferred3.vsh"])
            fs = varyings(expanded["deferred3.fsh"])
            missing = set(vs) - set(fs)
            extra = set(fs) - set(vs)
            for name in sorted(missing):
                problems.append("deferred3.vsh writes %s, which deferred3.fsh never declares" % name)
            for name in sorted(extra):
                problems.append("deferred3.fsh declares %s, which deferred3.vsh never writes" % name)
            for name in sorted(set(vs) & set(fs)):
                if vs[name] != fs[name]:
                    problems.append("varying %s is %s in the vertex stage and %s in the fragment stage"
                                    % (name, vs[name], fs[name]))
            if not missing and not extra and not problems:
                print("ok    %-24s %d varyings agree" % ("deferred3.*", len(fs)))

    # Every option the tracer introduces has to be declared, or the pass reads a
    # name nothing defines and the compiler says so.
    settings = os.path.join(SHADERS, "lib", "settings.glsl")
    with open(settings, "r", encoding="utf-8") as f:
        declared = set(re.findall(r"^#define\s+(PT_[A-Z0-9_]+)\b", f.read(), re.M))
    used = set()
    for text in expanded.values():
        used |= set(re.findall(r"\bPT_[A-Z0-9_]+\b", text))
    for name in sorted(used - declared):
        problems.append("%s is used but lib/settings.glsl never declares it" % name)
    for name in sorted(declared - used):
        print("warn  %-24s declared in settings.glsl but not read by deferred3"
              % name)

    print()
    check_geometry(problems)

    print()
    if problems:
        print("%d problem(s):" % len(problems))
        for p in problems:
            print("  " + p)
        return 1
    print("path tracer programs compile and link clean")
    print()
    print("This does not exercise the loader's GLSL-to-SPIR-V translation. Only")
    print("the game can do that: reload the pack and read the log.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
