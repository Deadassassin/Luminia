# Lava

Molten lava, in the opaque pass. `lib/lava.glsl`, wired into `all_solid.fsh`.

On the settings screen under **Lava**:

| Option | Default | What it does |
| --- | --- | --- |
| `LAVA` | on | The master switch. Off means the code is not compiled, not merely multiplied by zero. |
| `LAVA_TILE` | 8.0 | How many blocks one unit of the source shader's uv spans. |
| `LAVA_SPEED` | 1.0 | Animation rate. |
| `LAVA_CRUST_LEVEL` | 0.70 | The contour the cracks sit on. Higher means more crust. |
| `LAVA_CRACK_WIDTH` | 0.03 | Half-width of that contour, in field units. |
| `LAVA_SEAM` | 0.65 | How much hotter a crack is than the melt around it. |
| `LAVA_GLOW` | 1.0 | Brightness lift on the whole surface. Also raises `EMISSIVE`. |

## The source

A port of Shadertoy
[Dt33z7](https://www.shadertoy.com/view/Dt33z7) by
[I11212](https://twitter.com/i11212_). Sixteen iterations of a domain that is
scaled by 1.5, rotated by a radian, warped by two cosines, and accumulated into
three more. It is a good lava texture.

It is not a lava surface. The whole shader is:

```glsl
fragColor = vec4( length(col/3.0) * vec3(1.0, 0.25, 0.0), 1.0 );
```

`length()` of a `vec3` is its magnitude, so all three accumulated channels
collapse into one scalar, and that scalar is multiplied by a fixed orange. What
comes out is a monochrome orange plasma. Real lava is mostly dark cooled crust
with a thin bright network between the plates, and that second half is the part
that reads as lava rather than as a lava-textured orange.

So the field is ported exactly and the crust is *derived* from it. A level set of
the scalar is a contour line through the pattern, and a contour is what a crack
between two crust plates is. Nothing is added to the field itself, so the swirl
and the outward zoom are still the original's.

Two details in the source are kept rather than tidied, because rewriting them
would change the pattern instead of documenting it:

- `col.b += cos(A + t + cos(B) + t)` uses `iTime` twice. It reads like a slip.
  It is `cos(A + 2t + cos(B))` and that is what the shader computes.
- `rot(1.0)` is `mat2(cos, -sin, sin, cos)`. GLSL fills a matrix from its
  *columns*, so that is a rotation by **-1** radian, not +1. It is written out
  as two component expressions in `lava.glsl` so the sign is visible. Getting it
  backwards is invisible in a still frame and obvious in motion.

## Why this is in `all_solid.fsh` and not `all_translucent.fsh`

This is the whole difference between this and the water work in
`WATER_RIPPLES.md`.

Water is `gbuffers_water` / `all_translucent`. **Lava is not.** Lava is ordinary
opaque terrain geometry, drawn with the block atlas like any other block, so it
arrives in `all_solid` as `BLOCK_LAVA` and there is no water pass to hook.

That has one consequence worth being blunt about: **there is nothing to refract
and no surface to reflect off.** The ripples perturb a normal that a reflection
and a refraction then go on to read. A lava surface's normal is a cube face, and
this is a deferred pack — `colortex15` carries the geometric normal and there is
no shading normal in the G-buffer at all — so there is no displaced normal here
to displace. Perturbing `normal` would change the GI and the path tracer's
bounces and nothing else.

So the lava is albedo and emission. That is also the honest way to do it:
molten rock is a dark skin over an emitter, not a mirror. A sky reflection on a
lava pool would be wrong in the way that a reflection on tar is wrong.

## The field is not normalised in the original, and that matters here

The source divides by 3 while summing 16 terms. Measured with
`tools/lava_probe.py`, that leaves the field centred at **1.34** with a maximum
of **4.98** and a minimum near 0.02.

On Shadertoy that clips to white and looks fine. Here it would make
`LAVA_CRUST_LEVEL` an unfalsifiable magic number, so the divisor is **8.0**,
which centres the field at 0.504:

| percentile | 5 | 25 | 50 | 75 | 95 |
| --- | --- | --- | --- | --- | --- |
| field | 0.177 | 0.333 | 0.472 | 0.642 | 0.939 |

`LAVA_CRUST_LEVEL` is then a percentile rather than a guess. Measured molten
fraction at `LAVA_TILE` 8:

| level | 0.50 | 0.60 | **0.70** | 0.80 | 0.90 |
| --- | --- | --- | --- | --- | --- |
| molten | 45% | 30% | **19%** | 11% | 6% |

## The octave LOD, and why the divisor has a sqrt in it

The loop scales the domain by 1.5 every pass, so by the last octave the pattern
is 1.5^16 = 657x finer than where it started. Measured half-period per octave, at
`LAVA_TILE` 8:

| octave | 4 | 8 | 12 | 15 |
| --- | --- | --- | --- | --- |
| feature size | 4.96 bl | 0.98 bl | 0.19 bl | 0.057 bl |

The last three octaves are sub-voxel. Left alone on a lava surface they alias
into crawling noise, so the iteration count is chosen per fragment from the
world-space size of a pixel, which is Nyquist applied to that table:

```
i <= log( LAVA_TILE * PI / (2 * px) ) / log(1.5)
```

clamped to `[4, 16]`. Four is the floor because below it the field has lost its
own structure — measured correlation against the full 16 octaves is 0.21 at four
octaves, so the extra iterations would be buying noise, not detail.

That creates a problem, and it is the non-obvious part of this file. **Fewer
iterations is a smaller field.** Measured standard deviation:

| octaves | 4 | 8 | 12 | 16 |
| --- | --- | --- | --- | --- |
| std | 0.110 | 0.162 | 0.202 | 0.235 |

A fixed `LAVA_CRUST_LEVEL` would therefore make distant lava fade toward black as
it simplified, which reads as a bug rather than as level of detail — lava pools
are exactly where you look *into* the distance.

So the field is divided by `2 * sqrt(octaves)` as well. A sum of partial-cancelling
cosines grows like `sqrt(n)`, and the measurement bears that out: the fitted
correction is within 7% at 4 octaves, 2.5% at 8, and under 1% past 12. One
constant threshold then means the same crust coverage at every distance, which is
the whole point of doing it this way.

## `fwidth()` has to leave the branch

The LOD needs `fwidth(worldpos.xz)`, and derivatives are undefined inside
non-uniform control flow. `blockID` is a `flat` varying, so `if (blockID ==
BLOCK_LAVA)` is uniform per primitive but **not** per quad — and a quad
straddling the edge of a lava pool would read its neighbours' derivatives across
that boundary, producing a ring of wrong octave counts along every shoreline.

So the derivative is taken in `all_solid.fsh` outside the branch and only the
`log()` that turns it into an octave count happens inside. This is why
`lavaOctaves()` takes the pixel size as an argument instead of measuring it
itself, and it is the kind of thing that is invisible until it is not.

## The emission ceiling is 0.95, not 1.0

`Emission()` in `composite1.fsh` gates its entire path on
`Emission < 254.5/255.0`:

```glsl
if( Emission < 254.5/255.0) Lighting = mix(Lighting, Albedo * Emissive_Brightness * autoBrightnessAdjust, pow(Emission, Emissive_Curve));
```

`EMISSIVE` is already 0.5 for lava — id 199 is inside the `[100, 300)` band at
`all_solid.vsh:277`, so lava has been mildly emissive since before this file
existed. `all_solid.vsh` raises it to at most **0.95**.

A lava pool set to 1.0 would fall out of that branch and end up **less** bright,
not more. The brightest setting is one step below the cutoff.

`EMISSIVE` is a per-block value, so this lifts the pool as a whole. The
per-pixel structure rides on the albedo instead, which is where the crack
network lives. That is the division of labour, and it is forced by the G-buffer:
`gl_FragData[1].a` is the only emission channel and it is written from a `flat`
varying.

## Known limits

- **No flow direction.** The only motion is the source's own `x.x += t/64`,
  which compounds to `t/64 * 1.5^i` because the domain is scaled each pass. So
  the pattern appears to zoom outward, faster at the fine end: measured drift is
  about 0.5 blocks/s at the coarse end and over 50 blocks/s at octave 15. It
  reads as a lazy crawl, which is right for a cooling pool and wrong for an
  active flow. Directional flow would need the block's flow vector, which this
  engine does not hand to the shader.
- **No heat haze.** Lava should shimmer the air above it. That wants a screen-
  space distortion driven by a volumetric sample, and it belongs to
  `composite`, not to a G-buffer pass.
- **Crust is albedo, not a normal.** As above: no displaced normal to write.
  The plates therefore have no relief and catch no specular, which is why
  `LAVA_SEAM` matters so much — it is doing the work a normal would do.
- **The lava bucket item is untouched.** `ITEM_LAVA_BUCKET` is 1016, in the item
  band, and is drawn by a different pass.
- **Not flow-direction aware.** A lava fall and a lava lake get the same
  treatment; the up-facing test only separates them from the *sides* of a pool.
- **Untested in game.** It compiles clean in all 250 programs with the player's
  settings, with `LAVA` off, and with the profiles applied; the field's range,
  distribution, drift and gradient are measured rather than assumed; and
  `block.properties` was corrected so `flowing_lava` reaches id 199 — but nothing
  here has been looked at.

## `block.199` did not match flowing lava

`block.199=lava` matches `minecraft:lava` only. `minecraft:flowing_lava` is a
separate block and a separate id, and it was matching nothing.

This is not a cosmetic gap: **the surface of a lava lake is almost entirely
flowing lava.** Level-2 flowing lava covers the whole pool around a source, so
before this was corrected the effect applied to the single source block in the
middle and to the lake around it not at all. `block.8` gets this right for water —
`block.8=minecraft:water minecraft:flowing_water` — and lava now matches it:

```
block.199=minecraft:lava minecraft:flowing_lava
```

Worth knowing that `lpv_blocks.glsl` already keyed its light-source colour off
`BLOCK_LAVA`, so the GI has been treating a source block as a 15-range orange
light while the lake around it emitted nothing of its own.