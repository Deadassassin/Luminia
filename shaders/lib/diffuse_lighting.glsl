#ifdef IS_LPV_ENABLED
    // The per-block light and tint table. This used to be read out of a 1D
    // storage image, which this engine cannot bind, and which the pass that
    // populated it never ran anyway - so a held light was being lit with
    // whatever the buffer happened to contain. It is a function of the id now.
    #include "/lib/lpv_blocks.glsl"

    vec3 GetHandLight(const in int itemId, const in vec3 playerPos, const in vec3 normal) {
        vec3 lightFinal = vec3(0.0);
        vec3 lightColor = vec3(0.0);
        float lightRange = 0.0;

        vec4 lightColorRange = unpackUnorm4x8(ptBlockLightData(itemId).r);
        lightColor = srgbToLinear(lightColorRange.rgb);
        lightRange = lightColorRange.a * 255.0;

        if (lightRange > 0.0) {
            float lightDist = length(playerPos);
            vec3 lightDir = playerPos / lightDist;
            float NoL = 1.0;//max(dot(normal, lightDir), 0.0);
            float falloff = pow(1.0 - lightDist / lightRange, 3.0);
            lightFinal = lightColor * NoL * max(falloff, 0.0);
        }

        return lightFinal;
    }
#endif

vec3 doBlockLightLighting(
    vec3 lightColor, float lightmap, float exposureValue,
    vec3 playerPos, vec3 lpvPos
){

    float lightmapCurve = pow(1.0-sqrt(1.0-clamp(lightmap,0.0,1.0)),2.0) * 2.0;
    
    vec3 blockLight = lightColor * lightmapCurve; //;
    
    // The volume's contribution to block light.
    //
    // This used to read
    //     #if defined IS_LPV_ENABLED && defined MC_GL_EXT_shader_image_load_store
    // and the second half of that can never be true on this engine. Its macro
    // set is MC_GL_VERSION, MC_GL_VENDOR_* and MC_GL_RENDERER_*; there is no
    // MC_GL_EXT_shader_image_load_store in it, and nothing in the pack defines
    // it either. So the condition was always false and the volume was never
    // sampled here, however live it was.
    //
    // It was redundant besides. IS_LPV_ENABLED is itself `#ifdef LPV_ENABLED`
    // plus `#ifdef IRIS_FEATURE_CUSTOM_IMAGES`, and "can I read a custom image"
    // is exactly what that second flag means. The engine does provide it - it
    // is in EngineDefines - and the volumes are bound: the engine lists
    // texLpv1 and texLpv2 among the samplers the chain reads, and allocates both
    // as RGBA8 256x256x256 storage volumes.
    #if defined IS_LPV_ENABLED
        vec4 lpvSample = SampleLpvLinear(lpvPos);
        vec3 lpvBlockLight = GetLpvBlockLight(lpvSample);

        // create a smooth falloff at the edges of the voxel volume.
        float fadeLength = 10.0; // in meters
        vec3 cubicRadius = clamp( min(((LpvSize3-1.0) - lpvPos)/fadeLength,      lpvPos/fadeLength) ,0.0,1.0);
        float voxelRangeFalloff = cubicRadius.x*cubicRadius.y*cubicRadius.z;
        voxelRangeFalloff = 1.0 - pow(1.0-pow(voxelRangeFalloff,1.5),3.0);
        
        // outside the voxel volume, lerp to vanilla lighting as a fallback
        blockLight = mix(blockLight, lpvBlockLight/5.0, voxelRangeFalloff);

        #ifdef Hand_Held_lights
            // create handheld lightsources
            const vec3 normal = vec3(0.0); // TODO

                if (heldItemId > 0)
                blockLight += GetHandLight(heldItemId, playerPos, normal);

                if (heldItemId2 > 0)
                blockLight += GetHandLight(heldItemId2, playerPos, normal);
        #endif
    #endif

    // try to make blocklight have consistent visiblity in different light levels.
    float autoBrightness = mix(1.0, 30.0,  clamp(exp(-10.0*exposureValue),0.0,1.0));
    blockLight *= autoBrightness;
    
    return blockLight * TORCH_AMOUNT;
}

vec3 doIndirectLighting(
    vec3 lightColor, vec3 minimumLightColor, float lightmap
){

    float lightmapCurve = (pow(lightmap,15.0)*2.0 + pow(lightmap,2.5))*0.5;

    vec3 indirectLight = lightColor * lightmapCurve * ambient_brightness * 0.7; 

    // The floor is light with no source, so it answers to ambient_brightness like
    // every other such term. It did not, and that is why turning the ambient
    // slider down left unlit ground still glowing: this was the one addition to
    // Indirect_lighting that no option reached.
    //
    // The translucent path already scales its own floor this way -
    // fogBehindTranslucent_pass.fsh does `indirectLightColor_dynamic *=
    // ambient_brightness * ...` - so this makes the two agree rather than
    // inventing a convention.
    //
    // Only the floor term is scaled. Night vision is a deliberate
    // see-in-the-dark effect rather than ambient, and darkening the world should
    // not also remove the ability to see in it.
    //
    // At the default ambient_brightness of 1.0 this is term-for-term identical to
    // what it replaced, so nothing changes until the slider is turned down.
    // MIN_LIGHT_AMOUNT still decides how much floor there is - take it to 0.0 to
    // have none at all, which is what "no light source, no light" means.
    vec3 ambientFloor = minimumLightColor * MIN_LIGHT_AMOUNT * 0.01 * ambient_brightness;
    indirectLight += max(ambientFloor, minimumLightColor * nightVision * 0.1);

    return indirectLight;
}