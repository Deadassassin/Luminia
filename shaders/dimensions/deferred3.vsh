#include "/lib/settings.glsl"
#include "/lib/res_params.glsl"
#include "/lib/util.glsl"

// ---------------------------------------------------------------------------
// The path trace pass's vertex stage.
//
// It carries three flat varyings and nothing else: the sun's direction in world
// space, the sun's colour, and the frame's average sky colour. All three are
// per-frame constants, so passing them as flat is both correct and cheaper than
// making the fragment stage reach for the same uniforms again.
//
// The average sky and the sun colour are read out of colortex4 at the texels
// composite1.fsh and deferred2.fsh already use for exactly this pair. Reading
// them from the same place is what keeps a reflection's sky the same colour as
// the sky above it - a reflection lit by a differently tinted sky is the single
// most obvious way for a path tracer to look wrong.

flat varying vec3 ptSunVec;
flat varying vec3 ptSunColor;
flat varying vec3 ptSkyAvg;

uniform mat4 gbufferModelViewInverse;
uniform vec3 sunPosition;
uniform sampler2D colortex4;

void main() {

	gl_Position = ftransform();

	// Taken to world space rather than read as a world-space component: the sun
	// is only "up" if the camera is not rolled.
	ptSunVec = normalize(mat3(gbufferModelViewInverse) * sunPosition);

	ptSkyAvg = texelFetch2D(colortex4, ivec2(1, 37), 0).rgb;
	ptSunColor = texelFetch2D(colortex4, ivec2(6, 37), 0).rgb;

}
