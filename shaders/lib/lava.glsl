// Molten lava, for the opaque pass. Ported from Shadertoy Dt33z7 by I11212
// (https://www.shadertoy.com/view/Dt33z7), which is 16 iterations of a scaled,
// rotated, warped domain accumulating three cosines. Everything below is that
// field plus the two things it does not have.
//
// =============================================================================
// WHAT THE ORIGINAL DOES, AND WHY IT IS NOT ENOUGH
// =============================================================================
//
//     fragColor = vec4( length(col/3.0) * vec3(1.0, 0.25, 0.0), 1.0 );
//
// length() of a vec3 is its magnitude, so the whole shader is one scalar driving
// one fixed orange. There is no crust, no heat scale and no crack network - a
// flat orange plasma, which is a good lava *texture* and not a lava *surface*.
// Real lava is mostly dark cooled crust with a thin bright network between the
// plates, and the second half of that sentence is the part that reads as lava.
//
// So the field is kept exactly as written and the crust is derived from it: a
// level set of the scalar is a contour line through the pattern, and a contour
// is what a crack between two crust plates is. Nothing is added to the field
// itself, so the motion and the swirl are still the original's.
//
// =============================================================================
// WHERE IT RUNS, AND WHY IT IS IN all_solid.fsh AND NOT all_translucent.fsh
// =============================================================================
//
// Lava is drawn in the *opaque* pass, not the water pass. Water is
// gbuffers_water / all_translucent; lava is ordinary terrain geometry, so it
// arrives in all_solid as BLOCK_LAVA (199) and is textured from the block atlas
// like any other block.
//
// That has one consequence worth stating plainly, because it is the whole
// difference between this and the water work in WATER_RIPPLES.md: **there is
// nothing to refract and no water surface to reflect off.** The water ripples
// perturb a normal that a reflection and a refraction then read. Lava has one
// normal - the face normal of a cube - and a deferred pack shades that normal,
// it does not shade a displaced one. So the lava here is albedo and emission,
// which is also the honest way to do it: molten rock is an emitter with a dark
// skin, not a mirror.
//
// The up-facing test matters for the same reason. The field is a function of
// world XZ, which is only meaningful on a surface you look down on. Projected
// onto the side of a lava fall it smears, so faces that are not up-facing get
// the pattern faded out and keep a flat hot colour.
//
// =============================================================================
// THE FIELD IS NOT NORMALISED IN THE ORIGINAL, AND THAT MATTERS HERE
// =============================================================================
//
// The shader sums 16 terms and divides by 3. Measured by tools/lava_probe.py,
// that leaves the field centred at 1.34 with a maximum of 4.98 - which on
// Shadertoy clips to white and is fine, and here would make the crust threshold
// an unfalsifiable magic number.
//
// The divisor is 8.0 instead, which centres the field at 0.504 (p75 0.642,
// p95 0.939). Every threshold below is a real percentile of the distribution
// rather than a guess.
//
// It is divided by the octave count as well, and that is not tidiness. The
// octave LOD below cuts iterations with distance, and fewer iterations is a
// *smaller* field: measured standard deviation is 0.110 at 4 octaves against
// 0.235 at 16. A fixed threshold would therefore make distant lava fade to black
// as it simplified, which reads as a bug, not as level of detail. Dividing by
// sqrt(octaves) cancels it - the sum of 16 partial-cancelling cosines grows like
// sqrt(n), and the measurement confirms it to within 7% at 4 octaves and better
// than 1% past 8. So one constant threshold means the same crust coverage at
// every distance.

#ifdef LAVA

// 16 is the original's count. It is a #define and not a literal so the loop
// bound is a compile-time constant and the compiler can unroll; `octaves` is the
// runtime LOD and only ever breaks the loop earlier.
#define LAVA_OCTAVES_MAX 16

// The rotation in the original is mat2(cos(x), -sin(x), sin(x), cos(x)) with
// x = 1. GLSL fills a matrix from its *columns*, so that constructor is
//
//     [ cos  sin ]
//     [-sin  cos ]
//
// which is a rotation by -1 radian, not +1. Written out below so the sign is
// visible rather than buried in a constructor. Getting it backwards is
// invisible in a still frame and obvious in motion.
#define LAVA_COS1 0.5403023059   // cos(1.0)
#define LAVA_SIN1 0.8414709848   // sin(1.0)

// util.glsl's PI, spelled out. all_solid.fsh does not include util.glsl - it
// has its own viewToWorld() and never needed the rest - and this file is
// included from there, so borrowing the name would mean adding an include for
// one constant and picking up whatever else that file brings with it.
#define LAVA_PI 3.14159265358979

// lavaHeatMagnitude - the original's getlava() and its length(), with the
// normalisation described above.
//
// x is in field units, not blocks: the caller divides world XZ by LAVA_TILE.
// octaves is the LOD count and must be >= 1.
float lavaHeatMagnitude(vec2 x, float t, int octaves) {
	vec3 col = vec3(0.0);

	for (int i = 0; i < LAVA_OCTAVES_MAX; i++) {
		if (i >= octaves) break;

		x *= 1.5;
		x.x += t / 64.0;
		// mat2(cos, -sin, sin, cos) * x, expanded per the note on LAVA_COS1.
		x = vec2(
			LAVA_COS1 * x.x + LAVA_SIN1 * x.y,
			-LAVA_SIN1 * x.x + LAVA_COS1 * x.y
		);
		x += (sin(x.x + x.y + x.x * 2.0 - t / 4.0) + cos(x.x * 4.0)) / 16.0;

		float fi = float(i);
		col.r += sin(x.x * 2.0) * cos(x.y + t);
		col.g += cos(x.x + x.y - cos(x.x - x.y + t * fi - x.y + x.x * 4.0));
		// iTime appears twice here, once inside a cos and once outside it. That
		// looks like a slip in the original but it is kept: the expression is
		// cos(A + 2t + cos(B)), and rewriting it as anything else would change
		// the pattern rather than tidy it.
		col.b += cos(x.x + x.y + t + cos(x.x - x.y) + t);
	}

	// length(col) / (2 * sqrt(octaves)) - see the normalisation note above.
	return length(col) / (2.0 * sqrt(float(octaves)));
}

