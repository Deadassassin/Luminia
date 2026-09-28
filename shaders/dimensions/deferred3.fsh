#include "/lib/settings.glsl"
#include "/lib/res_params.glsl"
#include "/lib/util.glsl"

// ---------------------------------------------------------------------------
// Penumbra - screen-space path trace
// ---------------------------------------------------------------------------
// One pass, two targets.
//
//   colortex10  rgb: the accumulated radiance estimate
//               a:   how many frames have fed it, 0..1 normalised
//   colortex9   r:   the scene depth this estimate was made against, so the
//                    next frame can tell a disocclusion from a camera move
//               g:   its luminance, kept for diagnostics
//               b:   hit confidence, 1 where a ray actually found geometry
//               a:   held at zero on purpose - composite3.fsh reads this
//                    buffer's alpha as a rain-drop mask, and since nothing in
//                    the pack writes it that term has always read zero. Writing
//                    anything here would switch on a fog effect nobody asked for.
//
// The accumulation is in the same pass as the trace because there is exactly
// one free slot in the chain before the lighting pass that consumes this, and
// spending it on a resolve instead of on the trace would buy less. The loader
// serves a copy of any target a pass reads and writes, so reading last frame's
// estimate here is well defined.

// Declared before the library that reads them. GLSL has no two-pass
// declaration, so an include that uses `near` has to come after the uniform
// that defines it, and the option files have to come before both because the
// library's step counts and cutoffs are options.
uniform vec2 texelSize;
uniform int frameCounter;
uniform float frameTimeCounter;

uniform float near;
// Declared rather than picked up from /lib/Shadow_Params.glsl, which is where
// the programs that include it get `far` from. That file declares a good deal
// more than this pass wants, and the loader supplies no fallback: a name a
// program reads without declaring is an error, not a zero.
uniform float far;

uniform sampler2D depthtex0;
uniform sampler2D colortex3;  // the previous frame's lit scene
uniform sampler2D colortex8;  // specular: smoothness, metalness, sss, emissive
uniform sampler2D colortex15; // geometric normal, vanilla AO
uniform sampler2D colortex9;  // this pass's own auxiliary target
uniform sampler2D colortex10; // this pass's own accumulation

flat varying vec3 ptSunVec;    // world space
flat varying vec3 ptSunColor;
flat varying vec3 ptSkyAvg;

#include "/lib/projections.glsl"
#include "/lib/pathtracer.glsl"

// The pass renders at PT_SCALE of the frame, so a texel of its own target is
// this much larger than a texel of the scene.
vec2 ptOwnTexel() { return texelSize / PT_SCALE; }

