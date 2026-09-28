// Penumbra - water interaction ripples
// ---------------------------------------------------------------------------
// Ripples on the water surface where the player disturbs it: walking through
// shallows, wading, swimming.
//
// WHY THERE IS NO HISTORY BUFFER
//
// The obvious implementation keeps a ring of the player's last N positions in a
// texture, writes one entry per frame, and draws a ring at each. That is not
// available here, and the reason is the engine rather than the design:
//
//   * The bindable sampler kinds are COLORTEX, DEPTH, SHADOW_DEPTH,
//     SHADOW_COLOUR, NOISE, PACK_TEXTURE, CENTER_DEPTH, DISTANT_DEPTH,
//     CUSTOM_IMAGE. There is no BUFFER, so `size.buffer` is not a target of its
//     own.
//   * `size.buffer.colortexN = W H` does resize a colortex, which is how a pack
//     gets a small persistent target. It needs an index, and this pack uses all
//     sixteen: they are the G-buffer, the ping-pong pairs, the TAA history, the
//     low-resolution volumetrics, the specular atlas and the path tracer's two.
//   * The 3D storage volumes are cleared every frame, so they persist nothing
//     either.
//
// So the trail is analytic. Given a water fragment's world position and the
// player's frame-to-frame motion, both of which the engine does supply
// (`cameraPosition` and `previousCameraPosition`), a wake can be described
// directly:
//
//     toFrag = worldXZ - playerXZ
//     along  = dot(toFrag, travelDir)      > 0 ahead of the player, < 0 behind
//     across = |toFrag - travelDir * along|
//
// Crests are laid out along `along` and damped by both `along` and `across`,
// which gives a wake: corrugation trailing behind, dying out with distance, and
// narrow across rather than a corridor. Rings spreading from the player add the
// local disturbance.
//
// The cost of going analytic is that the pattern is carried along by the player
// rather than left behind in the world, so the ripples travel with you instead
// of staying where you walked. Given no place to keep a position, that is the
// trade, and it is worth making once: the effect reads correctly for the thing
// it is for, which is the water around your feet while you are in it.
//
// Slopes are taken by finite difference rather than analytically, for the same
// reason getWaveNormal() in lib/waterBump.glsl does: the field is a product of a
// sine and two exponentials, and differencing it is both easier to get right and
// impossible to get subtly wrong. It also means this returns slope in exactly
// the basis getWaveNormal() returns it in - x is d/dx, y is d/dz, in world XZ -
// so the two can simply be added.

// The option is WATER_INTERACTION in lib/settings.glsl, and the call site is
// guarded by it, so nothing here needs a fallback: if this file is compiled at
// all, those two values are already declared. A `#ifndef` block that turned the
// feature on when the option was missing would be worse than useless - it would
// make "off" unobservable and the switch untestable.

// The player's motion this frame, and how much of a wake it deserves.
void waterInteractionMotion(out vec2 travelDir, out float moving) {
	vec2 motion = cameraPosition.xz - previousCameraPosition.xz;
	float travelled = length(motion);

	// One frame of walking covers about 0.07 blocks, so the low end of this sits
	// well under a slow step and the top end a few steps' worth. The point is to
	// be at zero when the player is standing still, not to measure speed: the
	// wake's phase comes from position, not from integrating a velocity, so
	// nothing here needs to be framerate-correct. A single dropped frame while
	// walking is still above the threshold.
	moving = smoothstep(0.0006, 0.005, travelled);

	// A stationary player's motion is noise, and normalising it would spin the
	// wake to an arbitrary angle. Point it along +Z instead and let `moving`
	// carry the weight, so a stationary player contributes nothing at all.
	travelDir = travelled > 1e-6 ? motion / travelled : vec2(0.0, 1.0);
}

