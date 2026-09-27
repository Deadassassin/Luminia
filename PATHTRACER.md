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

## Coloured light: where it lives, and why it was missing

**The pack does not lack coloured indirect light. It ships switched off, and the
option that controls it is the least obvious one in the file.**

`indirect_effect` in `lib/settings.glsl` selects the indirect lighting algorithm,
and it is the single biggest lever on whether a scene looks photographically lit:

| value | mode | puts light on a surface? |
| --- | --- | --- |
| 0 | off | no |
| 1 | SSAO | no — only ever darkens |
| 2 | GTAO | no — only ever darkens |
| 3 | SSRT, occlusion only | no |
| 4 | **SSRT, occlusion + bounce** | **yes** |

The pack shipped on `3`. In `ApplySSRT` a ray that hits geometry adds the same
sky term to `radiance` and to `occlusion`, and the function ends by subtracting
one from the other — so on a hit the contribution is exactly zero. Mode 3 is
therefore occlusion and nothing else, which is why the scene has colour in the
sky and none in the shadows. Mode 4 is the only one where the bounce term is
non-zero.

The comment above the option claimed mode 3 "reads as real bounce light". The
arithmetic disagrees, which is a good part of why this was so hard to find.

Three things were wrong with mode 4 as it stood:

- **The reprojection bounds check was a typo.** It read
  `previousPosition.x < 1.0` twice and never tested `y`, so a reprojected point
  below the screen passed and sampled off the edge of the target — returning
  whatever the sampler clamps to, which is the top or bottom row of the frame.
  Light on a wall in the lower half of the screen could come from the sky at the
  top of it.
- **It sampled the wrong buffer.** `colortex5` is the TAA history, and
  `composite5.fsh` writes it with `fp10Dither()` because the target is
  `R11F_G11F_B10F`. That is not the defect it looks like, though — see the trap
  below. The real problem was the reprojection, not the buffer.
- **It sampled a buffer that only looks like the lit scene.** An attempt to
  "fix" the dither by reading `colortex3` instead made it dramatically worse, and
  the reason is worth writing down. `colortex3` *is* what the lighting pass
  writes, and `composite5.fsh` reads it as "the current frame" — so it reads as
  the lit scene. But `dimensions/composite.fsh` runs immediately before the
  lighting pass and overwrites `colortex3` with the **variable-penumbra shadow
  buffer**: `minshadowfilt` in red, average depth in green, blocker count in
  blue. Read from inside the lighting pass, that is what arrives. Adding it to
  the indirect term is nonsense, and it presents as a wildly over-bright,
  wrongly-tinted bounce — which is exactly how it looked.

  `colortex5` is the TAA resolve's output, i.e. the previous frame's lit scene,
  and it is the correct source. It is 10-bit and dithered, but the dither is half
  a code value and is averaged over `RAY_COUNT` rays and the TAA blend on top, so
  it does not survive into the result as noise.
- **The ghosting was accepted rather than suppressed.** Mode 4 was avoided
  because on a fast turn the reprojection is wrong for a frame or two, and the
  pack shipped 3 to avoid it. The bounce now fades out as the camera moves
  instead of trusting a reprojection it knows is bad, so it survives where the
  camera is still — which is where someone stops to look at a scene.
- **It was too strong, and could not be turned down.** `GI_Strength` defaulted to
  1.0 and its value list started at 1.0, so the bounce could only be added to
  the scene, never scaled back. A single-bounce estimate that does not model the
  energy a real bounce loses each time it lands reads as though every surface
  were a white card. Default is now 0.5 and the list goes down to 0.0.

### The voxel flood fill, and the four things wrong with it

There is a second coloured-light system: the LPV voxel flood fill. It propagates
light through a 3D volume, multiplying it by each block's tint as it travels —
which is exactly "a lamp behind blue glass lights the room blue". Four separate
things were wrong, and only the first was visible in the log.

1. **`imgBlockData` was a 1D storage image.** The bindable sampler shapes are 2D,
   2DShadow, 2DArray, 2DArrayShadow, 2DMS, 2DMSArray, Cube, CubeShadow,
   CubeArray, CubeArrayShadow, with any `i`/`u` prefix stripped. There is no 1D,
   so the compute pass that read it did not compile:
   `compute world0/shadowcomp SPIR-V failed: Unsupported texture dimensions '1D'
   for sampler imgBlockData`. This is the one the engine named, and it was the
   only reason the flood fill did not run.

   The buffer was never needed. Every entry in it is a compile-time constant
   chosen by block id, so `ptBlockLightData()` computes the same two packed uints
   from the id. The 1D shape is now gone from the pack entirely. The table was
   lifted out of `setup.csh` by script rather than by hand, because
   transcribing a thousand lines is how a colour constant gets dropped, and a
   dropped constant is a torch that lights a room the wrong colour with nothing to
   say so. `lib/lpv_blocks.glsl` is now the only copy and is meant to be edited in
   place.

2. **`setup.csh` cannot run.** The engine skips it: *compute programs skipped, no
   stage exists for them yet: [setup]*. So even a 2D image would have been
   written by nothing. It is now an empty stub, since the table needs no pass.

3. **The fragment stage gated the volume read behind a macro the engine does not
   define.** `doBlockLightLighting` read
   `#if defined IS_LPV_ENABLED && defined MC_GL_EXT_shader_image_load_store`, and
   the engine's macro set is `MC_GL_VERSION`, `MC_GL_VENDOR_*` and
   `MC_GL_RENDERER_*` — there is no `MC_GL_EXT_shader_image_load_store` in it, and
   nothing in the pack defines it either. The condition was therefore always
   false, so the volume was never sampled however live it was. It was also
   redundant: `IS_LPV_ENABLED` already requires `IRIS_FEATURE_CUSTOM_IMAGES`,
   which means exactly "can I read a custom image", and which this engine does
   provide.

