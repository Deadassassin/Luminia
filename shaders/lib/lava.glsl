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

// 8, and not the original's 16.
//
// The loop magnifies the domain by 1.5 per pass, so 16 passes is a 657:1
// frequency range. A screen can show that: on Shadertoy the finest octave is
// about a pixel and half across a 1000px image. A lava surface cannot - plates
// are metres apart and cracks are centimetres, which is a range of about 20:1 -
// so at 16 octaves the pattern's structure lands at roughly one millimetre and
// every lava pool renders as an undifferentiated sheet. Measured plate spacing
// (one standard deviation of the field, converted to blocks through the local
// gradient) against octave count, at a 0.04 block pixel:
//
//     octaves        3      5      8     12     16
//     TILE 0.35   0.415  0.308  0.252  0.243  0.240 blocks
//     TILE 1.50   0.078  0.045  0.022  0.015  0.014 blocks
//     TILE 8.00   0.014  0.009  0.003  0.001  0.001 blocks
//
// Past about 8 the extra iterations stop adding structure and start adding
// aliasing: the octaves are finer than the pixel, and the contact sheet in
// tools/lava_render.py --sheet shows rows 10, 12 and 16 turning to speckle while
// rows 5 to 8 stay clean. Eight keeps the source's self-similar structure and
// its motion, over the band a world surface can actually resolve.
//
// It is a #define and not a literal so the loop bound is a compile-time constant
// and the compiler can unroll; `octaves` is the runtime LOD and only ever breaks
// the loop earlier.
#define LAVA_OCTAVES_MAX 8

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
// with px the world-space size of a pixel. Clamped to [3, LAVA_OCTAVES_MAX]: below
// 3 the pattern has lost its own structure (measured r against the full field is
// 0.21 at 4 octaves) and there is no point spending iterations on it.
//
// px must be measured in uniform control flow. See the call site in
// all_solid.fsh for why that is done outside the lava branch rather than here.
int lavaOctaves(float px) {
	float want = log(max(LAVA_TILE * LAVA_PI / max(2.0 * px, 1e-6), 1.001)) / log(1.5);
	return clamp(int(floor(want)) + 1, 3, LAVA_OCTAVES_MAX);
}

// lavaWrap - keep the field's argument small.
//
// The loop multiplies the domain by 1.5 sixteen times, so a coordinate 10000
// blocks from the origin arrives at the cosines as ~6.6e6, where one float32 ulp
// is about 0.5. sin() of that argument has lost most of its low bits and the
// pattern quantises into blocks - fine at spawn, garbage at 10k.
//
// Wrapping the input at 8192 fixes it: every evaluation stays near zero. The
// wrap is not a period of the field, so there is a real discontinuity at each
// multiple of 8192 blocks, but the two sides of one are 16 km apart and you
// cannot see both from inside a 512 block draw distance. This is the same
// origin-wrapping that lib/waterBump.glsl's callers rely on for the same
// reason.
#define LAVA_WRAP 8192.0

vec2 lavaWrap(vec2 p) {
	return mod(p, LAVA_WRAP) - LAVA_WRAP * 0.5;
}

// lavaRamp - the heat scale. Stops are (heat, linear rgb).
//
// Lava's colour is blackbody radiation, so the ramp is monotonic in red and the
// other two channels arrive late and unequally: green climbs, blue barely
// moves. That is why this is a ramp and not a hue rotation - a hue rotation
// would swing through yellow and green on the way up, which is not a thing
// molten rock does.
//
// **Blue is capped low on purpose.** The first version of this ramp topped out at
// (1.0, 0.88, 0.56) - yellow-white - and the result read as poured gold rather
// than as lava, because high green *and* high blue is what gold is. Real lava
// only goes yellow-white in the white-hot centre of an active vent, and even
// then it is a small part of the surface. Blue now reaches 0.17 at the very top
// and green 0.62, which keeps the hue red-orange across the whole range.
//
// The values are linear, not sRGB, because Albedo in this pass is linear - see
// the toLinear() on the read side in composite1.fsh.
vec3 lavaRamp(float heat) {
	vec3 c = vec3(0.012, 0.010, 0.009);   // cold crust, near black
	c = mix(c, vec3(0.090, 0.014, 0.003), smoothstep(0.00, 0.42, heat));
	c = mix(c, vec3(0.420, 0.070, 0.006), smoothstep(0.38, 0.62, heat));
	c = mix(c, vec3(0.850, 0.190, 0.016), smoothstep(0.58, 0.80, heat));
	c = mix(c, vec3(1.000, 0.380, 0.045), smoothstep(0.76, 0.93, heat));
	c = mix(c, vec3(1.000, 0.620, 0.170), smoothstep(0.90, 1.00, heat));
	return c;
}

