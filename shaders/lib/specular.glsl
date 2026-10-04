uniform int framemod8;

const vec2[8] offsets = vec2[8](vec2(1./8.,-3./8.),
									vec2(-1.,3.)/8.,
									vec2(5.0,1.)/8.,
									vec2(-3,-5.)/8.,
									vec2(-5.,5.)/8.,
									vec2(-7.,-1.)/8.,
									vec2(3,7.)/8.,
									vec2(7.,-7.)/8.);

vec3 lerp(vec3 X, vec3 Y, float A){
	return X * (1.0 - A) + Y * A;
}

float lerp(float X, float Y, float A){
	return X * (1.0 - A) + Y * A;
}

float square(float x){
  return x*x;
}



vec3 toClipSpace3(vec3 viewSpacePosition) {
    return projMAD(gbufferProjection, viewSpacePosition) / -viewSpacePosition.z * 0.5 + 0.5;
}
float invLinZ (float lindepth){
	return -((2.0*near/lindepth)-far-near)/(far-near);
}
float linZ(float depth) {
    return (2.0 * near) / (far + near - depth * (far - near));
	// l = (2*n)/(f+n-d(f-n))
	// f+n-d(f-n) = 2n/l
	// -d(f-n) = ((2n/l)-f-n)
	// d = -((2n/l)-f-n)/(f-n)

}

void frisvad(in vec3 n, out vec3 f, out vec3 r){
    if(n.z < -0.9) {
        f = vec3(0.,-1,0);
        r = vec3(-1, 0, 0);
    } else {
    	float a = 1./(1.+n.z);
    	float b = -n.x*n.y*a;
    	f = vec3(1. - n.x*n.x*a, b, -n.x) ;
    	r = vec3(b, 1. - n.y*n.y*a , -n.y);
    }
}

mat3 CoordBase(vec3 n){
	vec3 x,y;
    frisvad(n,x,y);
    return mat3(x,y,n);
}

vec2 R2_Sample(int n){
	vec2 alpha = vec2(0.75487765, 0.56984026);
	return fract(alpha * n);
}

vec3 rayTraceSpeculars(vec3 dir, vec3 position, float dither, float quality, bool hand, inout float reflectLength){

	vec3 clipPosition = toClipSpace3(position);
	float rayLength = ((position.z + dir.z * far*sqrt(3.)) > -near) ?
	                   (-near -position.z) / dir.z : far*sqrt(3.);
	vec3 direction = normalize(toClipSpace3(position+dir*rayLength)-clipPosition);  //convert to clip space
	direction.xy = normalize(direction.xy);

	//get at which length the ray intersects with the edge of the screen
	vec3 maxLengths = (step(0.0,direction)-clipPosition) / direction;
	float mult = min(min(maxLengths.x,maxLengths.y),maxLengths.z);

	vec3 stepv = direction * mult / quality*vec3(RENDER_SCALE,1.0);

	vec3 spos = clipPosition*vec3(RENDER_SCALE,1.0) + stepv*dither;

	float minZ = spos.z;
	float maxZ = spos.z;
	
	spos.xy += TAA_Offset*texelSize*0.5/RENDER_SCALE;
	float depthcancleoffset = pow(1.0-(quality/reflection_quality),1.0);

	float dist = 1.0 + clamp(position.z*position.z/50.0,0.0,2.0); // shrink sample size as distance increases
  	for (int i = 0; i <= int(quality); i++) {

		// float sp = invLinZ(sqrt(texelFetch2D(colortex4,ivec2(spos.xy/texelSize/4.0),0).a/65000.0));

		// if(sp <= max(maxZ,minZ) && sp >= min(maxZ,minZ) ) return vec3(spos.xy/RENDER_SCALE,sp);
		
		// spos += stepv;
		
		// //small bias
		// float biasamount = (0.0002 + 0.0015*pow(depthcancleoffset,5) ) / dist;

		// if(hand) biasamount = 0.00035;

		// minZ = maxZ-biasamount / ld(spos.z);
		// maxZ += stepv.z;


		float sp = invLinZ(sqrt(texelFetch2D(colortex4,ivec2(spos.xy/texelSize/4.0),0).a/65000.0));

		float currZ = linZ(spos.z);
		float nextZ = linZ(sp);

		// if(nextZ < currZ) {
			if(abs(nextZ-currZ)/currZ < 0.15 && sp <= max(minZ,maxZ) && sp >= min(minZ,maxZ)) return vec3(spos.xy/RENDER_SCALE,sp);
		// }
		float biasamount = 0.005;
		minZ = maxZ-biasamount / linZ(spos.z);
		maxZ += stepv.z;

		spos += stepv;

		reflectLength += 1.0 / quality; // for shit
  	}
  return vec3(1.1);
}

