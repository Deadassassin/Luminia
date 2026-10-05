# Lava

Molten lava, in the opaque pass. `lib/lava.glsl`, wired into `all_solid.fsh`.

On the settings screen under **Lava**:

| Option | Default | What it does |
| --- | --- | --- |
| `LAVA` | on | The master switch. Off means the code is not compiled, not merely multiplied by zero. |
| `LAVA_TILE` | 2.0 | How many blocks one unit of the source shader's uv spans. Sets plate size. |
| `LAVA_SPEED` | 0.5 | Animation rate. See *Motion* below before touching it. |
| `LAVA_CRUST_LEVEL` | 0.78 | The contour the cracks sit on. Higher means more crust. |
| `LAVA_CRACK_WIDTH` | 0.05 | Half-width of that contour, **in blocks**. |
| `LAVA_SEAM` | 0.45 | How much hotter a crack is than the melt around it. |
| `LAVA_VARIATION` | 0.10 | How much the crust level drifts across a pool. |
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

So the field is ported as written and the crust is *derived* from it. A level set
of the scalar is a contour line through the pattern, and a contour is what a crack
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

So the lava is albedo and emission. That is also the honest way to do it: molten
rock is a dark skin over an emitter, not a mirror. A sky reflection on a lava
pool would be wrong in the way that a reflection on tar is wrong.

## What it looked like before, and why

The first working version was reported as looking like **poured gold**, with the
sides of every pool a **flat untextured orange**. Both were bugs, and neither was
the colour ramp, which is where they were assumed to be. Three separate faults,
in increasing order of how much they mattered:

### 1. The crack width was not a width

The contour was thresholded in *field value* units:

```glsl
seam = 1 - smoothstep(0, 0.03, abs(h - level))
```

which looks like a width and is not one. The field's gradient is steep enough
that a band half 0.03 units wide is a small fraction of a thousandth of a block.
The entire melt gradient fitted inside a thousandth of a block, which is a hard
binary edge. `tools/lava_render.py` confirmed it: **12.9% of the surface at heat
exactly 1.0, and only 9.2% anywhere in between.** Every molten pixel came out the
identical colour, which is a flat sheet of the top of the ramp — and a flat sheet
of yellow-white is exactly what "poured gold" means.

The fix is to divide the threshold by the local gradient, which turns a distance
in field value into a distance in blocks. `LAVA_CRACK_WIDTH` is now an honest
width in blocks, and needs two more evaluations of the field to get that
gradient.

The gradient is differenced over **one pixel**, taken from `fwidth()`. That is
deliberate: it is the only step that is meaningful at this point, and it degrades
the right way — at distance the step grows, the estimate becomes a low-pass, and
distant cracks go soft and wide, which is what distance does to a crack.

### 2. `fwidth()` has to leave the branch

The LOD needs `fwidth(worldpos.xz)`, and derivatives are undefined inside
non-uniform control flow. `blockID` is a `flat` varying, so
`if (blockID == BLOCK_LAVA)` is uniform per primitive but **not** per quad — and
a quad straddling the edge of a lava pool would read its neighbours' derivatives
across that boundary, producing a ring of wrong octave counts along every
shoreline.

So the derivative is taken in `all_solid.fsh` outside the branch and only the
`log()` that turns it into an octave count happens inside. This is why
`lavaOctaves()` and `lavaSurface()` both take the pixel size as an argument
instead of measuring it themselves.

### 3. Non-up-facing faces were painted a flat colour

```glsl
col = mix(vec3(0.55, 0.10, 0.012), col, upness);   // the wrong fix
```

Any face not pointing up got a constant orange. That was an over-correction: the
projection *is* wrong on a wall — world XZ is nearly a single point per column
there, so every feature smears into a vertical streak — but the answer is to
reproject, not to delete the detail.

A wall now gets its own 2D basis: one axis along the wall, derived from the face
normal so it works at any orientation, and one down it, compressed by
`LAVA_WALL_STRETCH` so features come out taller than wide and a crack reads as a
drip rather than a bead. Walls also run hotter, because a vertical face of molten
rock does not crust the way a horizontal one does.

## The frequency range is the thing that cannot be reasoned about

The loop magnifies the domain by 1.5 per octave, so the source's sixteen passes
span a **657:1** frequency range. A screen can show that: on Shadertoy the finest
octave is about a pixel and a half across a 1000px image. A lava surface cannot.
Plates are metres apart and cracks are centimetres — about 20:1 — so at 16
octaves the pattern's structure lands at roughly **one millimetre** and every
lava pool renders as an undifferentiated sheet.

Measured plate spacing, one standard deviation of the field converted to blocks
through the local gradient, against octave count:

| octaves | 3 | 5 | 8 | 12 | 16 |
| --- | --- | --- | --- | --- | --- |
| `LAVA_TILE` 0.35 | 0.415 | 0.308 | 0.252 | 0.243 | 0.240 bl |
| `LAVA_TILE` 1.50 | 0.078 | 0.045 | 0.022 | 0.015 | 0.014 bl |
| `LAVA_TILE` 8.00 | 0.014 | 0.009 | 0.003 | 0.001 | 0.001 bl |