// The surface height this adds, in blocks. Only ever evaluated for fragments
// that are water.
float waterInteractionHeight(vec2 worldXZ, float surfaceY) {
	vec2 travelDir;
	float moving;
	waterInteractionMotion(travelDir, moving);

	// Reach. Ripples belong to water the player is in, or leaning over. Someone
	// crossing a bridge five blocks above a lake must not set it moving, or every
	// crossing ripples a lake they never touched - so the effect fades out as
	// the water surface drops away below the eye. Underwater is always in reach,
	// because there the player is in the water by definition.
	float above = cameraPosition.y - surfaceY;
	float reach = above <= 0.0
		? 1.0
		: 1.0 - smoothstep(1.1, 2.5, above);

	float scale = max(WATER_RIPPLE_SCALE, 0.05);

	// Out of distance, so the finite-difference slope below does not alias into
	// noise out at the horizon where one pixel spans several wavelengths. The
	// distances scale with the feature size, because a fixed range cannot serve
	// both ends of the SCALE slider: at SCALE 4 the wavelength is 11 blocks and a
	// 26-block reach is right, while at SCALE 0.25 it is 0.7 blocks and the same
	// reach turns the far half of the lake into shimmer. Measured, not guessed -
	// the small-scale end is where this goes wrong if it is not tied to the
	// wavelength.
	vec2 toFrag = worldXZ - cameraPosition.xz;
	float dist = length(toFrag);
	float range = 1.0 - smoothstep(5.0 * scale, 18.0 * scale, dist);

	float weight = moving * reach * range;
	if (weight <= 0.0) return 0.0;

	float along = dot(toFrag, travelDir);
	float behind = max(-along, 0.0);
	vec2 lateral = toFrag - travelDir * along;
	float across = length(lateral);

	// The wake: crests perpendicular to travel, marching away behind the player.
	// exp(-behind * 0.16) is the trail dying out behind you; exp(-across^2 * 0.55)
	// makes it a wake rather than a corridor the whole lake ripples along.
	float wake = sin(behind * (2.2 / scale) - frameTimeCounter * 1.7)
		* exp(-behind * 0.16)
		* exp(-across * across * 0.55);

	// The disturbance where the player actually is: rings spreading out from
	// them, which is the part that reads as "this water has been disturbed" rather
	// than "something passed by". Fades fast with distance so it stays local.
	float rings = sin(dist * (5.0 / scale) - frameTimeCounter * 3.4)
		* exp(-dist * 0.85);

	// The amplitude is multiplied by `scale`, and that is the whole reason the
	// SCALE slider changes the size of the ripples and nothing else. Slope is
	// amplitude times frequency, and the frequency here is 1/scale, so holding
	// the amplitude fixed makes the slope fall as 1/scale: a 4.0 setting is an
	// 11-block wavelength at a tenth of the steepness, which measured as a peak
	// tilt of 0.6 against 2.0 at 1.0 - the far end of the slider was there and
	// did almost nothing. Scaling the amplitude by `scale` cancels the frequency
	// exactly, holding the steepness steady and letting the wavelength vary, which
	// is also how a real wave behaves: a longer wavelength needs a proportionally
	// taller wave to be the same wave.
	//
	// The constants are the only tuned numbers in this file, and they were set by
	// measuring the slope that comes out rather than by eye, which is the only way
	// to tune a normal perturbation without being able to look at it. The call
	// site multiplies by 10.0, mirroring the bumpmult the ambient swell gets, so
	// what matters is the slope here: about 0.2, arriving at the normal as roughly
	// 2.0 against the swell's 6.0 at the default WATER_WAVE_STRENGTH of 0.6.
	// Subordinate to the swell, which is what a wake on moving water should be,
	// but not so far under it that it cannot be seen - a first pass at a tenth of
	// this measured as visible and was not.
	return (wake * 0.070 + rings * 0.042) * weight * scale;
}

// The slope to add to the water normal, in getWaveNormal()'s basis: x is d/dx and
// y is d/dz, in world XZ.
vec2 waterInteractionSlope(vec2 worldXZ, float surfaceY) {
	// A fifth of the shortest wavelength in the field at scale 1, so the
	// difference is well inside the feature and the slope is not aliased by its
	// own sampling.
	float delta = max(0.10, 0.05 * WATER_RIPPLE_SCALE);

	float h0 = waterInteractionHeight(worldXZ, surfaceY);
	float hx = waterInteractionHeight(worldXZ + vec2(delta, 0.0), surfaceY);
	float hz = waterInteractionHeight(worldXZ + vec2(0.0, delta), surfaceY);

	return vec2(hx - h0, hz - h0) / delta;
}