// lavaWallProjection - field coordinates for a vertical face.
//
// The field is a function of world XZ, which on a wall is very nearly a single
// point per column, so projecting the world-XZ field onto a side face smears
// every feature into a vertical streak. A wall needs its own 2D basis: one axis
// running along the wall, and one running down it.
//
// along comes from the face normal, so it is correct for any wall orientation
// rather than only the axis-aligned ones. The vertical axis is compressed by
// LAVA_WALL_STRETCH so features come out taller than they are wide, which is
// what makes a crack down a wall read as a drip instead of as a bead.
#define LAVA_WALL_STRETCH 0.5

vec2 lavaWallProjection(vec3 worldPos, vec3 worldNormal) {
	vec2 n = worldNormal.xz;
	float len = length(n);

	// A degenerate horizontal normal is a floor or ceiling face, where this is
	// never reached. Guarded anyway so the divide cannot produce a NaN that
	// would then be sampled as a coordinate.
	vec2 along = (len > 1e-4) ? vec2(-n.y, n.x) / len : vec2(1.0, 0.0);

	return lavaWrap(vec2(dot(worldPos.xz, along), worldPos.y * LAVA_WALL_STRETCH)) / LAVA_TILE;
}

// lavaBlocksPerFieldUnit - how many world blocks one field unit spans, in
// whichever projection is in use.
//
// Named for the direction of the conversion on purpose. `grad` below comes out
// of a finite difference in field coordinates, so it is in *h units per field
// unit*, and turning a field-unit distance into a block distance means
// multiplying by this - not by its reciprocal. The first version of this file
// had the reciprocal, named `lavaFieldUnitsPerBlock`, which is a name that reads
// correctly and inverts the arithmetic: the whole melt gradient came out 64x
// too narrow and lavaSurface() returned a flat constant for every pixel.
//
// On a top face the answer is LAVA_TILE on both axes. On a wall the axis along
// the wall is LAVA_TILE but the vertical axis is stretched by
// LAVA_WALL_STRETCH, so it is LAVA_TILE/0.5; this returns the geometric mean of
// the two for a wall, which is the right compromise for a single scalar. The
// crack width is an artistic control, not something being simulated - being 30%
// off on one axis of a wall is invisible, where being 64x off is the whole
// surface.
float lavaBlocksPerFieldUnit(float upness) {
	return mix(LAVA_TILE * sqrt(LAVA_WALL_STRETCH), LAVA_TILE, upness);
}

// lavaCoarse - a second, much lower frequency evaluation of the same field,
// used to vary how molten a region is.
//
// Without it the field's own structure is the only scale on show, and a lava
// pool is a uniform speckle at every distance: close up the veins are right but
// there are no big dark plates, and from across a cavern there is nothing but
// mottle. Real lava has both scales at once - metre-wide plates with hairline
// channels between them - and one octave band cannot supply both.
//
// Two iterations on a quarter-scale domain, so it costs a quarter of one full
// evaluation. 2 octaves rather than 1 because a single octave's magnitude is
// nearly smooth; 2 is the point where it still looks like a field.
//
// The mean and standard deviation below are measured, not assumed, and they are
// not 0.5 and 1.0. length() of a short sum is biased low - at 2 octaves the
// field averages 0.4441, not 0.5 - so centring on the wrong number would bias
// every pool toward one end of the crust range.
#define LAVA_COARSE_OCTAVES 2
#define LAVA_COARSE_MEAN 0.4441
#define LAVA_COARSE_STD 0.2019