Past about 8 the extra iterations stop adding structure and start adding
aliasing: they are finer than the pixel. The contact sheet from
`tools/lava_render.py` shows octave rows 10, 12 and 16 turning to speckle while
rows 5 to 8 stay clean. **`LAVA_OCTAVES_MAX` is 8, not 16.** That keeps the
source's self-similar structure and its motion, over the band a world surface can
resolve.

## `LAVA_TILE` is what decided the gold

`LAVA_TILE` scales the pattern's world size while `LAVA_CRUST_LEVEL` fixes what
fraction of it is molten — so a large `LAVA_TILE` makes the features bigger than
the transition band, and the crust disappears into the melt. At the original
8.0 there was **no crust at all**, which is the other half of why it looked like
a poured metal sheet.

Measured at the shipped `CRUST_LEVEL` and `VARIATION`, over a 12 block view:

| `LAVA_TILE` | 1.0 | 1.5 | **2.0** | 3.0 | 4.0 |
| --- | --- | --- | --- | --- | --- |
| molten | 26% | 24% | **23%** | 16% | 11% |
| dark crust | 50% | 56% | **58%** | 71% | 81% |

## The field is not normalised in the original, and that matters here

The source divides by 3 while summing 16 terms. Measured with
`tools/lava_probe.py`, that leaves the field centred at **1.34** with a maximum
of **4.98** and a minimum near 0.02.

On Shadertoy that clips to white and looks fine. Here it would make
`LAVA_CRUST_LEVEL` an unfalsifiable magic number, so `lib/lava.glsl` divides by
`2 * sqrt(octaves)` instead, which centres the field at 0.504:

| percentile | 5 | 25 | 50 | 75 | 95 |
| --- | --- | --- | --- | --- | --- |
| field | 0.177 | 0.333 | 0.472 | 0.642 | 0.939 |

The `sqrt(octaves)` is not tidiness. **Fewer octaves is a smaller field** —
measured standard deviation 0.110 at 4 octaves against 0.235 at 16 — so a fixed
threshold would make distant lava fade toward black as it simplified, which reads
as a bug rather than as level of detail. Lava pools are exactly where you look
*into* the distance. A sum of partial-cancelling cosines grows like `sqrt(n)`,
and the measurement bears that out: within 7% at 4 octaves, 2.5% at 8, under 1%
past 12.

## Two scales, because one is not enough

With a single octave band a lava pool is a uniform speckle at every distance:
close up the veins are right but there are no big dark plates, and from across a
cavern there is nothing but mottle. Real lava has both scales at once.

So `LAVA_VARIATION` runs a second, much lower frequency evaluation — 2 iterations
on a quarter-scale domain, a quarter the cost of one full evaluation — and uses it
to offset the crust level. Whole regions of a pool run crusty and whole regions
run molten.

Its mean and standard deviation are measured, not assumed, and they are not 0.5
and 1.0: `length()` of a short sum is biased low, and at 2 octaves the field
averages **0.4441** with a standard deviation of **0.2019**. Centring on 0.5
would have biased every pool toward one end of the crust range.

## Keeping the field's argument small

The loop scales the domain by 1.5 eight times, so a coordinate 10000 blocks from
the origin arrives at the cosines as ~6.6e6, where one float32 ulp is about 0.5.
`sin()` of that argument has lost most of its low bits and the pattern quantises
into blocks — fine at spawn, garbage at 10k.

Input is wrapped at 8192, which keeps every evaluation near zero. The wrap is
not a period of the field, so there is a real discontinuity at each multiple of
8192 blocks, but the two sides of one are 16 km apart and you cannot see both
from inside a 512 block draw distance.

## The emission ceiling is 0.95, not 1.0

`Emission()` in `composite1.fsh` gates its entire path on
`Emission < 254.5/255.0`:

```glsl
if( Emission < 254.5/255.0) Lighting = mix(Lighting, Albedo * Emissive_Brightness * autoBrightnessAdjust, pow(Emission, Emissive_Curve));
```

`EMISSIVE` is already 0.5 for lava — id 199 is inside the `[100, 300)` band at
`all_solid.vsh:277` — and `all_solid.vsh` raises it to at most **0.95**.

A lava pool set to 1.0 would fall out of that branch and end up **less** bright,
not more. The brightest setting is one step below the cutoff, and no position on
the `LAVA_GLOW` slider can cross it.

`EMISSIVE` is a per-block value, so this lifts the pool as a whole. The per-pixel
structure rides on the albedo instead, which is where the crack network lives.
That division of labour is forced by the G-buffer: `gl_FragData[1].a` is the only
emission channel and it is written from a `flat` varying.

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

## Looking at it without a GPU

`tools/lava_render.py` renders the albedo offline and writes a PNG, and
`--sheet` produces a contact sheet. This exists because the first version was
shipped on the strength of reasoning about a colour ramp and came out looking
like poured gold, which is not something an argument catches.

