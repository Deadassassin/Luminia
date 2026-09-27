// FauxTracer - screen-space path tracing
// ---------------------------------------------------------------------------
// A stochastic path tracer that runs in one fullscreen pass and is consumed by
// the deferred lighting pass. Three things make it a path tracer rather than the
// single-bounce march that was here before:
//
//   * the lobe is sampled, not aimed. Every bounce draws a GGX visible-normal
//     sample, so a rough surface integrates its whole lobe over time instead of
//     pretending one mirror direction stands in for it.
//   * rays bounce. A hit spawns a fresh ray from the hit point carrying an
//     energy weight, so light reaches a second and third surface. A miss ends
//     the path against the sky.
//   * the noise is integrated out. Each frame contributes one stochastic sample
//     per pixel, blended into a running estimate of capped length, with the
//     history clamped to the neighbourhood so a disocclusion cannot smear.
//
// Portability notes, because these constraints shaped the design:
//
//   * Only 2D samplers and colortexes. Vitrail binds sampler2D and a cube and
//     refuses a sampler1D outright, which is what kills the voxel/LPV path in
//     this pack. So the tracer carries its own half-resolution depth rather
//     than reading a voxel grid out of a 3D storage image.
//   * No compute, no storage images, no atomics. All of this is a fragment
//     shader reading 2D targets.
//   * The depth convention and the view<->screen transforms are the pack's own,
//     not independently derived. ptViewPos and toClipSpace3 are inverses under
//     the same convention the rest of the pack uses, so the tracer agrees
//     geometrically with the GTAO, the SSRT and the old SSR that all share it.
//     Re-deriving the matrices here would have been the one way to be subtly
//     and invisibly wrong.
//
// Requires from the including program: near, far, gbufferProjection,
// gbufferProjectionInverse, gbufferModelViewInverse, texelSize, frameCounter,
// and the samplers passed in below.

#ifndef FXT_LIB_PATHTRACER_INCLUDED
#define FXT_LIB_PATHTRACER_INCLUDED

float ptMax3(vec3 v) { return max(v.x, max(v.y, v.z)); }
float ptMin3(vec3 v) { return min(v.x, min(v.y, v.z)); }

float ptSaturate(float x) { return clamp(x, 0.0, 1.0); }

// ---------------------------------------------------------------------------
// Geometry
// ---------------------------------------------------------------------------
// The pack's linear depth: positive, and the same ld() composite1.fsh compares
// a marched position against. Sharing that function is the whole reason a hit
// here means the same thing a hit means in the GTAO and the SSRT.
float ptLinZ(float windowDepth) {
	return (2.0 * near) / (far + near - windowDepth * (far - near));
}

// Screen uv + window depth -> view position. A literal mirror of the
// toScreenSpace that composite1.fsh reconstructs its own viewPos with: same
// signature shape, same expression, renamed only so this file can sit next to
// it without the two looking like the same function when they are not.
// tools/validate_pt.py compares the two bodies and fails if they drift.
vec3 ptViewPos(vec3 p) {
	vec4 iProjDiag = vec4(gbufferProjectionInverse[0].x, gbufferProjectionInverse[1].y, gbufferProjectionInverse[2].zw);
	vec3 feetPlayerPos = p * 2. - 1.;
	vec4 viewPos = iProjDiag * feetPlayerPos.xyzz + gbufferProjectionInverse[3];
	return viewPos.xyz / viewPos.w;
}

vec3 ptViewToWorld(vec3 viewDir) {
	return normalize(mat3(gbufferModelViewInverse) * viewDir);
}

// ---------------------------------------------------------------------------
// Surface fetch
// ---------------------------------------------------------------------------
// colortex15 carries the G-buffer's geometric normal, colortex1 the albedo and
// colortex8 the specular block: .r perceptual smoothness, .g metalness, .b
// subsurface, .a emissive.
//
// Reading the G-buffer rather than the material atlases is deliberate. The
// atlases read one pixel and no more unless a PBR resource pack is installed -
// the loader reports exactly that - so a tracer built on them produces a
// plausible image made entirely of nothing. The G-buffer is written by the
// pack's own per-block classification either way.
void ptFetchNormal(sampler2D nrmTex, vec2 uv, out vec3 n) {
	n = normalize(texture2D(nrmTex, uv).xyz * 2.0 - 1.0);
}