float fma(float a,float b,float c){
 return a * b + c;
}

//// thank you Zombye | the paper: https://ggx-research.github.io/publication/2023/06/09/publication-ggx.html
vec3 SampleVNDFGGX(
    vec3 viewerDirection, // Direction pointing towards the viewer, oriented such that +Z corresponds to the surface normal
    vec2 alpha, // Roughness parameter along X and Y of the distribution
    float xy // Pair of uniformly distributed numbers in [0, 1)
) {
	// alpha *= alpha;
    // Transform viewer direction to the hemisphere configuration
    viewerDirection = normalize(vec3(alpha * viewerDirection.xy, viewerDirection.z));

    // Sample a reflection direction off the hemisphere
    const float tau = 6.2831853; // 2 * pi
    float phi = tau * xy;

    float cosTheta = fma(1.0 - xy, 1.0 + viewerDirection.z, -viewerDirection.z) ;
    float sinTheta = sqrt(clamp(1.0 - cosTheta * cosTheta, 0.0, 1.0));

	// xonk note, i dont know what im doing but this kinda does what i want so whatever
	float attemptTailClamp  = clamp(sinTheta,max(cosTheta-0.25,0), cosTheta);
	float attemptTailClamp2 = clamp(cosTheta,max(sinTheta-0.25,0), sinTheta);

    vec3 reflected = vec3(vec2(cos(phi), sin(phi)) * attemptTailClamp2, attemptTailClamp);
    // vec3 reflected = vec3(vec2(cos(phi), sin(phi)) * sinTheta, cosTheta);

    // Evaluate halfway direction
    // This gives the normal on the hemisphere
    vec3 halfway = reflected + viewerDirection;

    // Transform the halfway direction back to hemiellispoid configuation
    // This gives the final sampled normal
    return normalize(vec3(alpha * halfway.xy, halfway.z));
}

float GGX(vec3 n, vec3 v, vec3 l, float r, float f0) {
  r = max(pow(r,2.5), 0.0001);

  vec3 h = l + v;
  float hn = inversesqrt(dot(h, h));

  float dotLH = clamp(dot(h,l)*hn,0.,1.);
  float dotNH = clamp(dot(h,n)*hn,0.,1.) ;
  float dotNL = clamp(dot(n,l),0.,1.);
  float dotNHsq = dotNH*dotNH;

  float denom = dotNHsq * r - dotNHsq + 1.;
  float D = r / (3.141592653589793 * denom * denom);

  float F = f0 + (1. - f0) * exp2((-5.55473*dotLH-6.98316)*dotLH);
  float k2 = .25 * r;

  return dotNL * D * F / (dotLH*dotLH*(1.0-k2)+k2);
}