4. **The shadow vertex stage gated the volume's *fill* behind the same dead
   macro** — `world0/shadow.vsh`, and the Nether's and the End's:

   ```glsl
   #if defined IS_LPV_ENABLED && defined MC_GL_EXT_shader_image_load_store
       PopulateShadowVoxel(playerpos);
   #endif
   ```

   This is the one that made light come through walls. With the call compiled out,
   nothing ever wrote `imgVoxelMask`. The engine clears that volume every frame
   and `GetVoxelBlock` reads it, so every voxel in the 256³ grid read as `0` —
   which is `BLOCK_EMPTY`, air. The flood fill therefore believed the whole volume
   was empty and propagated light straight through the world.

   The three shadow stages also each declared `uniform usampler1D texBlockData;`
   under `LPV_ENTITY_LIGHTS`, which ships on. A 1D sampler cannot be bound, so
   opening this gate would have failed the shadow pass outright with the same
   `'1D'` error as `shadowcomp`. Those declarations are gone;
   `lib/voxel_write.glsl` calls `ptBlockLightData()` instead, and
   `lib/voxel_write.glsl` now defines the `MC_RENDER_STAGE_*` numbers it tests —
   the engine supplies `renderStage` as its `RenderStage` ordinal but not Iris's
   macros for them.

`shadowcomp` was never disabled — `shaders.properties` only disables it in the
`#else` of `#ifdef LPV_ENABLED`, so with the option on it was dispatched every
frame and failing to compile.

`LPV_ENABLED` ships commented out; your saved settings have it on, which is why
the volumes were allocated and bound at all.

#### A correction

An earlier version of this document claimed a fifth reason: that
`dimensions/shadowcomp.csh` did not include `lib/settings.glsl`, and that the
whole flood fill was therefore `#ifdef`'d out. **That was wrong.** Each world
wrapper — `world0/shadowcomp.csh`, `world1`, `world-1` — already includes
`settings.glsl` before including the body, so `IS_LPV_ENABLED` was always in
scope. Adding the include to the body only included the file twice, and since it
declares `const float ambientOcclusionLevel = 1.0;` the second copy is a
redefinition that stopped the pass compiling. The include has been removed again,
and `dimensions/shadowcomp.csh` carries a note saying why it must not come back.

The flood fill was live in the source all along. The 1D image alone stopped it
running, and item 4 above is what made what it produced wrong.


## Making unlit things actually dark

Two options, and the order to reach for them matters, because one of them looks
like it should do the job and does not.

**`MIN_LIGHT_AMOUNT` is the switch you want.** Set it to `0.0`. It is on the
settings screen under *Ambient Colors*, next to `ambient_brightness`.

`doIndirectLighting` in `lib/diffuse_lighting.glsl` adds a floor to every surface
in the frame, lightmap or not:

```glsl
indirectLight += minimumLightColor * max(MIN_LIGHT_AMOUNT*0.01, nightVision * 0.1);
```

`minimumLightColor` is `vec3(1.0)`, and line 927 of `composite1.fsh` raises it by
up to 70% on surfaces angled towards the player:

```glsl
MinimumLightColor += 0.7 * MinimumLightColor * dot(slopednormal, feetPlayerPos_normalized);
```

so the floor is not even on every surface equally — it is strongest on the ground
you are standing on, which is the thing that reads as "the ground is glowing".

**`ambient_brightness` did not reach that floor, and now it does.** It multiplied
only the sky-ambient term, so turning it to `0.0` removed the sky contribution and
left the floor behind — which is a reasonable way to conclude the pack has no
ambient control when one is right there on the same screen. The floor now answers
to it as well:

```glsl
vec3 ambientFloor = minimumLightColor * MIN_LIGHT_AMOUNT * 0.01 * ambient_brightness;
indirectLight += max(ambientFloor, minimumLightColor * nightVision * 0.1);
```

Two things about that, deliberately:

- **At the default `ambient_brightness` of 1.0 it is term-for-term identical to
  what it replaced**, over the whole range of `MIN_LIGHT_AMOUNT` and night vision.
  Nothing changes until the slider is moved.
- **Night vision is not scaled.** It is a deliberate see-in-the-dark effect, not
  ambient, so darkening the world does not also remove the ability to see in it.
  The `max()` is kept so the two terms stay alternatives rather than summing.

The translucent path already scaled its own floor this way
(`fogBehindTranslucent_pass.fsh`), so this makes the opaque and translucent halves
agree rather than inventing a convention for one of them.

There is no lift after the tonemap — `composite1.fsh` ends at
`(Indirect_lighting + Direct_lighting) * albedo` — so a zero floor really is black
rather than very dark grey.


## Known limits

- **`POM` cannot compile on this engine.** `all_solid.fsh` and `all_solid.vsh` both
  do `#ifdef POM` / `#define MC_NORMAL_MAP`, and the engine already defines
  `MC_NORMAL_MAP` to a value, so the pack's empty definition is a redefinition
  with different substitutions and the geometry programs stop compiling. It is
  off by default and off in your settings, so it has not bitten — but turning
  `POM` on will break the pack here. This is pre-existing and has nothing to do
  with the tracer or the flood fill.
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
