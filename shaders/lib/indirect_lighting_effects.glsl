vec2 R2_samples(int n){
	vec2 alpha = vec2(0.75487765, 0.56984026);
	return fract(alpha * n);
}

vec3 cosineHemisphereSample(vec2 Xi){
    float theta = 2.0 * 3.14159265359 * Xi.y;

    float r = sqrt(Xi.x);
    float x = r * cos(theta);
    float y = r * sin(theta);

    return vec3(x, y, sqrt(clamp(1.0 - Xi.x,0.,1.)));
}

vec3 TangentToWorld(vec3 N, vec3 H, float roughness){
    vec3 UpVector = abs(N.z) < 0.999 ? vec3(0.0, 0.0, 1.0) : vec3(1.0, 0.0, 0.0);
    vec3 T = normalize(cross(UpVector, N));
    vec3 B = cross(N, T);

    return vec3((T * H.x) + (B * H.y) + (N * H.z));
}
vec2 SpiralSample(
	int samples, int totalSamples, float rotation, float Xi
){
	Xi = max(Xi,0.0015);
	
    float alpha = float(samples + Xi) * (1.0 / float(totalSamples));
	
    float theta = (2.0 *3.14159265359) * alpha * rotation;

    float r = sqrt(Xi);
	float x = r * sin(theta);
	float y = r * cos(theta);

    return vec2(x, y);
}

////////////////////////////////////////////////////////////////
/////////////////////////////	SSAO 	////////////////////////
////////////////////////////////////////////////////////////////

vec4 BilateralUpscale_SSAO(sampler2D tex, sampler2D depth, vec2 coord, float referenceDepth){
	ivec2 scaling = ivec2(1.0);
	ivec2 posDepth  = ivec2(coord) * scaling;
	ivec2 posColor  = ivec2(coord);
  	ivec2 pos = ivec2(gl_FragCoord.xy*texelSize + 1);

	ivec2 getRadius[4] = ivec2[](
   	 	ivec2(-2,-2),
	  	ivec2(-2, 0),
		ivec2( 0, 0),
		ivec2( 0,-2)
  	);
	// ivec2 getRadius3x3[8] = ivec2[](
   	// 	ivec2(-2,-2),
	// 	ivec2(-2, 0),
	// 	ivec2( 0, 0),
	// 	ivec2( 0,-2),
    // 	ivec2(-2,-1),
	// 	ivec2(-1,-2),
	// 	ivec2(0,-1),
	// 	ivec2(-1,0)
	// );
	#ifdef DISTANT_HORIZONS
		float diffThreshold = 0.0005 ;
	#else
		float diffThreshold = 0.005;
	#endif

	vec4 RESULT = vec4(0.0);
	float SUM = 0.0;

	for (int i = 0; i < 4; i++) {
		
		ivec2 radius = getRadius[i];
		#ifdef DISTANT_HORIZONS
			float offsetDepth = sqrt(texelFetch2D(depth, posDepth + radius * scaling + pos * scaling,0).a/65000.0);
		#else
			float offsetDepth = ld(texelFetch2D(depth, posDepth + radius * scaling + pos * scaling, 0).r);
		#endif

		float EDGES = abs(offsetDepth - referenceDepth) < diffThreshold ? 1.0 : 1e-5;
		
		RESULT += texelFetch2D(tex, posColor + radius + pos, 0) * EDGES;
		
		SUM += EDGES;
	}

	// return vec4(1,1,1,1) * SUM/4;

	return RESULT / SUM;
}

