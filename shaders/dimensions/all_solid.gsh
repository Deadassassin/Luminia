// Geometry stage for the solid programs.
//
// This is the shader grass. Short grass stops being a cross-shaped billboard
// and becomes blades: each grass quad is replaced by a handful of real,
// vertical, curving strips that lean at random and move with the same wave the
// rest of the foliage uses.
//
// Why there is no tessellation stage. The obvious way to get many blades out of
// one quad is to tessellate it first and make a blade per sub-triangle - that
// is how this is done elsewhere, and it was how this was written first. It
// introduced visible speckling in the distance that survived with the grass
// code compiled out entirely, so the fault was in having a tessellation stage
// in the chain at all rather than in the blade building. Subdividing the quad
// here instead costs one extra loop and no extra pipeline stage, and a stage
// that cannot be there is a stage that cannot misbehave.
//
// The cost is blade count: a quad is two triangles, and each becomes a small
// number of blades rather than dozens. GRASS_DENSITY trades that against frame
// rate. The blade count is also what makes this expensive at all - the geometry
// is built for every quad inside GRASS_RANGE, and most of it is behind you.
//
// The varying list below is the vertex stage's and has to match it exactly. A
// geometry stage is a link-time step between the vertex and fragment stages: a
// name that is missing, or a type that differs, is refused when the pipeline is
// built, and the message names the pack rather than the program.

layout(triangles) in;

// A strip of `2 * (segments + 1)` vertices, and the largest GRASS_DENSITY can
// ask for. The constant has to cover the worst case at compile time, so it is
// the maximum rather than whatever the current setting is - and a stage that
// emitted more vertices than it declared is undefined, not merely wrong.
//
// Each blade is its own primitive, so the budget is per-primitive, not for the
// whole draw. The number that matters is the largest single blade, which is one
// strip of 2 * (GRASS_MAX_SEGMENTS + 1) vertices.
#if GRASS_DENSITY == 3
	#define GRASS_MAX_SEGMENTS 6
#elif GRASS_DENSITY == 2
	#define GRASS_MAX_SEGMENTS 4
#elif GRASS_DENSITY == 1
	#define GRASS_MAX_SEGMENTS 3
#else
	#define GRASS_MAX_SEGMENTS 2
#endif

layout(triangle_strip, max_vertices = 2 * (GRASS_MAX_SEGMENTS + 1)) out;

#include "/lib/settings.glsl"
// BLOCK_GRASS_SHORT, and the rest of the block id table. settings.glsl does not
// include it - each stage that needs it includes it itself, which is why the
// vertex stage does too.
#include "/lib/blocks.glsl"

// The varyings, declared one by one and not as an interface block.
//
// This is the whole reason the distant artifacting happened, and it is worth
// writing down. The vertex stage declares its outputs as loose `varying`
// declarations, which the loader hoists into individual `out` declarations. An
// interface block is a different kind of thing: a block that carries an array
// name is matched to the other stage as a whole, member by member, and it does
// not match a set of individually-declared outputs. So the block declared here
// was fed nothing, and what reached the fragment stage was whatever the loader
// left in those locations.
//
// The symptom was in the distance rather than everywhere, and that is what made
// it hard to place: a wrong lightmap or normal is least visible on a surface
// close to the camera, where the same value would be reached by interpolation
// anyway, and most visible on a distant hillside where every pixel is being
// interpolated from far away.
//
// The rule, and it has two halves, and getting either wrong is silent.
//
// A geometry stage's INPUTS must carry the vertex stage's names exactly. A
// loose varying is matched to the stage on the other side of it by name, so an
// input called `in_color` is fed nothing at all when the vertex stage writes
// `color`. The array brackets are the only difference from the vertex stage's
// own declaration.
//
// Its OUTPUTS cannot carry those same names, because a name cannot be both an
// input array and an output scalar in one scope - that is a redefinition, and
// the compiler will say so. So the outputs are suffixed `_g` and the FRAGMENT
// stage declares the same suffixed names. All three stages agreeing on a name
// is the whole contract; the fragment stage's `color` becomes
// `gbuffers_terrain.g_color` and nothing else in the pack is affected.
in vec4 color[];
in float VanillaAO[];
in vec4 lmtexcoord[];
in vec4 normalMat[];
in vec4 vtexcoordam[];
in vec4 vtexcoord[];

