// Auroras, after nimitz 2017 - https://www.shadertoy.com/view/XtGGRt
// License: Creative Commons Attribution-NonCommercial-ShareAlike 3.0 Unported
// Contact the author for other licensing options.
//
// Ported from Eclipse's lib/aurora.glsl. The maths is theirs and unchanged; the
// uniforms, the two call sites and the settings screen are this pack's. See the
// note at the foot of this file for what had to change and why.
//
// ---------------------------------------------------------------------------
// WHY IT IS CALLED TWICE, OR AT ALL
//
// The original walks a volume of atmosphere in N steps per pixel and accumulates
// an emission curve. Two details make it affordable:
//
//   * the sample STRIDE grows polynomially with the step index, so the far,
//     high-altitude part of the volume is sampled sparsely. That works because
//     the aurora's upper reaches are lower opacity than its base.
//   * each step blends into a running average (avgCol = mix(avgCol, col2, 0.1))
//     rather than accumulating independently, which is what removes the banding
//     you would otherwise see at low sample counts.
//
// Both survive the port. What did not survive is the call site: Eclipse renders
// this twice, once into its sky buffer in prepare4 and once over the composited
// scene in composite4, because its two locations (a sky-only pass and a
// behind-translucents pass) need different amounts of it. This pack has one sky
// write - composite1.fsh's `Background` - so there is one call, and AURORA_GAIN
// below carries the scale that the second call site used to provide.
// ---------------------------------------------------------------------------

float hash_aurora(float p)
{
	p = fract(p * .1031);
	p *= p + 33.33;
	p *= p + p;
	return fract(p);
}

mat2 mm2(in float a) {
    float c = cos(a), s = sin(a);
    return mat2(c, s, -s, c);
}

const mat2 m2 = mat2(0.95534, 0.29552, -0.29552, 0.95534);

float tri(in float x) {
    return clamp(abs(fract(x) - 0.5), 0.01, 0.49);
}

vec2 tri2(in vec2 p) {
    float triX = tri(p.x);
    float triY = tri(p.y);
    return vec2(triX + triY, tri(triX + p.y));
}

// The band structure. Three octaves of gradient noise, each one rotating and
// warping the next, folded with a triangle wave so the result has the hard-ish
// edges that give an aurora its curtain look rather than a cloud's soft one.
float triNoise2d(in vec2 p) {
    float z = 1.8;
    float z2 = 2.5;
    float rz = 0.0;
    p *= mm2(p.x * 0.06);
    vec2 bp = p;
    mat2 rotation = mm2(frameTimeCounter * 0.06);
    
    for (int i = 0; i < 3; i++) {
        vec2 dg = tri2(bp * 1.75) * 0.75;
        dg *= rotation;
        p -= dg / z2;

        bp *= 1.3;
        z2 *= 0.45;
        z *= 0.42;
        p *= 1.21 + (rz - 1.0) * 0.02;
        
        rz += tri(p.x + tri(p.y)) * z;
        p *= -m2;
    }
    return clamp(1.0 / pow(rz * 29.0, 1.6), 0.0, 0.55);
}

// dir          view direction, world space, normalised
// samples      steps through the volume
// noise        per-pixel dither, decorrelates the banding between pixels
// WmoonVecY    moon elevation, for the "only when the moon is down" option
// WsunVecY     sun elevation - the aurora is always gated on this being negative
vec3 aurora(vec3 dir, int samples, float noise, float WmoonVecY, float WsunVecY) {
    vec3 col = vec3(0.0);
    vec3 avgCol = vec3(0.0);
    float hash = 0.05 * noise;
    float fade = dir.y * 2.0 + 0.4;

    float atmosphereGround = 1.0 - exp2(-50.0 * pow(clamp(dir.y+0.025,0.0,1.0),2.0));

    // Step stride. 6.0 where the caller composites over an already-lit scene, 3.0
    // where it goes straight into a sky buffer. Lumina has one call site and it
    // writes Background before the clouds are composited over it, so 3.0 is the
    // right side of that choice and the second site is gone - see AURORA_GAIN.
    const float mult = 3.0;
    
    for (int i = 0; i < samples; i++) {
        float mI = mult * float(i);
        float of = hash * smoothstep(0.0, 12.0, mI);
        // The growing stride: (mI^1.4) is what makes this cheap at the top of the
        // atmosphere, where the sample positions spread out superlinearly.
        float pt = (0.8 + pow(mI, 1.4) * 0.0016) / fade - of;
        vec3 bpos = pt * dir;
        float rzt = triNoise2d(bpos.zx);
        vec3 col2 = vec3(0.0, 0.0, 0.0);
        // The RGB options are PHASE OFFSETS into a sine, not colour channels -
        // that is why Eclipse's defaults are 2.25 / -0.5 / 1.2 and go negative,
        // and why they are not "red 0.9, green 1.0, blue 0.8". A phase spread of
        // this size is what walks the emission through green into magenta over
        // the height of the curtain. Set them all equal and the aurora is a flat
        // single colour; that is a legitimate look, not a mistake.
        col2 = (sin(vec3(AURORA_R, AURORA_G, AURORA_B) + mI * 0.063) * 0.5 + 0.5) * rzt;
        avgCol = mix(avgCol, col2, 0.1);
        col += avgCol * exp2(-mI * 0.05 - 2.5);
    }

    // The 1.45 gamma is what makes the base of a curtain bright and its top
    // faint, rather than the whole thing being uniformly dim.
    vec3 auroraCol = 14.5*pow(col, vec3(1.45));

    #ifdef AURORA_MOON
        // Moon below the horizon, i.e. WmoonVecY near 0 and falling. A rising
        // moon brightens the sky the aurora sits in, and an aurora against a
        // moonlit sky reads as fog rather than as emission.
        auroraCol *= smoothstep(0.1, 0.0, WmoonVecY);
    #endif

    // Always below the horizon. 0 at sunset and -1 at midnight, so this is a
    // fade-in through dusk rather than a hard cut.
    auroraCol *= smoothstep(0.0, -0.1, WsunVecY);

    return auroraCol * atmosphereGround * AURORA_BRIGHTNESS * AURORA_GAIN;
}

// ---------------------------------------------------------------------------
// WHEN IT SHOWS: the day gate, decoupled from the biome.
//
// Eclipse drives this from shaders.properties with
//
//     uniform.float.auroraAmount = smooth(if(biome_precipitation == 2, 1.0, 0.0), ...)
//
// which makes the aurora a snow-biome effect - and a badlands or a savanna, which
// report no precipitation at all, could never see one. That is the pack author's
// choice and a defensible one, but it is also an odd coupling: a magnetic display
// has nothing to do with whether it is hailing.
//
// So it is separated here. AURORA_CHANCE is the percentage of days it appears at
// all, and the biome is no longer consulted:
//
//     hash_aurora(float(worldDay)) <= 0.01 * float(AURORA_CHANCE)
//
// which is a stable per-day roll - the same worldDay gives the same answer all
// day, so it does not flicker, and it is a different day tomorrow. Note the
// hash: a plain fract(worldDay * k) would repeat on a short period, and the
// periods of the usual fract constants are small enough to be visible over a few
// hundred days.
//
// The roll is on the DAY, so an aurora that appears lasts the whole night rather
// than blinking - which is both cheaper and what an aurora does.
float auroraTonight() {
    #if AURORA_CHANCE >= 100
        return 1.0;
    #else
        return hash_aurora(float(worldDay)) <= 0.01 * float(AURORA_CHANCE) ? 1.0 : 0.0;
    #endif
}