vec2 SSAO(
	vec3 viewPos, vec3 normal, bool hand, bool leaves, float noise
){
	if(hand) return vec2(1.0,0.0);
	int samples = 7;
	float occlusion = 0.0; 
	float sss = 0.0;


	float dist = 1.0 + clamp(viewPos.z*viewPos.z/50.0,0,5); // shrink sample size as distance increases
	float mulfov2 = gbufferProjection[1][1]/(3 * dist);
	float maxR2 = viewPos.z*viewPos.z*mulfov2*2.*5/50.0;

	#ifdef Ambient_SSS
		float maxR2_2 = viewPos.z*viewPos.z*mulfov2*2.*2./50.0;

		float dist3 = clamp(1-exp( viewPos.z*viewPos.z / -50),0,1);
		if(leaves) maxR2_2 = mix(10, maxR2_2, dist3);
	#endif

	vec2 acc = -(TAA_Offset*(texelSize/2))*RENDER_SCALE ;

	int n = 0;
	for (int i = 0; i < samples; i++) {
		
		// vec2 sampleOffset = SpiralSample(i, 7, 8, noise) * 0.2 * mulfov2;
		
		vec2 sampleOffset = SpiralSample(i, 7, 8, noise) * clamp(0.05 + i*0.095, 0.0,0.3)  * mulfov2;

		ivec2 offset = ivec2(gl_FragCoord.xy + sampleOffset*vec2(viewWidth,viewHeight*aspectRatio)*RENDER_SCALE);

		if (offset.x >= 0 && offset.y >= 0 && offset.x < viewWidth*RENDER_SCALE.x && offset.y < viewHeight*RENDER_SCALE.y ) {
			#ifdef DISTANT_HORIZONS
				float dhdepth = texelFetch2D(dhDepthTex1, offset,0).x;
			#else
				float dhdepth = 0.0;
			#endif

			vec3 t0 = toScreenSpace_DH((offset*texelSize+acc+0.5*texelSize) * (1.0/RENDER_SCALE), texelFetch2D(depthtex1, offset,0).x, dhdepth);
			vec3 vec = (t0.xyz - viewPos);
			float dsquared = dot(vec, vec);
			
			if (dsquared > 1e-5){
				if (dsquared < maxR2){
					float NdotV = clamp(dot(vec*inversesqrt(dsquared), normalize(normal)),0.,1.);
					occlusion += NdotV * clamp(1.0-dsquared/maxR2,0.0,1.0);
				}

				#ifdef Ambient_SSS
					if(dsquared > maxR2_2){
						float NdotV = 1.0 - clamp(dot(vec*dsquared, normalize(normal)),0.,1.);
						sss += max((NdotV - (1.0-NdotV)) * clamp(1.0-maxR2_2/dsquared,0.0,1.0) ,0.0);
					}
				#endif

				n += 1;
			}
		}
	}
	return max(1.0 - vec2(occlusion, sss)/n, 0.0);
}
float ScreenSpace_SSS(
	vec3 viewPos, vec3 normal, bool hand, bool leaves, float noise
){
	if(hand) return 0.0;
	int samples = 7;
	float occlusion = 0.0; 
	float sss = 0.0;


	float dist = 1.0 + clamp(viewPos.z*viewPos.z/50.0,0,5); // shrink sample size as distance increases
	float mulfov2 = gbufferProjection[1][1]/(3 * dist);

	float maxR2_2 = viewPos.z*viewPos.z*mulfov2*2.*2./50.0;

	float dist3 = clamp(1-exp( viewPos.z*viewPos.z / -50),0,1);
	if(leaves) maxR2_2 = mix(10, maxR2_2, dist3);
	

	vec2 acc = -(TAA_Offset*(texelSize/2))*RENDER_SCALE ;

	int n = 0;
	for (int i = 0; i < samples; i++) {
		
		vec2 sampleOffset = SpiralSample(i, 7, 8, noise) * 0.2 * mulfov2;

		ivec2 offset = ivec2(gl_FragCoord.xy + sampleOffset*vec2(viewWidth,viewHeight*aspectRatio)*RENDER_SCALE);

		if (offset.x >= 0 && offset.y >= 0 && offset.x < viewWidth*RENDER_SCALE.x && offset.y < viewHeight*RENDER_SCALE.y ) {
			vec3 t0 = toScreenSpace(vec3(offset*texelSize+acc+0.5*texelSize, texelFetch2D(depthtex1, offset,0).x) * vec3(1.0/RENDER_SCALE, 1.0) );
			vec3 vec = (t0.xyz - viewPos);
			float dsquared = dot(vec, vec);
			
			if (dsquared > 1e-5){
				if(dsquared > maxR2_2){
					float NdotV = 1.0 - clamp(dot(vec*dsquared, normalize(normal)),0.,1.);
					sss += max((NdotV - (1.0-NdotV)) * clamp(1.0-maxR2_2/dsquared,0.0,1.0) ,0.0);
				}
				n += 1;
			}
		}
	}
	return max(1.0 - sss/n, 0.0);
}

////////////////////////////////////////////////////////////////////
/////////////////////////////	RTAO/SSGI 	////////////////////////
////////////////////////////////////////////////////////////////////