#ifdef MC_NORMAL_MAP
	in vec4 tangent[];
	in vec3 FlatNormals[];
#endif

flat in float blockID[];
flat in float HELD_ITEM_BRIGHTNESS[];
flat in int NameTags[];
flat in float SSSAMOUNT[];
flat in float EMISSIVE[];
flat in int LIGHTNING[];
flat in int PORTAL[];
flat in int SIGN[];

out vec4 color_g;
out float VanillaAO_g;
out vec4 lmtexcoord_g;
out vec4 normalMat_g;
out vec4 vtexcoordam_g;
out vec4 vtexcoord_g;

#ifdef MC_NORMAL_MAP
	out vec4 tangent_g;
	out vec3 FlatNormals_g;
#endif

flat out float blockID_g;
flat out float HELD_ITEM_BRIGHTNESS_g;
flat out int NameTags_g;
flat out float SSSAMOUNT_g;
flat out float EMISSIVE_g;
flat out int LIGHTNING_g;
flat out int PORTAL_g;
flat out int SIGN_g;

uniform mat4 gbufferModelView;
uniform mat4 gbufferModelViewInverse;
// gl_ProjectionMatrix is not declared here: the loader supplies it, exactly as
// it does to the vertex stage that calls toClipSpace3. viewPosFromClip needs it
// and receives it the same way.
uniform vec3 cameraPosition;
uniform vec3 relativeEyePosition;
uniform float frameTimeCounter;
uniform sampler2D noisetex;

// Mirrors the vertex stage. toClipSpace3 in particular has to be the same
// function rather than an equivalent one: it is the pack's own projection
// (w = -viewZ), so using gl_Position directly would put every blade on a
// different depth scale from the quad it replaces, and the lighting pass reads
// depth to decide what is in front of what.
#define diagonal3(m) vec3((m)[0].x, (m)[1].y, m[2].z)
#define projMAD(m, v) (diagonal3(m) * (v) + (m)[3].xyz)

vec4 toClipSpace3(vec3 viewSpacePosition) {
	return vec4(projMAD(gl_ProjectionMatrix, viewSpacePosition),
	            -viewSpacePosition.z);
}

// The inverse of toClipSpace3, and the reason this function has to exist.
//
// gl_Position is CLIP space - the position already pushed through the
// projection - and a geometry stage is handed nothing but gl_Position and the
// varyings. The blades are built in view space, because that is what the wave
// function and the height offsets are defined in, so the vertex positions have
// to come back out of the projection before anything is built from them.
//
// This was the bug that made the grass invisible. The blade positions were
// computed from gl_Position.xyz as though it were a view-space position, which
// it is not: it is a projected coordinate. Every blade was placed at a nonsense
// point - usually behind the camera or far off to one side - and the stray
// geometry that produced also punched through the faces it was drawn over,
// which is what "seeing through grass" was.
//
// toClipSpace3 is invertible because it is affine in the position:
//   clip.xyz = diagonal3(P) * viewPos + P[3].xyz
//   clip.w   = -viewPos.z
// so viewPos = (clip.xyz - P[3].xyz) / diagonal3(P), and z is handed over
// directly by w. The divide is by the projection's own diagonal rather than by
// w, which is the unusual part of this pack's projection and the reason the
// usual xyz/w does not recover a position here.
vec3 viewPosFromClip(vec4 clipPos) {
	return (clipPos.xyz - gl_ProjectionMatrix[3].xyz) / diagonal3(gl_ProjectionMatrix);
}

const float PI48 = 150.796447372 * WAVY_SPEED;
float pi2wt = PI48 * frameTimeCounter;

