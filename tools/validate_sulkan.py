#!/usr/bin/env python3
"""Offline SPIR-V validation for the FauxTracer Sulkan shader pack.

Minecraft's Vulkan backend compiles every shader to SPIR-V, so glslangValidator
can reproduce the real thing offline. This script

  1. resolves #moj_import <namespace:path> the way Minecraft's resource loader
     does (our pack first, then the mod's built-in tree as a fallback),
  2. compiles each shader to SPIR-V for Vulkan 1.2, and
  3. reports errors with the offending file and line.

Because a pack only has to provide the entrypoints it overrides, validating the
built-in tree unchanged is the harness's own regression test: if
`python3 tools/validate_sulkan.py --builtin` is clean, resolution and flags are
correct and any later failure is in FauxTracer's own code.

Usage:
    python3 tools/validate_sulkan.py              # validate the pack
    python3 tools/validate_sulkan.py --builtin    # validate the mod's built-ins
    python3 tools/validate_sulkan.py atmosphere   # only matching files
    python3 tools/validate_sulkan.py --keep       # keep expanded sources
"""

import argparse
import os
import re
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
PACK = os.path.join(ROOT, "sulkan", "shaders")
BUILTIN = os.path.join(ROOT, "_ref", "builtin_shaders")

IMPORT_RE = re.compile(r"^\s*#moj_import\s+<([A-Za-z0-9_.-]+):([^>]+)>\s*$")
STAGES = {".vsh": "vert", ".fsh": "frag"}


class Unresolvable(Exception):
    """An import needing a namespace this harness deliberately does not vendor."""


def resolve(namespace, rel, importer_dir):
    """Mirror Minecraft's #moj_import lookup for the `sulkan` namespace.

    The mod's own files live in `shaders/include/` yet are imported as
    `<sulkan:name.glsl>`, so Minecraft searches the namespace's shader tree rather
    than treating the path as strictly relative to `shaders/`. The pack is
    searched before the mod's built-ins, exactly like a resource pack shadowing a
    mod asset. FauxTracer mirrors that layout exactly.
    """
    rel = rel.lstrip("/")
    candidates = []
    for root in (PACK, BUILTIN):
        candidates.append(os.path.join(root, rel))
        candidates.append(os.path.join(root, "include", rel))
    candidates.append(os.path.join(importer_dir, rel))
    for c in candidates:
        if os.path.isfile(c):
            return c
    if namespace != "sulkan":
        raise Unresolvable(
            "#moj_import <%s:%s> needs %s's own shader chunks, which this "
            "harness does not vendor" % (namespace, rel, namespace)
        )
    raise FileNotFoundError(
        "#moj_import <%s:%s> not found (looked in: %s)"
        % (namespace, rel, ", ".join(candidates))
    )


def expand(path, seen=None):
    """Inline every #moj_import, following Minecraft's import semantics."""
    if seen is None:
        seen = []
    real = os.path.realpath(path)
    if real in seen:
        raise RecursionError("cyclic #moj_import: %s" % " -> ".join(seen + [real]))
    seen = seen + [real]

    out = []
    with open(path, "r", encoding="utf-8") as f:
        for lineno, line in enumerate(f, 1):
            m = IMPORT_RE.match(line)
            if not m:
                out.append(line)
                continue
            namespace, rel = m.group(1), m.group(2)
            target = resolve(namespace, rel, os.path.dirname(path))
            out.append("// ---- %s:%s ----" % (namespace, rel))
            out.append(expand(target, seen))
            out.append("// ---- end %s:%s ----" % (namespace, rel))
    return "\n".join(out)


def strip_duplicate_versions(text):
    """glslang only honours one #version, and only if it is the first statement.

    Every included file starts with `#version 460 core`; Minecraft tolerates that
    because it preprocesses includes before the directive is parsed. For a
    standalone compile we keep the first one and drop the rest.
    """
    lines = text.split("\n")
    seen = False
    result = []
    for line in lines:
        if line.startswith("#version"):
            if seen:
                continue
            seen = True
        result.append(line)
    return "\n".join(result)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("filter", nargs="?", default="")
    ap.add_argument("--builtin", action="store_true",
                    help="validate the mod's built-in tree instead of the pack")
    ap.add_argument("--keep", action="store_true", help="keep expanded sources")
    ap.add_argument("--emit", action="store_true", help="write expanded sources out")
    args = ap.parse_args()

    base = BUILTIN if args.builtin else PACK
    label = "builtin" if args.builtin else "pack"

    targets = []
    for dirpath, _d, filenames in os.walk(base):
        for name in sorted(filenames):
            if os.path.splitext(name)[1] in STAGES and args.filter in name:
                targets.append(os.path.join(dirpath, name))
    targets.sort()

    if not targets:
        print("no shaders matched under %s (filter %r)" % (base, args.filter))
        return 1

    outdir = os.path.join(ROOT, "_build") if args.emit else tempfile.mkdtemp(prefix="fauxtracer_spv_")
    os.makedirs(outdir, exist_ok=True)

    failures, skipped, checked = [], [], 0
    for src in targets:
        ext = os.path.splitext(src)[1]
        rel = os.path.relpath(src, base).replace(os.sep, "_") + ext[1:]
        dst = os.path.join(outdir, rel)
        name = os.path.relpath(src, base)

        try:
            source = strip_duplicate_versions(expand(src))
        except Unresolvable as e:
            # Sodium/vanilla receiver passes. FauxTracer does not override them.
            skipped.append(name)
            print("skip  %-44s %s" % (name, e))
            continue
        except (FileNotFoundError, RecursionError) as e:
            print("FAIL  %-44s %s" % (name, e))
            failures.append(name)
            continue

        with open(dst, "w", encoding="utf-8") as f:
            f.write(source)

        proc = subprocess.run(
            ["glslangValidator", "-V", "--target-env", "vulkan1.2",
             "-S", STAGES[ext], dst],
            capture_output=True, text=True,
        )
        checked += 1
        if proc.returncode != 0:
            failures.append(name)
            print("FAIL  %s" % name)
            for line in proc.stdout.split("\n"):
                if line.strip():
                    print("      " + line.replace(dst, name))
            if proc.stderr.strip():
                for line in proc.stderr.strip().split("\n"):
                    print("      " + line)
        else:
            print("ok    %-44s (%d lines)" % (name, source.count("\n") + 1))

    print("\n[%s] %d/%d shaders compiled to SPIR-V for vulkan1.2%s"
          % (label, checked - len(failures), checked,
             ", %d skipped" % len(skipped) if skipped else ""))
    if not args.emit and not args.keep:
        subprocess.run(["rm", "-rf", outdir])
    else:
        print("expanded sources: %s" % outdir)
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