vec3 rayTrace_GI(vec3 dir,vec3 position,float dither, float quality){

	vec3 clipPosition = toClipSpace3(position);
	float rayLength = ((position.z + dir.z * far*sqrt(3.)) > -near) ?
	                   (-near -position.z) / dir.z : far*sqrt(3.);
	vec3 direction = normalize(toClipSpace3(position+dir*rayLength)-clipPosition);  //convert to clip space
	direction.xy = normalize(direction.xy);

	//get at which length the ray intersects with the edge of the screen
	vec3 maxLengths = (step(0.0,direction)-clipPosition) / direction;
	float mult = min(min(maxLengths.x,maxLengths.y),maxLengths.z);

	vec3 stepv = (direction * mult) / quality*vec3(RENDER_SCALE,1.0);
	vec3 spos = clipPosition*vec3(RENDER_SCALE,1.0)	+ stepv*dither;

	spos.xy += TAA_Offset*texelSize*0.5*RENDER_SCALE ;

	float minZ = spos.z;
	float maxZ = spos.z;

	for(int i = 0; i < int(quality); i++){
		if (spos.x < 0.0 || spos.y < 0.0 || spos.z < 0.0 || spos.x > 1.0 || spos.y > 1.0 || spos.z > 1.0) return vec3(1.1);

		#ifdef UseQuarterResDepth
			float sp = invLinZ(sqrt(texelFetch2D(colortex4,ivec2(spos.xy/texelSize/4),0).w/65000.0));
		#else
			float sp = texelFetch2D(depthtex1,ivec2(spos.xy/ texelSize),0).r;
		#endif

		float currZ = linZ(spos.z);
		float nextZ = linZ(sp);

		if(nextZ < currZ && (sp <= max(minZ,maxZ) && sp >= min(minZ,maxZ))) return vec3(spos.xy/RENDER_SCALE,sp);
		
		float biasamount = 0.00005;

		minZ = maxZ - biasamount / currZ;
		maxZ += stepv.z;

		spos += stepv;
	}
  return vec3(1.1);
}
float convertHandDepth_3(in float depth, bool hand) {
    if(!hand) return depth;
	
	float ndcDepth = depth * 2.0 - 1.0;
    ndcDepth /= MC_HAND_DEPTH;
    return ndcDepth * 0.5 + 0.5;
}
vec3 RT(vec3 dir, vec3 position, float noise, float stepsizes, bool hand){
	float dist = 1.0 + clamp(position.z*position.z,0,2); // shrink sample size as distance increases

	float stepSize = stepsizes / dist;
	int maxSteps = STEPS;
	vec3 clipPosition = toClipSpace3(position);
	float rayLength = ((position.z + dir.z * sqrt(3.0)*far) > -sqrt(3.0)*near) ?
	   								(-sqrt(3.0)*near -position.z) / dir.z : sqrt(3.0)*far;
	vec3 end = toClipSpace3(position+dir*rayLength) ;
	vec3 direction = end-clipPosition ;  //convert to clip space

	float len = max(abs(direction.x)/texelSize.x,abs(direction.y)/texelSize.y)/stepSize;
	//get at which length the ray intersects with the edge of the screen
	vec3 maxLengths = (step(0.,direction)-clipPosition) / direction;
	
	float mult = min(min(maxLengths.x,maxLengths.y),maxLengths.z)*2000.0;

	vec3 stepv = direction/len;


	int iterations = min(int(min(len, mult*len)-2), maxSteps);
	
	//Do one iteration for closest texel (good contact shadows)
	vec3 spos = clipPosition*vec3(RENDER_SCALE,1.0) ;
	spos.xy += TAA_Offset*texelSize*0.5*RENDER_SCALE;
	
	spos += stepv;
	
	float distancered = 1.0 + clamp(position.z*position.z/50.0,0,2); // shrink sample size as distance increases

  	for(int i = 0; i < iterations; i++){
		if (spos.x < 0.0 || spos.y < 0.0 || spos.z < 0.0 || spos.x > 1.0 || spos.y > 1.0 || spos.z > 1.0) return vec3(1.1);
		
		spos += stepv*noise;
		#ifdef UseQuarterResDepth
			float sp = sqrt(texelFetch2D(colortex4,ivec2(spos.xy/ texelSize/4),0).w/65000.0);
		#else
			float sp = linZ(texelFetch2D(depthtex1,ivec2(spos.xy/ texelSize),0).r);
		#endif
		
		float currZ = linZ(spos.z);
		
		if( sp < currZ) {
			float dist = abs(sp-currZ)/currZ;
			if (dist <= mix(0.5, 0.1, clamp(position.z*position.z - 0.1,0,1))) return vec3(spos.xy, invLinZ(sp))/vec3(RENDER_SCALE,1.0);
		}
	}
	return vec3(1.1);
}