// The same wave the rest of the foliage uses, deliberately: calcMovePlants in
// all_solid.vsh, same constants and same inputs. A blade that waved differently
// from the grass around it would read as a separate object sitting on the
// ground rather than part of it.
vec2 calcWave(in vec3 pos) {
	float magnitude = abs(sin(dot(vec4(frameTimeCounter, pos),
	                              vec4(1.0, 0.005, 0.005, 0.005))) * 0.5 + 0.72) * 0.013;
	return (sin(pi2wt * vec2(0.0063, 0.0015) * 4.0 - pos.xz + pos.y * 0.05) + 0.1)
	       * magnitude;
}

vec3 calcMovePlants(in vec3 pos) {
	vec2 move = calcWave(pos);
	return vec3(move.x, -length(move), move.y) * 5.0 * WAVY_STRENGTH;
}

vec3 viewToWorld(vec3 viewPosition) {
	vec4 pos;
	pos.xyz = viewPosition;
	pos.w = 0.0;
	return (gbufferModelViewInverse * pos).xyz;
}

// The per-vertex varyings, plus the ones that describe the whole triangle.
//
// The block id and the rest of the flat set are read from the provoking vertex
// rather than from whichever vertex a given blade vertex came from: they
// describe the triangle, and a blade is built out of vertices that did not
// exist as vertices of the input at all.
void emitVertex(vec3 viewPos, vec3 normal, float heightFrac, int source) {
	gl_Position = toClipSpace3(viewPos);

	// The colour fades toward the root. Without it a blade is a hard-edged
	// shape pasted onto the ground with a visible bottom edge; with it the
	// blade emerges from the grass rather than sitting on top of it.
	float fade = smoothstep(-0.35, 1.0, heightFrac);

	color_g = color[source] * fade;
	VanillaAO_g = VanillaAO[source];
	lmtexcoord_g = lmtexcoord[source];

	// The blade has no texture coordinates of its own - it is not a surface
	// that was ever unwrapped - so the parallax coordinates are zeroed rather
	// than inherited. Passing the quad's through would make a blade sample
	// whatever part of the grass texture the quad's corner happened to name.
	vtexcoordam_g = vec4(0.0);
	vtexcoord_g = vec4(0.0);

	#ifdef MC_NORMAL_MAP
		tangent_g = vec4(0.0, 0.0, 1.0, 0.0);
		// The blade's own normal. The fragment stage's parallax path reads the
		// surface normal out of vtexcoordam, so it goes there rather than in
		// FlatNormals, which is the normal of the ground the blade grows from -
		// and lighting a vertical blade as though it were flat ground is what
		// makes grass look like a painted texture.
		FlatNormals_g = normal;
		vtexcoordam_g = vec4(normal, 0.0);
	#endif

	blockID_g = blockID[0];
	HELD_ITEM_BRIGHTNESS_g = HELD_ITEM_BRIGHTNESS[0];
	NameTags_g = NameTags[0];
	SSSAMOUNT_g = SSSAMOUNT[0];
	EMISSIVE_g = EMISSIVE[0];
	LIGHTNING_g = LIGHTNING[0];
	PORTAL_g = PORTAL[0];
	SIGN_g = SIGN[0];

	EmitVertex();
}

