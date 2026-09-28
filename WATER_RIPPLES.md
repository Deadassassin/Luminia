# Water interaction ripples

Ripples on the water surface where the player disturbs it: wading through
shallows, swimming, walking through a river. `lib/water_interaction.glsl`, wired
into the water normal in `dimensions/all_translucent.fsh`.

On the settings screen under **Water**, next to Wave Strength:

| Option | Default | What it does |
| --- | --- | --- |
| `WATER_INTERACTION` | on | The master switch. Off means the code is not compiled, not merely multiplied by zero. |
| `WATER_RIPPLE_STRENGTH` | 1.0 | How hard the water is pushed. 0.0 is flat. |
| `WATER_RIPPLE_SCALE` | 1.0 | Size of the ripples, and how far they reach. |

## Eclipse does not have this

Worth saying plainly, since it was the reference: the Eclipse pack in
`shaderpacks/Eclipse-Shader-Unstable` has no player-interaction ripples. Its
`lib/ripples.glsl` is 71 lines of rain-on-water — a cell-based procedural field
animated by `frameTimeCounter`, with no knowledge of where the player is. It is
called from two places, `all_translucent.fsh:815` and `composite1.fsh:920`, and
both are ambient. Nothing in that pack, and nothing in any other pack in this
directory, produces a wake from player movement. So this is written from scratch
rather than ported, and the comparison to Eclipse will not be exact.

## Why there is no position history

The obvious implementation keeps a ring of the player's last N positions in a
texture, writes one entry per frame, and draws a ring at each. That is not
available on this engine, and it is worth being precise about why, because it
determines the one compromise below:

- The bindable sampler kinds are `COLORTEX`, `DEPTH`, `SHADOW_DEPTH`,
  `SHADOW_COLOUR`, `NOISE`, `PACK_TEXTURE`, `CENTER_DEPTH`, `DISTANT_DEPTH`,
  `CUSTOM_IMAGE`. There is no `BUFFER`, so `size.buffer` is not a target of its
  own.
- `size.buffer.colortexN = W H` does resize a colortex, which is how a pack gets a
  small persistent target. It needs an index, and this pack uses all sixteen:
  the G-buffer, the ping-pong pairs, the TAA history, the low-resolution
  volumetrics, the specular atlas, and the path tracer's two.
- The 3D storage volumes are cleared every frame, so they persist nothing either.

What the engine *does* supply is `cameraPosition` and `previousCameraPosition`, so
the player's frame-to-frame motion is available, and the trail is derived from it
analytically:

```
toFrag = worldXZ - playerXZ
along  = dot(toFrag, travelDir)      > 0 ahead of the player, < 0 behind
across = |toFrag - travelDir * along|
```

Crests are laid out along `along` and damped by both `along` and `across`, which
gives a wake — corrugation trailing behind, dying out with distance, and narrow
across rather than a corridor the whole lake ripples along. Rings spreading from
the player add the local disturbance, which is the part that reads as "this water
has been disturbed" rather than "something passed by".

**The compromise:** the pattern is carried along by the player rather than left
behind in the world, so the ripples travel with you instead of staying where you
walked. Given nowhere to keep a position, that is the trade. The effect reads
correctly for the thing it is for, which is the water around your feet while you
are in it.

Slopes come from finite differences, for the same reason `getWaveNormal()` in
`lib/waterBump.glsl` does: the field is a sine times two exponentials, and
differencing it is easier to get right than differentiating it. It also means the
return value is slope in exactly `getWaveNormal()`'s basis — x is d/dx, y is
d/dz, world XZ — so the two simply add.

## The gates, and why each exists

Three things have to be true before a water fragment is disturbed. Each exists
because the alternative is wrong in a way that looks like a bug.

- **The player must be moving.** `length(cameraPosition.xz -
  previousCameraPosition.xz)` against a `smoothstep(0.0006, 0.005, ...)` gate.
  One frame of walking is about 0.07 blocks, so this is zero when still and one
  well before a slow step. It is deliberately not a speed measurement: the wake's
  phase comes from position, not from integrating a velocity, so nothing here
  needs to be framerate-correct.
- **The player must be near the surface.** `cameraPosition.y - waterSurfaceY`
  against a `smoothstep(1.1, 2.5, ...)` fade. Without this, crossing a bridge
  sets the lake five metres below moving, which is the kind of thing that gets a
  shader pack uninstalled. Underwater is always in reach — there the player is in
  the water by definition.
- **The water must be near enough to see.** A distance fade whose limits scale
  with the feature size, `smoothstep(5 * scale, 18 * scale, dist)`. A fixed range
  cannot serve both ends of the SCALE slider: at 4.0 the wavelength is 11 blocks
  and a 26-block reach is right, while at 0.25 it is 0.7 blocks and the same reach
  turns the far half of the lake into shimmer.

The surface height is captured *before* `getParallaxDisplacement()` moves the
sample point. Reading it afterwards puts the reach gate in slightly the wrong
place, by up to the depth of the displacement.

## How the strength was set

A normal perturbation cannot be tuned by eye from here, so the numbers were
measured by porting the height function out and probing it. Two things came out
of that which guessing would have got wrong:

- **A first pass was a tenth of this and was invisible.** The peak slope was 0.06
  against the ambient swell's 6.0. It is now about 0.2, which arrives at the
  normal as roughly 2.0 — subordinate to the swell, which is what a wake on moving
  water should be, but actually visible.
- **`SCALE` had to scale the amplitude too.** Slope is amplitude times frequency,
  and the frequency here is `1/scale`, so a fixed amplitude makes the slope fall
  as `1/scale`. At 4.0 that measured a peak tilt of 0.6 against 2.0 at 1.0 — the
  far end of the slider was present and did almost nothing. Multiplying the
  amplitude by `scale` cancels the frequency exactly, so the slider changes size
  and reach and holds its strength. It is also how a real wave behaves: a longer
  wavelength needs a proportionally taller wave to be the same wave.

The call site multiplies by `10.0`, mirroring the `bumpmult` the ambient swell
gets, and it is applied *after* that scaling rather than before, so
`WATER_RIPPLE_STRENGTH` means the same thing whatever `WATER_WAVE_STRENGTH` is
set to. Strong waves and a subtle wake are separate things and should not be
coupled.

## Known limits

- **The trail follows you** rather than staying in the world, as above.
- **No foam or spray.** This only perturbs the normal, so it changes the
  reflection, the refraction and the lighting but adds no whitewater at the
  surface. Foam would need a mask carried to the shading pass, and every colortex
  is in use.
- **A single straight wake.** There is no left-and-right separation as a real
  hull makes, and no lateral spread from footfalls.
- **It follows the camera's XZ, not the player's feet.** They differ only while
  the camera is in first person and the player is in a boat or a bed, which is
  not worth another uniform to distinguish.
- **Untested in game.** It compiles clean in all 250 programs with the player's
  settings, with the option off, and with every option on, and the field's shape
  has been measured rather than assumed — but nothing here has been looked at.
