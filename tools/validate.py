#!/usr/bin/env python3
"""Offline validation for the FauxTracer shader pack.

Expands Iris style #include directives exactly the way Iris does
(shaders.properties: "#include \\"path\\"", leading "/" = pack root, otherwise
relative to the including file) and hands the result to glslangValidator so GLSL
errors are caught without launching Minecraft.

Usage:
    python3 tools/validate.py            # validate every program
    python3 tools/validate.py clouds     # only files whose name contains "clouds"
    python3 tools/validate.py --keep     # keep the expanded sources for inspection
"""

import os
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SHADERS = os.path.join(ROOT, "pack", "shaders")
STAGES = {".vsh": "vert", ".fsh": "frag", ".csh": "comp", ".gsh": "geom"}
PRELUDE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "iris_prelude.glsl")


def inject_prelude(source):
    """Insert the simulated Iris constants directly after the #version line.

    The #version directive has to stay first, so the prelude cannot simply be
    prepended.
    """
    with open(PRELUDE, "r", encoding="utf-8") as f:
        prelude = f.read()
    lines = source.split("\n")
    for i, line in enumerate(lines):
        if line.startswith("#version"):
            return "\n".join(lines[: i + 1] + [prelude] + lines[i + 1 :])
    return prelude + "\n" + source


def expand(path, shaders_root):
    """Return the source of `path` with all #include directives inlined."""
    with open(path, "r", encoding="utf-8") as f:
        lines = f.read().split("\n")

    out = []
    for line in lines:
        stripped = line.strip()
        if not stripped.startswith("#include"):
            out.append(line)
            continue
        target = stripped[len("#include"):].strip()
        if target.startswith('"'):
            target = target[1:]
        if target.endswith('"'):
            target = target[:-1]

        if target.startswith("/"):
            resolved = os.path.join(shaders_root, target[1:])
        else:
            resolved = os.path.join(os.path.dirname(path), target)

        if not os.path.isfile(resolved):
            raise FileNotFoundError(
                "%s: cannot resolve #include \"%s\" -> %s" % (path, target, resolved)
            )
        out.append("// ---- begin include: %s ----" % target)
        out.append(expand(resolved, shaders_root))
        out.append("// ---- end include: %s ----" % target)
    return "\n".join(out)


def programs():
    for dirpath, _dirnames, filenames in os.walk(SHADERS):
        for name in sorted(filenames):
            if os.path.splitext(name)[1] in STAGES:
                yield os.path.join(dirpath, name)


def main():
    args = [a for a in sys.argv[1:] if a != "--keep"]
    keep = "--keep" in sys.argv[1:]
    filt = args[0] if args else ""

    targets = [p for p in programs() if filt in os.path.basename(p)]
    if not targets:
        print("no shader programs matched %r" % filt)
        return 1

    tmpdir = tempfile.mkdtemp(prefix="fauxtracer_validate_")
    failures = 0
    checked = 0

    for src in targets:
        ext = os.path.splitext(src)[1]
        stage = STAGES[ext]
        rel = os.path.relpath(src, SHADERS).replace(os.sep, "_") + "." + ext[1:]
        dst = os.path.join(tmpdir, rel)

        try:
            source = expand(src, SHADERS)
        except (FileNotFoundError, RecursionError) as e:
            print("FAIL  %-42s %s" % (os.path.relpath(src, SHADERS), e))
            failures += 1
            continue

        source = inject_prelude(source)

        with open(dst, "w", encoding="utf-8") as f:
            f.write(source)

        proc = subprocess.run(
            ["glslangValidator", "-S", stage, dst],
            capture_output=True,
            text=True,
        )
        checked += 1

        if proc.returncode != 0:
            failures += 1
            print("FAIL  %s" % os.path.relpath(src, SHADERS))
            for line in proc.stdout.split("\n"):
                if line.strip() and "ERROR" in line or "WARNING" in line:
                    # strip the temp path prefix for readability
                    print("      " + line.replace(dst, os.path.relpath(src, SHADERS)))
            if proc.stderr.strip():
                for line in proc.stderr.strip().split("\n"):
                    print("      " + line)
            print("      expanded -> " + dst)
        else:
            warns = [l for l in proc.stdout.split("\n") if "WARNING" in l]
            print("ok    %-42s (%d lines%s)"
                  % (os.path.relpath(src, SHADERS), source.count("\n") + 1,
                     ", %d warnings" % len(warns) if warns else ""))
            for w in warns:
                print("      " + w.replace(dst, os.path.relpath(src, SHADERS)))

    print("\n%d/%d programs compiled cleanly" % (checked - failures, checked))
    if keep:
        print("expanded sources kept in " + tmpdir)
    else:
        subprocess.run(["rm", "-rf", tmpdir])
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