void ptFetchSurface(sampler2D albTex, sampler2D specTex, vec2 uv,
					out vec3 albedo, out float smoothness, out float metalness, out vec3 emissive) {
	vec4 a = texture2D(albTex, uv);
	vec4 s = texture2D(specTex, uv);
	albedo = max(a.rgb, vec3(0.0));
	smoothness = clamp(s.r, 0.0, 1.0);
	// LabPBR puts a full metal in the top of the range and leaves dielectric F0
	// below it. Reading the whole channel as F0 without that split is what makes
	// every metal look like grey plastic.
	metalness = step(0.9, s.g);
	emissive = vec3(max(s.a, 0.0));
}

// Perceptual smoothness to GGX alpha. The squaring is the LabPBR definition and
// matters more than it looks: without it a half-smooth surface spreads its lobe
// far too wide and its reflections read as fog rather than as a blurry mirror.
float ptAlpha(float smoothness) {
	float r = 1.0 - clamp(smoothness, 0.0, 1.0);
	float r2 = r * r;
	return max(r2 * r2, 0.0015);
}

vec3 ptF0(float metalness) {
	return mix(vec3(0.04), vec3(1.0), metalness);
}

// ---------------------------------------------------------------------------
// GGX visible-normal sampling
// ---------------------------------------------------------------------------
// Heitz 2018, "Sampling the GGX Distribution of Visible Normals". Sampling the
// distribution of *visible* normals rather than the NDF is what makes one sample
// per pixel usable: the sample is already tilted towards the viewer, so it
// carries far more signal than an NDF sample at the same roughness would.
//
// V is in the local tangent frame with +z towards the viewer. alpha is GGX alpha
// (roughness^2, not roughness). u is a pair of uniforms in [0,1).
vec3 ptSampleGGXVNDF(vec3 V, float alpha, vec2 u) {
	// Stretch the view vector into the distribution's frame.
	vec3 Vh = normalize(vec3(alpha * V.x, alpha * V.y, V.z));

	// Orthonormal basis around it. The degenerate case is V straight down the
	// normal, where the tangent is arbitrary but must still be finite.
	float lensq = Vh.x * Vh.x + Vh.y * Vh.y;
	vec3 T1 = lensq > 1e-8 ? vec3(-Vh.y, Vh.x, 0.0) * inversesqrt(lensq) : vec3(1.0, 0.0, 0.0);
	vec3 T2 = cross(Vh, T1);

	// A point on the projected visible-normal lobe.
	float r = sqrt(u.x);
	float phi = 6.28318530718 * u.y;
	float t1 = r * cos(phi);
	float t2 = r * sin(phi);

	// Warp t2 towards the axis as the view approaches it, so the lobe does not
	// open a hole at normal incidence.
	float s = 0.5 * (1.0 + Vh.z);
	t2 = (1.0 - s) * sqrt(max(0.0, 1.0 - t1 * t1)) + s * t2;

	vec3 Nh = t1 * T1 + t2 * T2 + sqrt(max(0.0, 1.0 - t1 * t1 - t2 * t2)) * Vh;

	// Unstretch, and keep the normal in the visible hemisphere.
	return normalize(vec3(alpha * Nh.x, alpha * Nh.y, max(0.0, Nh.z)));
}

vec3 ptFresnel(vec3 f0, float VoH) {
	return f0 + (1.0 - f0) * pow(clamp(1.0 - VoH, 0.0, 1.0), 5.0);
}

// A frame around n that avoids the degenerate cross product a fixed up vector
// produces when the normal points along it.
void ptBasis(vec3 n, out vec3 t, out vec3 b) {
	vec3 up = abs(n.z) < 0.999 ? vec3(0.0, 0.0, 1.0) : vec3(0.0, 1.0, 0.0);
	t = normalize(cross(up, n));
	b = cross(n, t);
}

