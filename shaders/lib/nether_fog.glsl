// The nether's own biome environment.
//
// This file is included by deferred.fsh, composite2.fsh and
// fogBehindTranslucent_pass.fsh, and only the first of those has
// lib/climate_settings.glsl in scope by the time it gets here - the other two
// reach it more directly. So the uniform is declared here, guarded by a macro,
// rather than relying on an include order that is not the same in all three.
// Redeclaring a uniform that is already in scope is legal GLSL as long as the
// types agree, but the guard makes it unambiguous and keeps the three passes
// compiling the same expression either way.
#ifndef LUMINA_NETHER_FOG_UNIFORMS
#define LUMINA_NETHER_FOG_UNIFORMS
	uniform float isNether;
#endif

float densityAtPosFog(in vec3 pos){
	pos /= 18.;
	pos.xz *= 0.5;

	vec3 p = floor(pos);
	vec3 f = fract(pos);

	f = (f*f) * (3.-2.*f);
	vec2 uv =  p.xz + f.xz + p.y * vec2(0.0,193.0);
	vec2 coord =  uv / 512.0;
	vec2 xy = texture2D(noisetex, coord).yx;
	return mix(xy.r,xy.g, f.y);
}

float cloudVol(in vec3 pos){
	vec3 samplePos = pos*vec3(1.0,1./48.,1.0);

    float Wind = pow(max(pos.y-30,0.0) / 15.0,2.1);

	float Plumes = texture2D(noisetex, (samplePos.xz + Wind)/256.0).b;
	float floorPlumes = clamp(0.3 - exp(Plumes * -6),0,1);
	Plumes *= Plumes;

	float Erosion = densityAtPosFog(samplePos * 400	- frameTimeCounter*10 - Wind*10) *0.7+0.3 ;

    float RoofToFloorDensityFalloff = exp(max(100-pos.y,0.0) / -15);
	float FloorDensityFalloff = pow(exp(max(pos.y-31,0.0) / -3.0),2);
	float RoofDensityFalloff = exp(max(120-pos.y,0.0) / -10);

	float Output = max((RoofToFloorDensityFalloff - Plumes * (1.0-Erosion)) * 2.0,	clamp((FloorDensityFalloff - floorPlumes*0.5) * Erosion ,0.0,1.0) );
    
	return Output;
}