It reads the `LAVA_*` values out of `settings.glsl` rather than taking them as
arguments, so the preview cannot drift away from the pack.

The check that matters is **G/R**, not "is it orange". Gold is high red *and*
high green with almost no blue; lava is high red with green around 0.25. A
surface whose median G/R is much above about 0.55 reads as metal no matter how
orange it looks in isolation. At the shipped defaults it measures **0.255** on
molten pixels. Two mistakes this file made and had to be told about:

- The first version measured G/R over the whole surface, and 78% of that is
  near-black crust where a channel ratio is meaningless. Dividing the crust's
  0.010 by its 0.012 gives 0.83 — exactly gold's green ratio — so the check
  reported a pass on a surface it was measuring rock on. It now measures molten
  pixels only.
- The wall half of the preview rendered as horizontal stripes, and the bug was
  in the *preview*, not the shader: the harness built its wall grid with both
  axes a function of `y`. Worth knowing before trusting a preview.

## Motion, and why the metric is not a velocity

The first tuned version shipped `LAVA_SPEED 6.0` and was reported as shimmering.
Two things had to be untangled, and the second one invalidated the first
measurement I took.

**A drift velocity is the wrong measurement.** The obvious approach is to track
how fast the pattern translates, via the structure function — which is exact for
an advected field, `v = -<(dh/dt)(dh/dx)> / <(dh/dx)^2>`. Measured that way the
velocity barely moves with `LAVA_SPEED`: 0.0102 at 1.0 and 0.0114 at 6.0. That
looked like a contradiction until the source was read again.

Most of this shader's time dependence is **not** advection. Only some of it is:

```glsl
col.r += sin(x.x*2.0) * cos(x.y + t);                       // translates
col.b += cos(x.x + x.y + t + cos(x.x - x.y) + t);            // translates, at 2t
col.g += cos(x.x + x.y - cos(x.x - x.y + t*float(i) - ...)); // t*i is INSIDE a cos
```

That last one — a quarter of the accumulated field — has its time term nested
inside another cosine, so it *modulates* rather than translates. Modulation is
precisely what reads as shimmer, and it scales linearly with `LAVA_SPEED` while
translation does not move much at all.

**So the measurement is per-frame change**: the RMS of `h(t + 1/60) - h(t)` over
the field's own standard deviation. TILE-independent, normalisation-independent,
and directly proportional to what the eye sees. It is linear in `LAVA_SPEED`:

| `LAVA_SPEED` | 0.25 | **0.5** | 1.0 | 1.5 | 3.0 | 6.0 |
| --- | --- | --- | --- | --- | --- | --- |
| field changed per frame | 1.6% | **3.1%** | 6.3% | 9.4% | 18.5% | 35.7% |

`LAVA_SPEED` is now **0.5**, about 3% of the field per frame — a drift you can
follow across the crust.

**Why the original 1.0 was fine and is not now.** Measured per-frame change at the
*old* settings (`LAVA_TILE` 8, 16 octaves, `SPEED` 1.0) was 27.6%, which by this
metric is well into shimmer. It did not look like shimmer, because its feature
width was **0.0049 blocks** — sub-centimetre. Almost all of that change was
sub-pixel and averaged away before it reached the screen. The shipped
configuration has a feature width of **0.031 blocks**, six times larger, so the
same fractional change is six times more visible.

That is the same lesson as the `LAVA_TILE` section, and it is the recurring trap
in this file: **anything measured as a fraction of the field has to be converted
to world units before it means anything**, because both the field's scale and
the screen's change.

## Known limits

- **No flow direction.** The only motion is the source's own `x.x += t/64` plus
  the `t`, `2t` and `t*i` phase terms above, and none of them know which way the
  block is flowing. It reads as a slow boil rather than as a flow moving
  downhill, which is right for a cooling pool and wrong for an active one.
  Directional flow would need the block's flow vector, which this engine does not
  hand to the shader.
- **No heat haze.** Lava should shimmer the air above it. That wants a
  screen-space distortion driven by a volumetric sample, and it belongs to
  `composite`, not to a G-buffer pass.
- **Crust is albedo, not a normal.** As above: no displaced normal to write. The
  plates therefore have no relief and catch no specular, which is why
  `LAVA_SEAM` and `LAVA_VARIATION` matter so much — between them they are doing
  the work a normal would do.
- **The lava bucket item is untouched.** `ITEM_LAVA_BUCKET` is 1016, in the item
  band, and is drawn by a different pass.
- **The wall projection is a compromise.** One scalar width for two axes of
  different scale, taken as their geometric mean. Being 30% off on the vertical
  axis of a wall is invisible.
- **Tuned, not play-tested.** The constants are measured and the look was
  confirmed on rendered albedo, but `EMISSIVE`, bloom and the deferred lighting
  are not in that render — how a pool sits against a dark cave is the part
  still unverified, and the tonemap in the preview is only this pack's.