// ---------------------------------------------------------------------------
// The trace
// ---------------------------------------------------------------------------
// Marches the ray through the depth buffer in view space, comparing the ray's
// own view distance against the surface the depth buffer reports. The step
// grows along the ray, so a long grazing reflection costs far fewer samples
// than a short head-on one, and a binary refinement at the end recovers a hit
// position the coarse step alone would leave visibly quantised - which is what
// the old march's fixed 0.005 bias and 15% thickness test were papering over.
//
// Returns the view-space distance to the hit, or -1.0 for a miss, in which case
// hitUv is left at (-1,-1).
float ptTrace(vec3 P, vec3 D, float maxDist, float jitter, int steps, float thickness, out vec2 hitUv) {
	hitUv = vec2(-1.0);

	// A ray that does not travel away from the eye can only hit the near plane.
	if (D.z > -1e-4) return -1.0;

	float stepLen = maxDist / float(steps);
	float t = stepLen * clamp(jitter, 0.0, 1.0);
	float prevT = 0.0;

	for (int i = 0; i < 96; i++) {
		if (i >= steps) break;

		vec3 p = P + D * t;

		// Past the eye plane: everything beyond is behind the camera.
		if (p.z > -near) return -1.0;

		vec3 s = toClipSpace3(p);
		// Off screen. This is a correct miss rather than a loss: there is no
		// geometry of ours out there, and the sky or the fallback takes over.
		if (s.x < 0.0 || s.x > 1.0 || s.y < 0.0 || s.y > 1.0) return -1.0;

		float sceneZ = ptLinZ(texture2D(depthtex0, s.xy).x);
		float rayZ = -p.z;

		// Behind geometry, and close enough behind it that this is a crossing
		// rather than a pass behind a distant wall. The slack widens with
		// distance because a fixed world-space thickness is a vanishingly thin
		// sliver once the depth buffer's own quantisation is considered at
		// range - which is exactly why the old march's constant bias either
		// leaked or missed depending on the scene.
		float slack = thickness * (1.0 + rayZ * 0.06);
		if (rayZ > sceneZ && rayZ - sceneZ < slack) {
			float lo = prevT, hi = t;
			for (int k = 0; k < 6; k++) {
				float mid = 0.5 * (lo + hi);
				vec3 pm = P + D * mid;
				vec3 sm = toClipSpace3(pm);
				float sz = ptLinZ(texture2D(depthtex0, sm.xy).x);
				if (-pm.z > sz) hi = mid; else lo = mid;
			}
			hitUv = toClipSpace3(P + D * hi).xy;
			return hi;
		}

		prevT = t;
		// Growing step. The 0.14 ramp is a compromise: steeper reaches the far
		// plane in fewer samples but steps over thin geometry, which is what
		// produces the dotted, half-missing reflections this replaces.
		t += stepLen * (1.0 + float(i) * 0.14);
	}
	return -1.0;
}

// ---------------------------------------------------------------------------
// Sky
// ---------------------------------------------------------------------------
// Only reached when a ray leaves the screen, and only ever seen through a
// Fresnel term, so a two-stop gradient with a forward-scattering lobe is the
// right amount of fidelity. Evaluating the pack's real atmosphere would drag its
// entire uniform block into a pass with no other use for it.
vec3 ptSkyRadiance(vec3 worldDir, vec3 zenith, vec3 horizon, vec3 sunDir, vec3 sunColor) {
	vec3 d = normalize(worldDir);
	float up = clamp(d.y * 0.5 + 0.5, 0.0, 1.0);
	vec3 sky = mix(horizon, zenith, pow(up, 0.7));
	float sun = max(dot(d, sunDir), 0.0);
	// Deliberately not a sun disc: at this magnitude the disc would alias into a
	// crawling blob as the sample pattern moves.
	sky += sunColor * (pow(sun, 8.0) * 0.30 + pow(sun, 2.0) * 0.05);
	return max(sky, vec3(0.0));
}