vec4 GetVolumetricFog(
	vec3 viewPosition,
	float dither,
	float dither2
){
	#ifndef TOGGLE_VL_FOG
		return vec4(0.0,0.0,0.0,1.0);
	#endif

	/// -------------  RAYMARCHING STUFF ------------- \\\

	int SAMPLECOUNT = 16;

	vec3 wpos = mat3(gbufferModelViewInverse) * viewPosition + gbufferModelViewInverse[3].xyz;
	vec3 dVWorld = (wpos-gbufferModelViewInverse[3].xyz);
	vec3 progressW = vec3(0.0);

	float maxLength = min(length(dVWorld), min(far, 12*16))/length(dVWorld);

	dVWorld *= maxLength;

	float dL = length(dVWorld);

	float expFactor = 11.0;
	
	/// -------------  COLOR/LIGHTING STUFF ------------- \\\

	vec3 color = vec3(0.0);
	float absorbance = 1.0;

	vec3 hazeColor = normalize(gl_Fog.color.rgb);
	
	// The nether biome environment, applied once outside the march.
	//
	// isNether is 1 in any nether biome and 0 everywhere else, so this whole block
	// compiles away to nothing overworld without needing a dimension #ifdef - which
	// matters, because the plume/haze/ceiling code below it is shared and this is
	// the only nether-specific thing in it.
	//
	// NETHER_STORM_DENSITY scales the plume, haze and ceiling together, because in
	// the nether they are all the same overcast: there is no weather to vary them
	// independently. It is a density, so it multiplies; a value above 1 thickens
	// the nether and can be pushed further than a colour can.
	//
	// The RGB is a TINT, not a replacement colour. It is multiplied into the plume
	// lighting, so with the default of (1.0, 0.4, 0.2) left alone nothing changes -
	// which is the point. Setting all three to 1.0 turns the nether's orange
	// overcast grey and is the fastest way to see that this is wired up at all.
	float netherDensity = mix(1.0, NETHER_STORM_DENSITY, isNether);
	vec3 netherTint = mix(vec3(1.0), vec3(NETHER_STORM_R, NETHER_STORM_G, NETHER_STORM_B), isNether);
	
	#if defined LPV_VL_FOG_ILLUMINATION && defined EXCLUDE_WRITE_TO_LUT
    	float TorchBrightness_autoAdjust = mix(1.0, 30.0,  clamp(exp(-10.0*exposure),0.0,1.0)) / 5.0;
	#endif

	for (int i = 0; i < SAMPLECOUNT; i++) {
		float d = (pow(expFactor, float(i+dither)/float(SAMPLECOUNT))/expFactor - 1.0/expFactor)/(1-1.0/expFactor);
		float dd = pow(expFactor, float(i+dither)/float(SAMPLECOUNT)) * log(expFactor) / float(SAMPLECOUNT)/(expFactor-1.0);
		
		progressW = gbufferModelViewInverse[3].xyz + cameraPosition + d*dVWorld;

		float densityVol = cloudVol(progressW);
		float clearArea = 1.0 - min(max(1.0 - length(progressW - cameraPosition) / 24.0,0.0),1.0);

		//------ PLUME EFFECT
			float plumeDensity = min(densityVol * pow(min(max(100.0-progressW.y,0.0)/30.0,1.0),4.0), pow(clamp(1.0 - length(progressW-cameraPosition)/far,0.0,1.0),5.0));
			plumeDensity *= NETHER_PLUME_DENSITY * netherDensity;
			float plumeVolumeCoeff = exp(-plumeDensity*dd*dL);

			// The (1.0, 0.4, 0.2) is the nether's own overcast colour and is kept
			// explicit rather than folded into netherTint, so that a pack setting the
			// tint to white gets a NEUTRAL overcast and not the nether's orange one.
			vec3 lighting = vec3(1.0,0.4,0.2) * netherTint * exp(-15.0*densityVol) * (clearArea*clearArea*0.9+0.1);

			color += (lighting - lighting * plumeVolumeCoeff) * absorbance;
			absorbance *= plumeVolumeCoeff;

		//------ HAZE EFFECT
			// dont make haze contrube to absorbance.
			float hazeDensity = 0.001;
			#ifndef ReflectedFog
				hazeDensity *= NETHER_HAZE_DENSITY * netherDensity;
			#endif
			float hazeVolumeCoeff = exp(-hazeDensity*dd*dL);
			
			vec3 hazeLighting = hazeColor * netherTint;
			
			color += (hazeLighting - hazeLighting*hazeVolumeCoeff) * absorbance;

		//------ CEILING SMOKE EFFECT
			float ceilingSmokeDensity = 0.001 * pow(min(max(progressW.y-40.0,0.0)/50.0,1.0),3.0);
			ceilingSmokeDensity *= NETHER_CEILING_SMOKE_DENSITY * netherDensity;
			float ceilingSmokeVolumeCoeff = exp(-ceilingSmokeDensity*dd*dL);
			
			// Left white rather than tinted. The ceiling is already a near-white
			// overcast and it is what you see against, so tinting it toward the fog
			// colour would just mute the whole sky without changing the fog.
			vec3 ceilingSmoke = vec3(1.0);

			color += (ceilingSmoke - ceilingSmoke*ceilingSmokeVolumeCoeff) * (absorbance*0.5+0.5);
			absorbance *= ceilingSmokeVolumeCoeff;

		//------ LPV FOG EFFECT
			#if defined LPV_VL_FOG_ILLUMINATION && defined EXCLUDE_WRITE_TO_LUT
				color += LPV_FOG_ILLUMINATION(progressW-cameraPosition, dd, dL) * TorchBrightness_autoAdjust * absorbance;
			#endif

	}
	return vec4(color, absorbance);
}