void DoSpecularReflections(
	inout vec3 Output,

	vec3 FragPos, // toScreenspace(vec3(screenUV, depth)
	vec2 ScreenUV, // the same uv, un-scaled, for reading a pass's own target
	vec3 WorldPos,
    vec3 LightPos, // should be in world space
    vec2 Noise, // x = bluenoise z = interleaved gradient noise

	vec3 Normal, // normals in world space
	float Roughness, // red channel of specular texture _S
	float F0, // green channel of specular texture _S

	vec3 Albedo, 
	vec3 Diffuse, // should contain the light color and NdotL. and maybe shadows.

    float Lightmap, // in anything other than world0, this should be 1.0;
    bool Hand // mask for the hand
){
	vec3 Final_Reflection = Output;
	vec3 Background_Reflection = Output;
	vec3 Lightsource_Reflection = vec3(0.0);
	vec4 SS_Reflections = vec4(0.0);

	Lightmap = clamp((Lightmap-0.8)*7.0, 0.0,1.0);
	
	Roughness = 1.0 - Roughness; Roughness *= Roughness;
	F0 = F0 == 0.0 ? 0.02 : F0;

	// Roughness = 0.0;
	// F0 = 0.9;

	mat3 Basis = CoordBase(Normal);
	vec3 ViewDir = -WorldPos*Basis;

	#ifdef Rough_reflections
		vec3 SamplePoints = SampleVNDFGGX(ViewDir, vec2(Roughness), Noise.x);
		if(Hand) SamplePoints = vec3(0.0,0.0,1.0);
	#else
		vec3 SamplePoints = vec3(0.0,0.0,1.0);
	#endif

	vec3 Ln = reflect(-ViewDir, SamplePoints);
	vec3 L = Basis * Ln;

	float Fresnel = pow(clamp(1.0 + dot(-Ln, SamplePoints),0.0,1.0), 5.0); // Schlick's approximation

	float RayContribution = lerp(F0, 1.0, Fresnel); // ensure that when the angle is 0 that the correct F0 is used.
	
	#ifdef Rough_reflections
		if(Hand) RayContribution = RayContribution * pow(1.0-Roughness,F0 > 229.5/255.0 ? 1.0 : 3.0);
	#else
		RayContribution = RayContribution * pow(1.0-Roughness,3.0);
	#endif

    bool hasReflections = Roughness_Threshold == 1.0 ? true : F0 * (1.0 - Roughness * Roughness_Threshold) > 0.01;

	// mulitply all reflections by the albedo if it is a metal.
	// vec3 Metals = F0 > 229.5/255.0 ? lerp(normalize(Albedo+1e-7) * (dot(Albedo,vec3(0.21, 0.72, 0.07)) * 0.7 + 0.3), vec3(1.0), Fresnel * pow(1.0-Roughness,25.0)) : vec3(1.0);
	vec3 Metals = F0 > 229.5/255.0 ? normalize(Albedo+1e-7) * (dot(Albedo,vec3(0.21, 0.72, 0.07)) * 0.7 + 0.3) : vec3(1.0);
	// vec3 Metals = F0 > 229.5/255.0 ? Albedo : vec3(1.0);

	// --------------- BACKGROUND REFLECTIONS
	// apply background reflections to the final color. make sure it does not exist based on the lightmap
	// Both of the next two blocks are alternatives to the path tracer rather
	// than additions to it. Each of them produces the *same* thing the tracer
	// does - the radiance arriving from the reflection direction - so running
	// them together would light every reflective surface twice and wash the
	// image out. The tracer replaces both; the sun's own glint below is kept,
	// because that is a light source rather than an environment and the tracer
	// does not model it.
	#if defined Sky_reflection && !defined PATH_TRACER

		#ifdef OVERWORLD_SHADER
			if(hasReflections) Background_Reflection = (skyCloudsFromTex(L, colortex4).rgb / 30.0) * Metals ;
		#else
			if(hasReflections) Background_Reflection = (skyCloudsFromTexLOD2(L, colortex4, sqrt(Roughness) * 6.0).rgb / 30.0) * Metals;
		#endif

		// take fresnel and lightmap levels into account and write to the final color
		Final_Reflection = lerp(Output, Background_Reflection, Lightmap * RayContribution);
	#endif

	// --------------- SCREENSPACE REFLECTIONS
	// apply screenspace reflections to the final color and mask out background reflections.
	#if defined Screen_Space_Reflections && !defined PATH_TRACER
		if(hasReflections){
			#ifdef Dynamic_SSR_quality
				float SSR_Quality = lerp(reflection_quality, 6.0, RayContribution); // Scale quality with ray contribution
			#else
				float SSR_Quality = reflection_quality;
			#endif

			float reflectLength = 0.0;
			vec3 RaytracePos = rayTraceSpeculars(mat3(gbufferModelView) * L, FragPos,  Noise.y, float(SSR_Quality), Hand, reflectLength);
			float LOD = clamp(pow(reflectLength, pow(1.0-sqrt(Roughness),5.0) * 3.0) * 6.0, 0.0, 6.0); // use higher LOD as the reflection goes on, to blur it. this helps denoise a little.
			
			if(Roughness <= 0.0) LOD = 0.0;

			if (RaytracePos.z < 1.0){
				vec3 previousPosition = mat3(gbufferModelViewInverse) * toScreenSpace(RaytracePos) + gbufferModelViewInverse[3].xyz + cameraPosition-previousCameraPosition;
				previousPosition = mat3(gbufferPreviousModelView) * previousPosition + gbufferPreviousModelView[3].xyz;
				previousPosition.xy = projMAD(gbufferPreviousProjection, previousPosition).xy / -previousPosition.z * 0.5 + 0.5;
		
				if (previousPosition.x > 0.0 && previousPosition.y > 0.0 && previousPosition.x < 1.0 && previousPosition.x < 1.0) {
					SS_Reflections.a = 1.0;
					SS_Reflections.rgb = texture2DLod(colortex5, previousPosition.xy, LOD).rgb * Metals;
				}
			}
			// make sure it takes the fresnel into account for SSR.
			SS_Reflections.rgb = lerp(Output, SS_Reflections.rgb, RayContribution);
		
			// occlude the background with the SSR and write to the final color.
			Final_Reflection = lerp(Final_Reflection, SS_Reflections.rgb, SS_Reflections.a);
		}
	#endif

	// --------------- PATH TRACED REFLECTIONS
	// The radiance the tracer gathered along a stochastically sampled GGX path,
	// temporally accumulated in its own pass. This replaces the two blocks above,
	// which is why they are switched off when PATH_TRACER is on.
	#ifdef PATH_TRACER
	if (hasReflections) {
		// Read at the producer's own uv rather than FragPos.xy. The tracer
		// derives its uv from gl_FragCoord the same way this pass does, and the
		// two agreeing is the only reason this lands on the right pixel.
		vec4 traced = texture2D(colortex10, ScreenUV);
		// The tracer's own hit fraction. A pixel where most rays left the screen
		// is mostly an estimate of the sky, and showing it at full strength is
		// how a screen-space tracer announces that it is guessing.
		float confidence = texture2D(colortex9, ScreenUV).b;

		// The sky, computed here rather than left to the block above, and that is
		// the whole reason this function still works with the tracer on.
		//
		// The block above is switched off when PATH_TRACER is defined, and the
		// tracer is in turn gated on hasReflections and on its own confidence.
		// Without a fallback in between, a surface the tracer could not resolve
		// would end up with no environment reflection at all - which is a worse
		// image than the tracer's own noise, and much harder to diagnose because
		// it looks like a lighting bug rather than a missing fallback.
		vec3 skyRefl = vec3(0.0);
		#ifdef OVERWORLD_SHADER
			skyRefl = (skyCloudsFromTex(L, colortex4).rgb / 30.0) * Metals;
		#else
			skyRefl = (skyCloudsFromTexLOD2(L, colortex4, sqrt(Roughness) * 6.0).rgb / 30.0) * Metals;
		#endif
		vec3 withSky = lerp(Output, skyRefl, Lightmap * RayContribution);

		// A target the tracer never wrote does not read as zero, it reads as
		// whatever was in it. The history length is only ever written next to a
		// real estimate, so it is what says whether there is anything here to
		// believe at all.
		float have = step(1.0 / 255.0, traced.a);

		// The estimate already carries a Fresnel term per bounce, so it is not
		// weighted by one again. What is left is how much of it to believe:
		// the tracer's own confidence, the lightmap, and whether it ran.
		float believe = clamp(confidence, 0.0, 1.0) * Lightmap * PT_INTENSITY * have;

		Final_Reflection = lerp(withSky, max(traced.rgb, vec3(0.0)) * Metals, clamp(believe, 0.0, 1.0));
	}
	#endif

	// Final_Reflection = mix(mix(Output,Background_Reflection,Lightmap), SS_Reflections.rgb, SS_Reflections.a) * RayContribution;

	// --------------- LIGHTSOURCE REFLECTIONS
	// slap the main lightsource reflections to the final color.
	//
	// This is the only reflection path with no hasReflections gate, so in v0.4.2 it
	// ran on every block in the world - including the ones the gate had just
	// rejected as matte. That is what made a matte block look lit from within.
	// Quartz was the one that made it obvious, because quartz is deliberately not
	// in lib/material_reflectance.glsl: it scores gate = -0.0033 against the 0.01
	// cutoff, hasReflections is false, and every other path below is correctly
	// switched off - while this one carried on regardless.
	//
	// Gating it makes the gate mean one thing in one place: a surface reflects or
	// it does not.
	#ifdef LIGHTSOURCE_REFLECTION
		if (hasReflections) {
			// GGX() in this file has no geometry term and no 1/(4*NoV), so the factor
			// that is supposed to cancel D's growth is not there and the result runs
			// away as roughness falls. Its own floor, r = max(pow(r,2.5), 0.0001),
			// only holds it to about 1e8, which is nowhere near bounded.
			//
			// In v0.4.2 this was harmless, and only by accident: every block sampled
			// the specular texture at roughness 1.0, where the term evaluates to 0.05
			// and nobody would ever have noticed. A per-block material table
			// (lib/material_reflectance.glsl) is the first thing to hand this function
			// a genuinely smooth surface, and it goes off the scale immediately:
			//
			//     roughness 1.00   every block in v0.4.2          5.1e-02
			//     roughness 0.55   netherrack                       1.0e+00
			//     roughness 0.09   lapis, emerald                   8.6e+03
			//     roughness 0.04   iron, copper, iron ore          1.1e+07
			//     roughness 0.02   gold                             1.2e+08
			//
			// and 1e8 is well past what the RGBA16F targets hold (65504), so it clamps
			// partway through the bloom chain. What survives is a bright halo of
			// whatever channel ratio the clamp left behind, which is why this reads as
			// a glow of a colour the block does not have rather than as a highlight.
			// It is additive, so nothing else in the function gates it.
			//
			// 0.035 is not a number picked here: all_translucent.fsh:805 has always
			// guarded its own GGX call with max(roughness, 0.035) and this path simply
			// never got the same guard. Using it makes the two agree, which they should
			// have been from the start.
			float glintRoughness = max(Roughness, 0.035);

			// The floor above bounds the roughness axis. It does not bound the other
			// singularity in GGX: as dotLH goes to 0 - the light directly opposite the
			// view - the denominator falls to k2 = 0.25*r while D rises as 1/r, so the
			// product still reaches 1e7 on the materials above.
			//
			// This is not a flaw in the arithmetic. A punctual light reflected by a
			// near-mirror genuinely IS a delta function and unbounded, which is why
			// renderers either clamp it or integrate it over the light's solid angle.
			// This pack has no light solid angle to integrate over - LightPos is a
			// direction - so the peak is capped instead.
			//
			// Capping at 1.0 and then weighting by RayContribution means the strongest
			// glint a surface can add is its own Fresnel reflectance times its lit
			// colour: strong and obvious on a metal (F0 0.906), barely there on a
			// dielectric (F0 0.04). That is the correct relative answer, and it is the
			// same RayContribution the sky and screen-space paths above already use, so
			// all three agree on how reflective a surface is.
			//
			// The clamp discards the Schlick term GGX carries internally, and
			// RayContribution puts a Fresnel weight back on the result - so for a
			// surface sitting at the cap the total is one Fresnel, not two. Blocks
			// still under the cap (concrete 0.076, wool 0.003) keep GGX's own value and
			// pick up a second Schlick factor, which is immaterial because they are
			// already dim and rough.
			float glint = min(GGX(Normal, -WorldPos, LightPos, glintRoughness, F0), 1.0);

			Lightsource_Reflection = Diffuse * glint * RayContribution * Metals;
			Final_Reflection += Lightsource_Reflection * Sun_specular_Strength ;
		}
	#endif

	Output = Final_Reflection;
}