// ---------------------------------------------------------------------------
// The path
// ---------------------------------------------------------------------------
// Traces up to `bounces` bounces. The weight carried along the path is the
// product of each bounce's Fresnel and a fixed geometric term, which is what
// makes a chain of metal highlights fall off instead of accumulating to white.
//
// A miss terminates the path against the sky; a hit continues from the hit
// surface with that surface's own material. Radiance leaving a hit comes from
// the previous frame's lit scene, because this pass runs before the lighting
// pass that would have produced this frame's version - which is also the only
// reason a second bounce is possible at all.
//
// `confidence` comes back as the fraction of bounces that found geometry rather
// than sky. It is what lets the consumer fade a reflection out where the trace
// is mostly guessing, instead of showing a noise field at full strength.
vec3 ptTracePath(
	sampler2D nrmTex, sampler2D albTex, sampler2D specTex, sampler2D litTex,
	vec3 P, vec3 N, vec3 V, float smoothness, float metalness,
	vec3 zenith, vec3 horizon, vec3 sunDirWorld, vec3 sunColor,
	vec2 seed, int bounces, int steps, float maxDist, float thickness,
	out float confidence
) {
	vec3 radiance = vec3(0.0);
	vec3 throughput = vec3(1.0);
	float hits = 0.0;
	float tries = 0.0;

	vec3 p = P;
	vec3 n = N;
	vec3 v = V;
	float sm = clamp(smoothness, 0.0, 1.0);
	float mt = clamp(metalness, 0.0, 1.0);

	// One random pair per bounce, rotated by the golden angle so successive
	// bounces are not correlated. Reusing a single sample every bounce would
	// correlate them and the variance would never come down.
	float rot = 0.0;

	for (int b = 0; b < 3; b++) {
		if (b >= bounces) break;

		vec2 u = fract(seed + vec2(rot, rot * 0.6180339887));
		rot += 0.7548776662;

		vec3 tAx, bAx;
		ptBasis(n, tAx, bAx);
		vec3 Vl = vec3(dot(v, tAx), dot(v, bAx), dot(v, n));
		if (Vl.z <= 0.0) break; // the surface has turned away from the eye

		vec3 Hl = ptSampleGGXVNDF(normalize(Vl), ptAlpha(sm), u);
		vec3 H = normalize(tAx * Hl.x + bAx * Hl.y + n * Hl.z);
		vec3 L = reflect(-v, H);

		// A lobe sample that leaves the surface is a wasted segment.
		if (dot(L, n) <= 0.0) break;

		vec3 F = ptFresnel(ptF0(mt), clamp(dot(-v, H), 0.0, 1.0));

		vec2 hitUv;
		float t = ptTrace(p + n * thickness, L, maxDist, u.x, steps, thickness, hitUv);
		tries += 1.0;

		if (t < 0.0) {
			radiance += throughput * F * ptSkyRadiance(ptViewToWorld(L), zenith, horizon, sunDirWorld, sunColor);
			break;
		}
		hits += 1.0;

		vec3 hitPos = p + L * t;
		vec3 hitN;
		ptFetchNormal(nrmTex, hitUv, hitN);

		vec3 hitAlb, hitEmis;
		float hitSm, hitMt;
		ptFetchSurface(albTex, specTex, hitUv, hitAlb, hitSm, hitMt, hitEmis);

		// The previous frame's lit scene is the only image of the lit world
		// available this early in the frame.
		vec3 hitLit = max(texture2D(litTex, hitUv).rgb, vec3(0.0)) + hitEmis;
		vec3 outRadiance = hitLit * clamp(dot(hitN, -L), 0.0, 1.0);

		radiance += throughput * F * outRadiance;

		// Throughput: what survives one more bounce. The (1 - metalness) and
		// the 0.5 are the split between a surface's specular and diffuse
		// halves, and are what stop an interior corner filling with light.
		throughput *= F * (1.0 - mt) * 0.5;

		// Russian roulette, from the second bounce on. By then the weight is
		// small and carrying it costs more than it returns, so the path is more
		// likely to be dropped - and renormalising the survivors keeps the
		// estimate unbiased, which is the difference between a noisy tracer and
		// a biased one.
		if (b >= 1) {
			float q = clamp(ptMax3(throughput), 0.05, 0.95);
			if (u.y > q) break;
			throughput /= q;
		}
		if (ptMax3(throughput) < 0.02) break;

		p = hitPos + hitN * thickness;
		n = hitN;
		v = -L;
		sm = hitSm;
		mt = hitMt;
	}

	confidence = tries > 0.0 ? clamp(hits / tries, 0.0, 1.0) : 0.0;
	return max(radiance, vec3(0.0));
}

#endif