void main() {

/* DRAWBUFFERS:9,10 */

// Scene uv, in the same terms composite1.fsh uses: a fragment's own position
// over the frame. Reading the G-buffer and the depth through this one uv is what
// keeps the tracer geometrically consistent with the GTAO and the SSRT, which
// reconstruct their view positions from the same mapping.
vec2 uv = gl_FragCoord.xy * texelSize;
vec2 ownUV = uv / PT_SCALE;
vec2 ownTexel = ptOwnTexel();

float windowDepth = texture2D(depthtex0, uv).x;
float sceneZ = ptLinZ(windowDepth);

// Open sky, or the hand, which is not in the depth buffer we marched against.
// Either way there is no surface to gather from, and the sky is handled by the
// lighting pass itself.
if (windowDepth >= 1.0) {
	gl_FragData[0] = vec4(0.0, 0.0, 0.0, 0.0);
	gl_FragData[1] = vec4(0.0, 0.0, 0.0, 0.0);
	return;
}

vec3 viewPos = ptViewPos(vec3(uv, windowDepth));

vec3 nrm;
ptFetchNormal(colortex15, uv, nrm);
// A geometric normal points at the camera on every front face; a shading
// normal is the only thing that makes a reflection follow a bumpy surface.
// This pack's G-buffer has no shading normal - colortex15 is the face normal -
// so this is the honest limit of what can be traced here. See PATHTRACER.md.
if (dot(nrm, -normalize(viewPos)) < 0.0) nrm = -nrm;

vec3 emissive;
float smoothness, metalness;
ptFetchSurface(colortex8, uv, smoothness, metalness, emissive);

// Smooth enough to show a reflection at all. Below this the lobe is wider than
// the screen and the estimate is noise, so it is not worth a sample.
if (ptAlpha(smoothness) > PT_ROUGHNESS_CUTOFF) {
	gl_FragData[0] = vec4(0.0, 0.0, 0.0, 0.0);
	gl_FragData[1] = vec4(0.0, 0.0, 0.0, 0.0);
	return;
}

// The seed. R2 over the pixel and the frame is the cheapest sequence that is
// stable in screen space and decorrelated in time - a per-frame hash would
// decorrelate the neighbourhood the variance estimate is built from, and a
// per-pixel constant would freeze the same pattern into the image.
vec2 seed = vec2(
	fract(0.7548776662 * (gl_FragCoord.x + float(frameCounter % 4096) * 2.0)),
	fract(0.5698402909 * (gl_FragCoord.y + float(frameCounter % 4096) * 2.0))
);

vec3 viewDir = -normalize(viewPos);
vec3 horizon = max(ptSkyAvg / 30.0, vec3(0.0)) * Sky_Brightness;
// The zenith is the same colour a little cooler and brighter. Averaging the
// real sky would be better and would need the whole atmosphere evaluation
// dragged into a pass that has no other use for it.
vec3 zenith = horizon * vec3(0.82, 0.92, 1.12);

vec3 radiance;
float confidence;
radiance = ptTracePath(
	colortex15, colortex8, colortex3,
	viewPos, nrm, viewDir, smoothness, metalness,
	zenith, horizon, ptSunVec, max(ptSunColor, vec3(0.0)) / 30.0,
	seed, PT_BOUNCES, PT_STEPS, PT_MAX_DISTANCE, PT_THICKNESS, confidence
) * PT_INTENSITY;

// ---- temporal accumulation -------------------------------------------------
vec4 hist = texture2D(colortex10, ownUV);
float histLen = hist.a * PT_MAX_FRAMES;

// A disocclusion has to reset the history, or the old surface smears across the
// new one. Comparing the depth this estimate was made against with the depth in
// front of it now separates that from a camera turn, which changes every pixel's
// depth by a little and no pixel's by a lot.
float prevZ = texture2D(colortex9, ownUV).r;
float zRel = abs(sceneZ - prevZ) / max(sceneZ, 0.001);
histLen = (prevZ > 0.0 && zRel < PT_DISOCLUSION) ? histLen : 0.0;

// Clamp the history to its own neighbourhood. This is what keeps a reflection
// from trailing behind a moving highlight, and it is why the estimate does not
// need the previous frame's view-projection to reproject: the clamp does the
// work a reprojection would otherwise have to.
vec3 m1 = vec3(0.0);
vec3 m2 = vec3(0.0);
for (int y = -1; y <= 1; y++) {
	for (int x = -1; x <= 1; x++) {
		vec3 c = texture2D(colortex10, ownUV + vec2(float(x), float(y)) * ownTexel).rgb;
		m1 += c;
		m2 += c * c;
	}
}
m1 /= 9.0;
m2 /= 9.0;
vec3 sigma = sqrt(max(m2 - m1 * m1, vec3(0.0)));
vec3 clamped = clamp(hist.rgb, m1 - PT_CLAMP_SIGMA * sigma, m1 + PT_CLAMP_SIGMA * sigma);

float newLen = clamp(histLen + 1.0, 1.0, PT_MAX_FRAMES);
// A moving pixel accumulates no faster than a still one would, because the
// clamp is what a still pixel is relying on too - the difference is that a
// still pixel's history stays inside the neighbourhood.
vec3 resolved = mix(clamped, radiance, 1.0 / newLen);

float lum = dot(resolved, vec3(0.2126, 0.7152, 0.0722));

gl_FragData[0] = vec4(sceneZ, lum, confidence, 0.0);
gl_FragData[1] = vec4(max(resolved, vec3(0.0)), newLen / PT_MAX_FRAMES);

}