vec3 RT_alternate(vec3 dir, vec3 position, float noise, float stepsizes, bool hand){

	vec3 worldpos = mat3(gbufferModelViewInverse) * position;

	float dist = 1.0 + length(worldpos)/far; // step length as distance increases
	float stepSize = stepsizes / dist;

	int maxSteps = 10;
	vec3 clipPosition = toClipSpace3(position);
	float rayLength = ((position.z + dir.z * sqrt(3.0)*far) > -sqrt(3.0)*near) ?
	   								(-sqrt(3.0)*near -position.z) / dir.z : sqrt(3.0)*far;
	vec3 end = toClipSpace3(position+dir*rayLength) ;
	vec3 direction = end-clipPosition ;  //convert to clip space

	float len = max(abs(direction.x)/texelSize.x,abs(direction.y)/texelSize.y)/stepSize;
	//get at which length the ray intersects with the edge of the screen
	vec3 maxLengths = (step(0.,direction)-clipPosition) / direction;
	float mult = min(min(maxLengths.x,maxLengths.y),maxLengths.z)*2000.0;

	vec3 stepv = direction/len;

	int iterations = min(int(min(len, mult*len)-2), maxSteps);

	vec3 spos = clipPosition*vec3(RENDER_SCALE,1.0);// + stepv*noise;
	spos.xy += TAA_Offset*texelSize*0.5*RENDER_SCALE;

	float minZ = spos.z;
	float maxZ = spos.z;

  	for(int i = 0; i < iterations; i++){
		if (spos.x < 0.0 || spos.y < 0.0 || spos.z < 0.0 || spos.x > 1.0 || spos.y > 1.0 || spos.z > 1.0) return vec3(1.1);
		
		#ifdef UseQuarterResDepth
			float sp = invLinZ(sqrt(texelFetch2D(colortex4,ivec2(spos.xy/ texelSize/4),0).w/65000.0));
		#else
			float sp = texelFetch2D(depthtex1,ivec2(spos.xy/texelSize),0).r;
		#endif

		float currZ = linZ(spos.z);
		float nextZ = linZ(sp);

		if(nextZ < currZ && (sp <= max(minZ,maxZ) && sp >= min(minZ,maxZ))) return vec3(spos.xy/RENDER_SCALE,sp);
		
		float biasamount = 0.00005;

		minZ = maxZ-biasamount / currZ;
		maxZ += stepv.z;

		spos += stepv*(noise*0.25+0.75);

	}
	return vec3(1.1);
}