// lavaOctaves - how many of the 16 iterations to run, from the on-screen size
// of a pixel.
//
// The loop multiplies the domain by 1.5 every pass, so the half-period of the
// cosines at pass i is 2*LAVA_PI / 1.5^i field units, which is
// LAVA_TILE * LAVA_PI / 1.5^i blocks. Nyquist wants that to be at least two
// pixels, so
//
//     i <= log( LAVA_TILE * LAVA_PI / (2 * px) ) / log(1.5)
//
// with px the world-space size of a pixel. Clamped to [4, 16]: below 4 the
// pattern has lost its own structure (measured r against the full field is 0.21
// at 4 octaves) and there is no point spending iterations on it.
//
// px must be measured in uniform control flow. See the call site in
// all_solid.fsh for why that is done outside the lava branch rather than here.
int lavaOctaves(float px) {
	float want = log(max(LAVA_TILE * LAVA_PI / max(2.0 * px, 1e-6), 1.001)) / log(1.5);
	return clamp(int(floor(want)) + 1, 4, LAVA_OCTAVES_MAX);
}

// lavaRamp - the heat scale. Stops are (heat, linear rgb).
//
// Lava's colour comes from blackbody radiation, which runs dark red through
// orange to yellow-white, so the ramp is monotonic in all three channels and
// only the *rate* changes: red is high almost immediately, blue only arrives at
// the top. That is what makes the seams read as hotter rather than merely
// brighter, and it is why this is a ramp and not a hue rotation.
//
// The values are linear, not sRGB, because Albedo in this pass is linear - see
// the toLinear() on the read side in composite1.fsh.
vec3 lavaRamp(float heat) {
	vec3 c = vec3(0.020, 0.014, 0.012);   // cold crust, faintly warm grey
	c = mix(c, vec3(0.140, 0.021, 0.004), smoothstep(0.00, 0.30, heat));
	c = mix(c, vec3(0.520, 0.098, 0.008), smoothstep(0.25, 0.55, heat));
	c = mix(c, vec3(0.980, 0.330, 0.030), smoothstep(0.50, 0.75, heat));
	c = mix(c, vec3(1.000, 0.620, 0.150), smoothstep(0.70, 0.90, heat));
	c = mix(c, vec3(1.000, 0.880, 0.560), smoothstep(0.86, 1.00, heat));
	return c;
}

// lavaSurface - the whole thing, for one lava fragment.
//
// worldPos is the world position, upness is the world-space Y of the face
// normal (1 flat, 0 vertical), octaves is from lavaOctaves().
//
// Returns the linear albedo. Emission is not handled here: see LAVA.md for why
// the glow rides on this colour rather than on a separate channel.
vec3 lavaSurface(vec3 worldPos, float upness, int octaves, float t) {
	vec2 p = worldPos.xz / LAVA_TILE;

	// The original's only motion is x.x += t/64 inside the scaled loop, so the
	// drift compounds to t/64 * 1.5^i and the pattern appears to zoom outward.
	// That is the whole animation and it is kept; LAVA_SPEED scales t.
	float h = lavaHeatMagnitude(p, t, octaves);

	// The contour is the crack network. |h - level| is a distance in field
	// units, so the band is thin where the field is steep and wide where it is
	// flat - which is what a crack does: it widens where the crust is thin.
	float level = LAVA_CRUST_LEVEL;
	float seam = 1.0 - smoothstep(0.0, LAVA_CRACK_WIDTH, abs(h - level));

	// Molten area, either side of the same contour. Below the level is crust.
	float heat = smoothstep(level - LAVA_CRACK_WIDTH * 2.0,
	                        level + LAVA_CRACK_WIDTH * 2.0, h);

	vec3 col = lavaRamp(heat);

	// The seam is hotter than the melt around it - it is an open vent, not more
	// of the same thing - so it is taken up the ramp rather than added, which
	// would clip to white and lose the gradient.
	col = mix(col, lavaRamp(min(heat + 0.45, 1.0)), seam * LAVA_SEAM);

	// Crust plates need tonal variation or they read as flat paper. h still
	// varies smoothly across the region below the contour, so h/level is a free
	// variation across each plate - no second evaluation, no texture fetch, and
	// guaranteed to agree with the pattern it sits on rather than being an
	// unrelated noise field laid over the top.
	col *= mix(0.7 + 0.6 * (h / max(level, 1e-4)), 1.0, heat);

	// A side face is not looked down on, so the world-XZ projection is
	// meaningless there and would smear. Fade the pattern out and leave a flat
	// hot surface, which is what the side of a lava fall actually looks like.
	col = mix(vec3(0.55, 0.10, 0.012), col, upness);

	// LAVA_GLOW is a lift on the whole surface, not on the seams alone: a lava
	// pool lights the room, and the crust is what you see of it.
	return col * LAVA_GLOW;
}

#endif // LAVA