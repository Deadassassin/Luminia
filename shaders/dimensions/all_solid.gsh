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

in VARYINGS {
	vec4 color;
	float VanillaAO;
	vec4 lmtexcoord;
	vec4 normalMat;
	vec4 vtexcoordam;
	vec4 vtexcoord;

	#ifdef MC_NORMAL_MAP
		vec4 tangent;
		vec3 FlatNormals;
	#endif

	flat float blockID;
	flat float HELD_ITEM_BRIGHTNESS;
	flat int NameTags;
	flat float SSSAMOUNT;
	flat float EMISSIVE;
	flat int LIGHTNING;
	flat int PORTAL;
	flat int SIGN;
} vs_in[];

out VARYINGS {
	vec4 color;
	float VanillaAO;
	vec4 lmtexcoord;
	vec4 normalMat;
	vec4 vtexcoordam;
	vec4 vtexcoord;

	#ifdef MC_NORMAL_MAP
		vec4 tangent;
		vec3 FlatNormals;
	#endif

	flat float blockID;
	flat float HELD_ITEM_BRIGHTNESS;
	flat int NameTags;
	flat float SSSAMOUNT;
	flat float EMISSIVE;
	flat int LIGHTNING;
	flat int PORTAL;
	flat int SIGN;
} fs_out;

uniform mat4 gbufferModelView;
uniform mat4 gbufferModelViewInverse;
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

	fs_out.color = vs_in[source].color * fade;
	fs_out.VanillaAO = vs_in[source].VanillaAO;
	fs_out.lmtexcoord = vs_in[source].lmtexcoord;

	// The blade has no texture coordinates of its own - it is not a surface
	// that was ever unwrapped - so the parallax coordinates are zeroed rather
	// than inherited. Passing the quad's through would make a blade sample
	// whatever part of the grass texture the quad's corner happened to name.
	fs_out.vtexcoordam = vec4(0.0);
	fs_out.vtexcoord = vec4(0.0);

	#ifdef MC_NORMAL_MAP
		fs_out.tangent = vec4(0.0, 0.0, 1.0, 0.0);
		// The blade's own normal. The fragment stage's parallax path reads the
		// surface normal out of vtexcoordam, so it goes there rather than in
		// FlatNormals, which is the normal of the ground the blade grows from -
		// and lighting a vertical blade as though it were flat ground is what
		// makes grass look like a painted texture.
		fs_out.FlatNormals = normal;
		fs_out.vtexcoordam = vec4(normal, 0.0);
	#endif

	fs_out.blockID = vs_in[0].blockID;
	fs_out.HELD_ITEM_BRIGHTNESS = vs_in[0].HELD_ITEM_BRIGHTNESS;
	fs_out.NameTags = vs_in[0].NameTags;
	fs_out.SSSAMOUNT = vs_in[0].SSSAMOUNT;
	fs_out.EMISSIVE = vs_in[0].EMISSIVE;
	fs_out.LIGHTNING = vs_in[0].LIGHTNING;
	fs_out.PORTAL = vs_in[0].PORTAL;
	fs_out.SIGN = vs_in[0].SIGN;

	EmitVertex();
}

void main() {
	#if defined SHADER_GRASS && defined WORLD && !defined ENTITIES && \
	    !defined HAND && !defined BLOCKENTITIES

		vec3 worldNormal = viewToWorld(vs_in[0].normalMat.xyz);
		float viewDist = gl_in[0].gl_Position.w;

		// blockID 85 is short grass: the cross-shaped quad the game draws for it.
		// The world normal has to point up, which is what separates it from every
		// other quad that happens to be made of the same block.
		bool isGrass = vs_in[0].blockID == BLOCK_GRASS_SHORT &&
		               worldNormal.y > 0.9 &&
		               viewDist < GRASS_RANGE;

		if (isGrass) {
			// The triangle's centre, in view space. The blades stand on it.
			vec3 centre = (gl_in[0].gl_Position.xyz +
			               gl_in[1].gl_Position.xyz +
			               gl_in[2].gl_Position.xyz) / 3.0;
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
			int blades, segments;
			if (viewDist > 16.0) {
				blades = 1; segments = 1;
			} else if (viewDist > 8.0) {
				blades = 2; segments = 2;
			} else if (viewDist > 4.0) {
				blades = 3; segments = 3;
			} else {
				blades = 4; segments = GRASS_MAX_SEGMENTS;
			}

			// Where the blades stand across the quad. Spread over the triangle's
			// own extent rather than at random inside it, so they stay on the grass
			// and do not overhang the block edge.
			vec3 edge = gl_in[1].gl_Position.xyz - gl_in[0].gl_Position.xyz;

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

			for (int b = 0; b < blades; b++) {
				// Spread the blades along the triangle's edge. A blade placed at a
				// fixed fraction per index, rather than randomly, keeps them from
				// clustering into bare patches and bare clumps.
				float along = (float(b) + 0.5) / float(blades);
				vec3 base = centre + edge * (along - 0.5) * 0.8;

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

			// The original quad is not also drawn. A cross-shaped billboard under a
			// set of blades is the thing this option exists to replace, and drawing
			// both is what makes shader grass look like grass pasted onto grass.
			return;
		}
	#endif

	// Not grass: the triangle through unchanged, which is the whole behaviour of
	// the pack for every block that is not short grass. Note that this stage is
	// still in the pipeline when SHADER_GRASS is off - the loader draws it either
	// way - so this path is the one that runs for the entire world most of the
	// time and it has to be a genuine pass-through. It is: the same three
	// positions, the same three varyings, in the same order.
	for (int i = 0; i < 3; i++) {
		gl_Position = gl_in[i].gl_Position;

		fs_out.color = vs_in[i].color;
		fs_out.VanillaAO = vs_in[i].VanillaAO;
		fs_out.lmtexcoord = vs_in[i].lmtexcoord;
		fs_out.normalMat = vs_in[i].normalMat;
		fs_out.vtexcoordam = vs_in[i].vtexcoordam;
		fs_out.vtexcoord = vs_in[i].vtexcoord;

		#ifdef MC_NORMAL_MAP
			fs_out.tangent = vs_in[i].tangent;
			fs_out.FlatNormals = vs_in[i].FlatNormals;
		#endif

		fs_out.blockID = vs_in[0].blockID;
		fs_out.HELD_ITEM_BRIGHTNESS = vs_in[0].HELD_ITEM_BRIGHTNESS;
		fs_out.NameTags = vs_in[0].NameTags;
		fs_out.SSSAMOUNT = vs_in[0].SSSAMOUNT;
		fs_out.EMISSIVE = vs_in[0].EMISSIVE;
		fs_out.LIGHTNING = vs_in[0].LIGHTNING;
		fs_out.PORTAL = vs_in[0].PORTAL;
		fs_out.SIGN = vs_in[0].SIGN;

		EmitVertex();
	}
	EndPrimitive();
}