vec3 ApplySSRT(
	in vec3 unchangedIndirect,
	in vec3 blockLightColor,
	in vec3 minimumLightColor,

	vec3 viewPos,
	vec3 normal,
	vec3 noise,

	float lightmap, 

	bool isGrass,
	bool isLOD
){
	int nrays = RAY_COUNT;

	vec3 radiance = vec3(0.0);
	vec3 occlusion = vec3(0.0);
	vec3 skycontribution = unchangedIndirect;

	vec3 radiance2 = vec3(0.0);
	vec3 occlusion2 = vec3(0.0);
	vec3 skycontribution2 = unchangedIndirect;

	vec3 bouncedLight = vec3(0.0);
	for (int i = 0; i < nrays; i++){
		int seed = (frameCounter%40000)*nrays+i;
		vec2 ij = fract(R2_samples(seed) + noise.xy);
		vec3 rayDir = TangentToWorld(normal, normalize(cosineHemisphereSample(ij)), lightmap);

		#ifdef HQ_SSGI
			vec3 rayHit = rayTrace_GI( mat3(gbufferModelView) * rayDir, viewPos, noise.z, 50.); // ssr rt
		#else
			vec3 rayHit = RT_alternate(mat3(gbufferModelView)*rayDir, viewPos, noise.z, 10., isLOD);  // choc sspt 
		#endif

		// The block light must NOT ride in skycontribution.
		//
		// It used to, as `... + blockLightColor` on both lines below. That put
		// the same value into both accumulators: `radiance += skycontribution`
		// runs for every ray, and `occlusion += skycontribution` runs for every
		// ray that hits geometry, and the return is (radiance - occlusion)/nrays.
		// So the block term cancelled in proportion to how enclosed the scene is -
		// fully in the open, nothing at all in a room, which is the only place a
		// torch is used. A torch in a cave contributed exactly nothing, and
		// outdoors it was scaled by the fraction of rays that missed geometry.
		//
		// It belongs outside this function entirely: it is the volume's own answer
		// for this pixel, not a per-ray sample, and it has already been added to
		// Indirect_lighting by the caller. It is added back below, after the
		// accumulators have been differenced.
		#ifdef SKY_CONTRIBUTION_IN_SSRT
			#ifdef OVERWORLD_SHADER
				skycontribution = doIndirectLighting(pow(skyCloudsFromTexLOD(rayDir, colortex4, 0).rgb/30.0, vec3(0.7)) * 2.5, minimumLightColor, lightmap);
			#else
				skycontribution = pow(skyCloudsFromTexLOD2(rayDir, colortex4, 6).rgb / 30.0, vec3(0.7));
			#endif
		#else
			#ifdef OVERWORLD_SHADER
				skycontribution = unchangedIndirect  * (max(rayDir.y,pow(1.0-lightmap,2))*0.95+0.05);
			#endif
		#endif

		radiance += skycontribution;
		radiance2 += skycontribution2;

		if (rayHit.z < 1.0){
			#if indirect_effect == 4
				vec3 previousPosition = mat3(gbufferModelViewInverse) * toScreenSpace(rayHit) + gbufferModelViewInverse[3].xyz + cameraPosition-previousCameraPosition;
				previousPosition = mat3(gbufferPreviousModelView) * previousPosition + gbufferPreviousModelView[3].xyz;
				previousPosition.xy = projMAD(gbufferPreviousProjection, previousPosition).xy / -previousPosition.z * 0.5 + 0.5;

				if (previousPosition.x > 0.0 && previousPosition.y > 0.0 && previousPosition.x < 1.0 && previousPosition.y < 1.0){
					// The y bound was missing: the test read
					// `previousPosition.x < 1.0` twice. A reprojected point below the
					// screen therefore passed and sampled off the edge of the target,
					// which returns whatever the sampler clamps to - the top or bottom
					// row of the frame. Light on a wall in the lower half of the
					// screen could come from the sky at the top of it.
					//
					// The previous frame's position for a ray a few metres away is
					// only good if the camera barely moved. On a fast turn it can be
					// metres off, and the bounce then arrives from entirely the wrong
					// part of the scene - the coloured smearing this option has always
					// been known for, and the reason the pack shipped on
					// indirect_effect 3. Fading the bounce out on camera motion costs
					// it exactly when the reprojection cannot be trusted and keeps it
					// everywhere the camera is still, which is where someone stops to
					// look at a scene.
					float camDelta = length(cameraPosition - previousCameraPosition);
					float trust = 1.0 - smoothstep(0.05, 0.5, camDelta);
					//
					// colortex5, and deliberately not colortex3.
					//
					// A trap worth writing down. colortex3 is what the lighting pass
					// writes and what composite5.fsh reads as "the current frame", so
					// it looks like the lit scene. It is not, by the time this runs:
					// dimensions/composite.fsh runs immediately before the lighting
					// pass and overwrites colortex3 with the variable-penumbra shadow
					// buffer - minshadowfilt, average depth, blocker count. Reading it
					// from inside the lighting pass yields that, and adding it to the
					// indirect term is nonsense that presents as a wildly over-bright,
					// wrongly-tinted bounce.
					//
					// colortex5 is the TAA resolve's output: the previous frame's lit
					// scene, which is what a bounce wants. It is 10-bit and dithered,
					// but the dither is half a code value and it is averaged over
					// RAY_COUNT rays and the TAA blend on top of that, so it does not
					// survive into the result as noise.
					bouncedLight = texture2D(colortex5, previousPosition.xy).rgb * GI_Strength * trust;

					radiance += bouncedLight;
					radiance2 += bouncedLight;
				}
			#endif

			occlusion += skycontribution;
			occlusion2 += skycontribution2;
		}
	}

	// The block light goes back in here, once, after the accumulators have been
	// differenced. See the note where it was taken out: inside the loop it was
	// added to both sides of the subtraction and cancelled, so a torch lit
	// nothing in a room and was scaled down outdoors.
	//
	// It is the same value the caller already added to Indirect_lighting before
	// calling, and this function's result replaces that - see composite1.fsh,
	// where `Indirect_lighting = ApplySSRT(...)`. So it is added here once
	// rather than left to the caller, which would mean it was counted nowhere.
	if(isLOD) return max(radiance/nrays, 0.0) + blockLightColor;

	#ifdef SKY_CONTRIBUTION_IN_SSRT
		return max((radiance - occlusion)/nrays,0.0) + blockLightColor;
	#else
		float threshold = isGrass ? 0.8 : (pow(1.0-lightmap,2.0) * 0.9 + 0.1);
		return max((radiance - occlusion)/nrays, (radiance2 - occlusion2)/nrays * threshold) + blockLightColor;
	#endif

}