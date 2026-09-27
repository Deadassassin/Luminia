# FauxTracer's path tracer

A stochastic screen-space path tracer, added to this pack and running on
Vitrail's Vulkan backend. It replaces the pack's single-bounce screen-space
reflection; turning `PATH_TRACER` off puts the original back.

## What it does differently

The reflection it replaces (`lib/specular.glsl`, `rayTraceSpeculars`) marched
one ray along a mirror direction and returned whatever the depth buffer said was
there. That is a single-bounce, deterministic lookup, and it is why a rough
floor read as grey plastic and a scratched metal block read as a perfect mirror.

This one:

- **samples the lobe.** Every bounce draws a GGX visible-normal sample (Heitz
  2018), so a rough surface integrates its whole reflection lobe over time
  instead of pretending one direction stands in for it.
- **bounces.** A hit spawns a new ray from the hit surface carrying an energy
  weight, with Russian roulette from the second bounce on. Light reaches a
  second and third surface.
- **integrates the noise out.** One stochastic sample per pixel per frame,
  blended into a running estimate of capped length, with the history clamped to
  its own neighbourhood.

## Where it runs

One new pass, `deferred3`, in the `deferred` group so it lands before the
lighting pass that consumes it. Two targets:

| target | contents |
| --- | --- |
| `colortex10` | `rgb` accumulated radiance, `a` history length |
| `colortex9` | `r` scene depth the estimate was made against, `g` luminance, `b` hit confidence, `a` held at 0 |

Both at full resolution, and that is not a preference. A pass cannot bind
targets of two different scales; the loader refuses to draw one that does, by
name:

```
deferred3 writes targets of two sizes, 0.500 by 0.500 of the screen and
1.000 by 1.000 of the screen for colortex1
```

That is what happened when the tracer's targets were given a `size.buffer`
directive. The G-buffer and the depth buffer are full resolution and cannot be
made otherwise, so a pass that reads them has to run at full resolution too.
A half-resolution tracer would need the depth and the G-buffer downsampled into
targets of its own first — another pass, and more targets than the chain has
room for. `PT_SCALE` therefore has to stay `1.0`, and `tools/check_pt_scale.py`
exists to keep it there.

`colortex9`'s alpha is deliberately zero. `composite3.fsh` reads that buffer's
alpha as a rain-drop mask; since nothing in the pack has ever written it, that
term has always read zero, and putting anything there would switch on a fog
effect nobody asked for.

## What it costs, and what to turn first

The tracer is the most expensive thing in the pack. In order of what they buy:

1. `PT_STEPS` — depth samples per ray. The single biggest cost. 24 is a
   reasonable default; 12 still looks right.
2. `PT_BOUNCES` — segments per path. Roughly linear. One bounce still beats the
   old SSR; two is where the second surface starts showing up.
3. `PT_MAX_FRAMES` — pure quality, almost free. Lowering it makes reflections
   respond faster and look noisier.
4. `PT_ROUGHNESS_CUTOFF` — skips tracing surfaces too rough to reflect. Raising
   it is the cheapest saving of all, at the cost of the roughest materials
   losing their sheen entirely.

Note what is *not* on that list: the tracer's resolution. It is not adjustable,
because a pass cannot mix target scales and the G-buffer is full resolution.
That makes it the most expensive thing in the pack, and it is worth knowing
before turning it on at 1920×1080.

## Why it is built the way it is

**No 3D textures, no storage buffers, no atomics.** Vitrail binds `sampler2D`
and a cube, and refuses a `sampler1D` outright — that refusal is what kills this
pack's own voxel/LPV path, and it is why the ray-traced packs on Modrinth
(Oct-Path, rethinking-voxels, Shrimple) do not run here: their tracers live
entirely in 3D storage images and atomics. The tracer carries its own
half-resolution depth instead.

**The geometry is the pack's, not re-derived.** `ptViewPos` and `ptLinZ` are
literal mirrors of `composite1.fsh`'s `toScreenSpace` and `ld()`. This pack's
projection matrices are stored in the OpenGL-era transposed convention, so
`projMAD` is the w-row and a textbook `P * v` is a *different function*.
Re-deriving the maths would have been the one way to be subtly and invisibly
wrong. `tools/validate_pt.py` compares the bodies and fails if they drift, which
is what makes the dependency safe to leave in.

**No hardware ray tracing.** `VK_KHR_ray_tracing_pipeline` is not among the
device's enabled extensions and Minecraft does not expose a ray tracing pipeline
to shader packs. Every "ray traced" pack for Minecraft is a raster or compute
tracer that reads a depth buffer or a voxel grid, and so is this one.

## Known limits

- **The reflections need a PBR resource pack to be visible.** The tracer reads
  smoothness and metalness out of `colortex8`, which the geometry programs fill
  from the resource pack's `specular` atlas. With no PBR pack installed that
  atlas is a blank 1×1, every surface comes out maximally rough, and
  `hasReflections` in `specular.glsl` is false everywhere — so the tracer is
  correct and contributes nothing. This is the pack's existing behaviour, not
  something the tracer introduces, but it is the first thing to check if the
  option appears to do nothing.
- **No shading normals.** `colortex15` holds the geometric (face) normal, so a
  reflection off a bumpy cube face is flat. Adding a real normal to the
  G-buffer is the fix and is a change to the geometry programs.
- **The sky is approximated.** A ray that leaves the screen gets a two-stop
  gradient from the frame's average sky colour plus a forward-scattering lobe,
  not the pack's atmosphere. It is only ever seen through a Fresnel term.
- **Secondary bounces read the previous frame.** `colortex3` is the last frame's
  lit scene, because this pass runs before the lighting pass that would have
  produced this frame's. One frame of lag on the second bounce.
- **No reprojection.** Anti-ghosting is the neighbourhood clamp alone. The
  matrices for a real reprojection do exist in this pack (`gbufferPreviousModelView`,
  `gbufferPreviousProjection`, `previousCameraPosition` — the old SSR uses them),
  so this is a deliberate omission rather than an impossibility.
- **Untested in game.** Everything above was validated offline. What that
  covers is syntax, types, bindings, cross-stage varyings, and the depth
  geometry. It does not cover tuning.

## Checking it

```sh
python3 tools/validate_pt.py      # compiles both stages, checks varyings and geometry
python3 tools/check_pt_scale.py    # PT_SCALE and size.buffer agree
```

`tools/validate_pt.py` compiles at `#version 130` rather than the `#version 120`
the pack is written at, purely because `texelFetch2D` — the one builtin the
pack's dialect adds — needs `texelFetch`, which is 130. 130 is still the
compatibility profile, so `gl_FragData`, `texture2D` and `ftransform` all still
mean what they mean at 120.

Neither script exercises Vitrail's GLSL-to-SPIR-V translation. Only the game
does: reload the pack and read the log.