void main() {
	#if defined SHADER_GRASS && defined WORLD && !defined ENTITIES && \
	    !defined HAND && !defined BLOCKENTITIES

		vec3 worldNormal = viewToWorld(normalMat[0].xyz);
		// Distance is taken from the view-space position, not from gl_Position.w.
		// This pack's projection puts -viewZ in w rather than the usual
		// perspective w, so the two agree here - but reading it from the position
		// the rest of this stage works in keeps it in one set of units.
		float viewDist = length(viewPosFromClip(gl_in[0].gl_Position));

		// Which blocks get blades, and which of their faces.
		//
		// The two ids are the opposite of what they look like, and
		// shaders/block.properties is what settles it:
		//
		//   block.12 = minecraft:short_grass minecraft:grass
		//   block.85 = minecraft:grass_block:snowy=false
		//
		// so BLOCK_GRASS_SHORT (12) is the cross-shaped billboard and BLOCK_GRASS
		// (85) is the full grass block. Reading them the other way round grows
		// blades out of the side of every grass block and leaves the little tufts
		// of short grass as flat billboards - which is the exact opposite of what
		// the option is for.
		//
		// Both are replaced, but the two are handled differently:
		//
		//   - The grass BLOCK's top face is a full 1x1 quad, and it is replaced
		//     outright. Its sides and bottom are left alone: a blade is drawn from
		//     a triangle standing on the ground, and the side of a grass block
		//     is not that.
		//   - SHORT grass is a small cross, and it is replaced outright too. There
		//     is nothing else to keep - it is a cross of two quads, and both go.
		//
		// REPLACE_SHORT_GRASS is what chooses between that and the conservative
		// version, which keeps the billboards and puts the blades behind them.
		bool isGrassBlock = blockID[0] == BLOCK_GRASS && worldNormal.y > 0.9;
		bool isShortGrass = blockID[0] == BLOCK_GRASS_SHORT && worldNormal.y > 0.9;

		// The triangle's three vertices, back in view space.
		//
		// gl_Position is clip space - the position already pushed through the
		// projection - and everything below is built in view space, because that is
		// what the wave function and the height offsets are defined in. So the
		// positions come out of the projection before anything is computed from
		// them. Using gl_Position.xyz as though it were a view-space position puts
		// every blade at a nonsense point, usually off screen or behind the camera.
		vec3 v0 = viewPosFromClip(gl_in[0].gl_Position);
		vec3 v1 = viewPosFromClip(gl_in[1].gl_Position);
		vec3 v2 = viewPosFromClip(gl_in[2].gl_Position);

		// A short-grass cross is two intersecting quads, so one of them always
		// faces away from the camera. Growing blades from both doubles the density
		// at some angles and leaves a gap at others, and - worse - the two sets
		// interpenetrate, because the same tuft is built twice from two quads that
		// cross at the middle.
		//
		// So one of the pair is dropped, chosen by which way the triangle faces.
		// gl_FrontFacing would be the obvious test and is not available: it is a
		// fragment-stage input, and this is a geometry stage. The geometric facing
		// is computed instead, from the triangle's own normal and the view ray.
		if (isShortGrass) {
			vec3 triNormal = normalize(cross(v1 - v0, v2 - v0));
			// View space has the camera at the origin looking down -z, so the
			// vector from the camera to the triangle is its own centroid, and the
			// dot is positive when the triangle faces the camera.
			if (dot(triNormal, (v0 + v1 + v2) / 3.0) < 0.0) isShortGrass = false;
		}

		bool isGrass = (isGrassBlock || isShortGrass) && viewDist < GRASS_RANGE;

		if (isGrass) {
			// The triangle's centre, in view space. The blades stand on it.
			vec3 centre = (v0 + v1 + v2) / 3.0;
			vec3 worldCentre = viewToWorld(centre);

			// World up, in view space - the direction a blade climbs. Derived
			// through the view matrix rather than assumed to be (0,1,0): in view
			// space up moves as the camera pitches, so a hardcoded view-space up
			// makes the grass lean over as you look up or down.
			vec3 worldUp = normalize(mat3(gbufferModelView) * vec3(0.0, 1.0, 0.0));

			// A per-blade random lean, from the same noise texture the rest of the
			// pack samples. Without it every blade in view is parallel and a field
			// reads as a hedge.
			vec2 noiseUv = worldCentre.xz + cameraPosition.xz;
			vec2 randomDir = 2.0 * (texture(noisetex, 0.75 * noiseUv).xy +
			                        texture(noisetex, 0.35 * noiseUv.yx).xy) - 1.0;

			// How many blades this triangle becomes, and how many segments each
			// has. Fewer of both further out, where a blade is a couple of pixels
			// and cannot show a curve - the segments are the entire cost.
			//
			// The grass block's top face is a whole block across and the short grass
			// cross is a fraction of one, so the same count on both leaves a field
			// of stubble next to a wall of blades. The block's face is scaled up to
			// match, and the multiplier is what makes the two read as the same
			// material at the same distance.
			int blades, segments;
			if (viewDist > 16.0) {
				blades = isGrassBlock ? 4 : 1;
				segments = 1;
			} else if (viewDist > 8.0) {
				blades = isGrassBlock ? 8 : 2;
				segments = 2;
			} else if (viewDist > 4.0) {
				blades = isGrassBlock ? 12 : 3;
				segments = 3;
			} else {
				blades = isGrassBlock ? 16 : 4;
				segments = GRASS_MAX_SEGMENTS;
			}

			// The two edges of the triangle, so blades can be spread across its whole
			// area rather than along a line.
			//
			// Spreading matters more than it looks: a grass block's top face is two
			// triangles, and putting all sixteen blades along one edge of each puts
			// every blade in a line down the middle of the block and leaves the
			// corners bare. Barycentric placement over the triangle is what turns
			// the count into coverage.
			vec3 edgeA = v1 - v0;
			vec3 edgeB = v2 - v0;

			// Blade length. Two independent randoms, so a field has blades that
			// lean left and blades that lean right rather than one direction for
			// everything.
			float len = fract(dot(noiseUv, vec2(12.9898, 78.233)));
			float height = 0.05 * (0.6 + 0.8 * len) * BASE_GRASS_HEIGHT * SHORT_GRASS_HEIGHT;

			// Push away from the player where they are standing in it. Smoothed on
			// both axes rather than a sphere, so it flattens underfoot instead of
			// leaving a bowl.
			vec3 offsetPos = centre + worldUp + relativeEyePosition;
			float playerDist = smoothstep(0.5, 0.05, length(offsetPos.xz)) *
			                   smoothstep(1.0, 0.2, abs(offsetPos.y));
			vec2 pushDir = normalize(worldCentre.xz +
			                         relativeEyePosition.xz + vec2(1e-5, 0.0));

			float thickness = GRASS_BASE_THICKNESS * 0.125;

			// Blade placement. A golden-ratio walk over the triangle's barycentric
			// coordinates, rather than a grid: a grid puts the blades in visible
			// rows, and a purely random placement clumps and leaves gaps. The
			// sequence is the same one used elsewhere in the pack for the same job.
			//
			// The offsets are nudged inwards so a blade at the edge of a block face
			// sits on the block rather than half off it.
			for (int b = 0; b < blades; b++) {
				// Two independent strides over the triangle, decorrelated by the
				// golden ratio. A single stride walks the blades along a line; a
				// grid puts them in visible rows. This is the standard low-discrepancy
				// answer and it needs no state.
				float t = (float(b) + 0.5) / float(blades);
				float u = fract(t);
				float v = fract(t * 0.6180339887 + 0.5);

				// Pull away from the triangle's edges, so no blade stands on a seam
				// between the two triangles of a quad or on the block boundary.
				u = 0.15 + u * 0.7;
				v = 0.15 + v * 0.7;
				// The third barycentric coordinate. Renormalised afterwards so the
				// blade still lands inside the triangle once the inset has pushed
				// u + v past one - without that, a blade on the far side of the
				// inset lands outside the triangle and floats off the block.
				float w = max(1.0 - u - v, 0.0);
				float sum = max(u + v + w, 1e-4);
				u /= sum; v /= sum;

				vec3 base = v0 + edgeA * u + edgeB * v;

				// Each blade leans its own way.
				float jitter = fract(len * 7.0 + float(b) * 0.618);
				vec2 lean = (randomDir + vec2(jitter - 0.5, fract(jitter * 3.1) - 0.5)) *
				            GRASS_RANDOMNESS * 0.4;

				// The blade's width runs across the direction it faces, so it is a
				// flat ribbon rather than a tube, and is lit as a surface.
				vec3 viewDir = normalize(base);
				vec3 right = normalize(cross(worldUp, viewDir));

				// The wave, weighted by the square of the height so the base does
				// not move. Same function as the vertex stage's, so the blade and
				// the grass around it move together.
				//
				// GRASS_WAVY_STRENGTH scales it on top of WAVY_STRENGTH rather than
				// replacing it. calcMovePlants already multiplies by WAVY_STRENGTH, so
				// the two compose and the blades follow the same slider the rest of
				// the foliage does.
				vec3 wave = calcMovePlants(worldCentre + cameraPosition) *
				            GRASS_WAVY_STRENGTH * 0.0625;
				vec3 push = vec3(pushDir.x, 0.0, pushDir.y) *
				            playerDist * 0.7 * 0.0625;

				for (int s = 0; s < segments; s++) {
					float t0 = float(s) / float(segments);
					float t1 = float(s + 1) / float(segments);

					// The lean accumulates along the blade, so the tip ends up
					// furthest over. This is the whole reason it curves; parallel
					// segments would make a plank.
					float bend0 = t0 * t0;
					float bend1 = t1 * t1;

					vec3 basePos = base + worldUp * (height * t0) +
					               right * lean.x * bend0 * 0.05;
					vec3 tipPos = base + worldUp * (height * t1) +
					              right * lean.x * bend1 * 0.05;

					// The blade tapers: full width at the base, GRASS_THICKNESS_FALLOFF
					// of it at the tip. A blade of constant width is a rectangle.
					float w0 = thickness * mix(1.0, GRASS_THICKNESS_FALLOFF, t0);
					float w1 = thickness * mix(1.0, GRASS_THICKNESS_FALLOFF, t1);

					// The wave and the push, applied in proportion to height so the
					// base stays planted.
					vec3 o0 = wave * bend0 + push * bend0;
					vec3 o1 = wave * bend1 + push * bend1;

					vec3 left0  = basePos - right * w0 + o0;
					vec3 right0 = basePos + right * w0 + o0;
					vec3 left1  = tipPos  - right * w1 + o1;
					vec3 right1 = tipPos  + right * w1 + o1;

					vec3 n = normalize(cross(right0 - left0, left1 - left0));

					// A strip: down the left side, then up the right.
					emitVertex(left0, n, t0, 0);
					emitVertex(right0, n, t0, 0);
					emitVertex(left1, n, t1, 0);
					emitVertex(right1, n, t1, 0);
				}

				EndPrimitive();
			}

			// Short grass: the original quad is dropped. A cross-shaped billboard
			// under a set of blades is the thing this option exists to replace, and
			// drawing both is what makes shader grass look like grass pasted onto
			// grass.
			//
			// A grass BLOCK is different, and this is the difference: its top face
			// is a solid surface, not a billboard. Dropping it does not reveal the
			// billboards behind, it reveals the inside of the block - you look
			// straight through the top of a grass block and see the dirt below. So
			// for a grass block the face is drawn and the blades are added on top
			// of it, and only the short-grass billboard is actually replaced.
			if (isShortGrass && !isGrassBlock) return;
		}
	#endif

	// The original triangle, drawn as well as (for a grass block) the blades
	// above. This is the path for everything that is not replaced geometry, and
	// for a grass block's top face.
	//
	// Note that this stage is in the pipeline whether or not SHADER_GRASS is on -
	// the loader draws it either way - so this is the path that runs for the
	// entire world most of the time and it has to be a genuine pass-through. It
	// is: the same three positions, the same varyings, in the same order.
	//
	// The blades were emitted above and closed with their own EndPrimitive, so
	// this triangle is a separate primitive and not a continuation of the strip.
	// That matters: without it the face would be stitched onto the end of a
	// blade's strip and the strip's vertex count would be over the limit.
	for (int i = 0; i < 3; i++) {
		gl_Position = gl_in[i].gl_Position;

		color_g = color[i];
		VanillaAO_g = VanillaAO[i];
		lmtexcoord_g = lmtexcoord[i];
		normalMat_g = normalMat[i];
		vtexcoordam_g = vtexcoordam[i];
		vtexcoord_g = vtexcoord[i];

		#ifdef MC_NORMAL_MAP
			tangent_g = tangent[i];
			FlatNormals_g = FlatNormals[i];
		#endif

		blockID_g = blockID[0];
		HELD_ITEM_BRIGHTNESS_g = HELD_ITEM_BRIGHTNESS[0];
		NameTags_g = NameTags[0];
		SSSAMOUNT_g = SSSAMOUNT[0];
		EMISSIVE_g = EMISSIVE[0];
		LIGHTNING_g = LIGHTNING[0];
		PORTAL_g = PORTAL[0];
		SIGN_g = SIGN[0];

		EmitVertex();
	}
	EndPrimitive();
}