// lavaSurface - the whole thing, for one lava fragment.
//
// worldPos is the world position, worldNormal is the world-space face normal,
// px is fwidth(worldPos.xz) - the world-space size of this pixel - and octaves
// is from lavaOctaves().
//
// Returns the linear albedo. Emission is not handled here: see LAVA.md for why
// the glow rides on this colour rather than on a separate channel.
vec3 lavaSurface(vec3 worldPos, vec3 worldNormal, vec2 px, int octaves, float t) {
	// How much this face is looked down on. The band is wide and starts low
	// because flowing lava's surface is *tilted* along the flow vector - a
	// level-2 face is nowhere near vertical but it is also nowhere near flat,
	// and a narrow band here would put half of every flowing pool on the wall
	// projection and give it visible seams where the two meet.
	float upness = smoothstep(0.15, 0.55, worldNormal.y);

	vec2 flatP = lavaWrap(worldPos.xz) / LAVA_TILE;
	vec2 wallP = lavaWallProjection(worldPos, worldNormal);
	vec2 p = mix(wallP, flatP, upness);

	// The original's only motion is x.x += t/64 inside the scaled loop, so the
	// drift compounds to t/64 * 1.5^i and the pattern appears to zoom outward.
	// That is the whole animation and it is kept; LAVA_SPEED scales t.
	float h = lavaHeatMagnitude(p, t, octaves);

	// ---------------------------------------------------------------------
	// THE CRACK WIDTH IS IN BLOCKS, AND THAT IS THE WHOLE FIX
	// ---------------------------------------------------------------------
	//
	// The first version thresholded the contour in *field value* units:
	//
	//     seam = 1 - smoothstep(0, 0.03, abs(h - level))
	//
	// which looks like a width and is not one. The field's gradient is steep
	// enough that a band half 0.03 units wide is a small fraction of a
	// thousandth of a block. The whole melt gradient fitted inside a thousandth
	// of a block, which is a hard binary edge, and the renderer confirmed it:
	// 12.9% of the surface at heat exactly 1.0 and only 9.2% anywhere in
	// between. Every molten pixel came out the same colour, which is a flat
	// sheet of the top of the ramp - and a flat sheet of yellow-white is what
	// "poured gold" turned out to mean.
	//
	// So the threshold is divided by the local gradient, which turns a distance
	// in field value into a distance in blocks, and LAVA_CRACK_WIDTH becomes
	// what it always read as: a width in blocks.
	//
	// The gradient is two more evaluations of the field, differenced over one
	// pixel. Differencing over px rather than over an arbitrary epsilon is
	// deliberate: it is the only step that is meaningful at this point, and it
	// degrades the right way - at distance the step grows, the estimate turns
	// into a low-pass, and distant cracks go soft and wide, which is what
	// distance does to a crack.
	//
	// step is in field units, so grad comes out in h units per field unit.
	float step = max(length(px) / lavaBlocksPerFieldUnit(upness), 1e-5);
	float hx = lavaHeatMagnitude(p + vec2(step, 0.0), t, octaves);
	float hz = lavaHeatMagnitude(p + vec2(0.0, step), t, octaves);
	float grad = max(length(vec2(hx - h, hz - h)) / step, 1e-5);

	// The contour, offset by the coarse field so that whole regions of a pool
	// run crusty and whole regions run molten.
	float coarse = (lavaHeatMagnitude(p * 0.25, t * 0.6, LAVA_COARSE_OCTAVES)
	                - LAVA_COARSE_MEAN) / LAVA_COARSE_STD;
	float level = LAVA_CRUST_LEVEL + coarse * LAVA_VARIATION;

	// Signed distance to the contour, in blocks. Positive is the molten side.
	// (h - level) / grad is a distance in field units, hence the multiply.
	float dist = (h - level) / grad * lavaBlocksPerFieldUnit(upness);

	// The contour is the crack network: a thin bright line on the level set, and
	// melt on the far side of it.
	float seam = 1.0 - smoothstep(0.0, LAVA_CRACK_WIDTH, abs(dist));
	float heat = smoothstep(-LAVA_CRACK_WIDTH * 2.0, LAVA_CRACK_WIDTH * 2.0, dist);

	vec3 col = lavaRamp(heat);

	// The seam is hotter than the melt around it - it is an open vent, not more
	// of the same thing - so it is taken up the ramp rather than added, which
	// would clip to white and lose the gradient. The push is 0.32 and not more
	// because every unit of it lands nearer the top of the ramp, which is the
	// part of the ramp that decides whether this reads as lava or as gold.
	col = mix(col, lavaRamp(min(heat + 0.32, 1.0)), seam * LAVA_SEAM);

	// Crust plates need tonal variation or they read as flat paper. h still
	// varies smoothly across the region below the contour, so h/level is a free
	// variation across each plate - no extra evaluation, no texture fetch, and
	// guaranteed to agree with the pattern it sits on rather than being an
	// unrelated noise field laid over the top.
	col *= mix(0.75 + 0.5 * (h / max(level, 1e-4)), 1.0, heat);

	// A vertical face of molten rock does not crust the way a horizontal one
	// does - it is still flowing off the wall - so walls run hotter and carry
	// less crust. This replaces what used to be a flat colour on any non-up
	// facing face, which was the wrong fix: it removed the detail instead of
	// reprojecting it, and left the sides of every pool as flat orange.
	col = mix(col, lavaRamp(min(heat + 0.28, 1.0)), (1.0 - upness) * 0.6);

	// LAVA_GLOW is a lift on the whole surface, not on the seams alone: a lava
	// pool lights the room, and the crust is what you see of it.
	return col * LAVA_GLOW;
}

#endif // LAVA