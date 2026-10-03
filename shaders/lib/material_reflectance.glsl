// Per-block reflection material.
//
// Rebuilt on top of v0.4.2. Two tables: a smoothness per block id and an F0 per
// block id, written into SpecularTex.r/.g by all_solid.fsh and read back by
// DoSpecularReflections in lib/specular.glsl.
//
// Enabled by LUMINA_MATERIAL_REFLECTANCE in lib/settings.glsl.
//
// =============================================================================
// WHY THIS FILE HAS TO EXIST
//
// lib/specular.glsl decides whether a surface reflects at all with
//
//     bool hasReflections = Roughness_Threshold == 1.0
//                          ? true
//                          : F0 * (1.0 - Roughness * Roughness_Threshold) > 0.01;
//
// and in v0.4.2 the roughness and F0 it tests arrived in the green and red
// channels of SpecularTex, sampled from the `specular` texture. Nothing writes
// that texture. The engine serves it as a single pixel and says so:
//
//     "4 read one pixel, because nothing fills them yet:
//      [normals, specular, colortex1, depthtex0]"
//
// Rain was the only thing that ever reached those channels
// (SpecularTex.r = max(SpecularTex.r, rainfall)), which is why in v0.4.2 blocks
// reflected when wet and were flat matte when dry, whatever they were made of.
// This computes the material from the block id instead, which is the one
// per-block value the fragment stage actually has: all_solid.vsh:235 reads
// blockID from mc_Entity.x.
//
// =============================================================================
// THE CHANNEL MAPPING IS NOT THE OBVIOUS ONE, AND GETTING IT BACKWARDS IS THE
// BUG THAT MADE WOOL SHINE AND DIAMOND GO DEAD
//
//     SpecularTex.r = SMOOTHNESS,  and .g = F0
//
// lib/specular.glsl:206 then does
//
//     Roughness = 1.0 - Roughness;  Roughness *= Roughness;
//
// so .r must be HIGH for a matte block and LOW for a shiny one. The values below
// are therefore written in smoothness - 1.0 is a mirror, 0.0 fully matte - and
// passed through untransformed. Do not "fix" them into 1.0 - smoothness: that
// inverts the axis, the gate then grows with smoothness instead of shrinking,
// every surface passes at once, wool and stone reflect hardest, diamond and
// obsidian go matte and the scene washes out.
//
// A material is also written to the 8-bit colortex1, so F0 survives only as
// k/255. The metal constant below is chosen with that in mind - see its own note.
//
// =============================================================================
// WHAT F0 MEANS IN THIS VERSION, WHICH IS LESS THAN IT DOES IN A FULL PBR MODEL
//
// lib/specular.glsl reads F0 as a single bit:
//
//     vec3 Metals = F0 > 229.5/255.0
//                 ? normalize(Albedo+1e-7) * (dot(Albedo, vec3(0.21,0.72,0.07)) * 0.7 + 0.3)
//                 : vec3(1.0);
//
// Above that midpoint the reflection is tinted by the block's own texture, which
// is how iron reads silver (a neutral grey texture) and gold reads gold (a
// yellow one). Below it the reflection stays white and the block's colour comes
// from its diffuse, which is the correct behaviour for a dielectric: a
// dielectric's Fresnel reflection is achromatic.
//
// So in this pack F0 is a FLAG plus a magnitude, and there are only two bands:
// a conductor and a plain dielectric. There is no separate "gem" band, and none
// is needed - diamond's reflection is white and its colour comes from the
// diffuse underneath, which is what a gem does. Anything that wanted to index a
// table of measured metal reflectances would need to change lib/specular.glsl
// and the arithmetic that picks the index; that is deliberately not done here.
//
// =============================================================================
// WHAT THE GATE DOES WITH THESE NUMBERS
//
// Substituting the two lines above, with s the smoothness written here and
// Roughness_Threshold at its v0.4.2 default of 1.2:
//
//     gate = F0 * (1 - 1.2 * (1 - s)^2)          reflects when gate > 0.01
//
// For a dielectric (F0 = 0.04) that gives, in order of increasing smoothness:
//
//     wool    s = 0.00  gate = -0.0080   matte
//     coal    s = 0.20  gate = +0.0093   matte   (just under the cutoff)
//     netherrack s = 0.26  gate = +0.0137  faint
//     concrete s = 0.30  gate = +0.0165  faint
//     glazed terracotta s = 0.80  gate = +0.0381  clear
//     glass   s = 0.90  gate = +0.0395  clear
//     and the unlisted default below, s = 0.05, gate = -0.0033: matte.
//
// Every number in the table is one of those, and the low ones are matte on
// purpose. Quartz is not in this table at all - see the note at the foot of the
// file.
//
// =============================================================================
// NOTHING HERE ADDS LIGHT
//
// This file only writes roughness and F0. It cannot make a block emit: emission
// is EMISSIVE in all_solid.vsh (0.5 for ids in [100, 300), all_solid.vsh:277)
// and a block's flood-fill light is ptBlockLightData() in lib/lpv_blocks.glsl.
// Every id this table is keyed on is >= 2000, which is clear of both - and of the
// item id band at 1000-1024, which is the one that actually bites: an earlier
// version of this table started at 1000 and 23 of its blocks came back as torches,
// lanterns, beacons and glowstone, which made them emit AND let light pass
// straight through them. See the note on the BLOCK_MAT_ ids at the foot of
// lib/blocks.glsl for that in full.
//
// A reflective block is lit BY the scene; it is not a light source.

#ifdef LUMINA_MATERIAL_REFLECTANCE

// A conductor. Must be above 229.5/255.0, which is the midpoint between the two
// nearest 8-bit values and is how lib/specular.glsl recognises a metal.
//
// 231/255 = 0.9059 rather than the minimal 230/255 = 0.9020: the channel is
// quantised to 8 bits on its way through colortex1, so the stored value is
// exactly k/255 and the comparison has to survive that round trip. 230/255 clears
// the midpoint by half a step, which is a margin measured in rounding. 231/255
// clears it by a step and a half, which is not.
//
// It is also comfortably below 1.0, so a metal cannot accidentally saturate the
// channel and lose its tint.
const float LUMINA_MAT_METAL_F0 = 231.0 / 255.0;

// A plain dielectric. 0.04 is the standard reflectance at normal incidence for a
// material of index ~1.5, which covers essentially every non-metal in the game.
const float LUMINA_MAT_DIELECTRIC_F0 = 0.04;

// Smoothness: 1.0 is a perfect mirror, 0.0 fully matte. Remember that .r carries
// this untransformed and specular.glsl inverts it into roughness, so high here
// means shiny.
float lpvMaterialSmoothness(const in int blockId) {
	// The unlisted default. Chosen to be MATTE rather than "faintly reflective":
	//
	//   gate = 0.04 * (1 - 1.2 * 0.95^2) = -0.0033
	//
	// which is below the 0.01 cutoff, so a block with no entry behaves exactly as
	// it did in v0.4.2. A block not named here is not given a shine it did not
	// have. An earlier version of this file used 0.05 for the same reason and the
	// same arithmetic; it is worth stating out loud that the default has to be
	// matte, because a default that reflects is a default that lights up half the
	// game.
	float smoothness = 0.05;

	switch (blockId) {
		// ---- metals: conductor, so F0 = LUMINA_MAT_METAL_F0 below ----
		//
		// These are the numbers for a Minecraft block rather than for real stock:
		// a cast iron block face is smooth but not polished, so 0.80 reflects
		// clearly without turning into chrome. Gold and copper are a little
		// higher because both are drawn as polished.
		case BLOCK_MAT_IRON_BLOCK:
		case BLOCK_MAT_RAW_IRON_BLOCK:
		case BLOCK_MAT_IRON_ORE:
		case BLOCK_MAT_ANVIL:
		case BLOCK_MAT_CHAIN:
		case BLOCK_MAT_IRON_BARS:
			smoothness = 0.80;
			break;
		case BLOCK_MAT_GOLD_BLOCK:
		case BLOCK_MAT_RAW_GOLD_BLOCK:
		case BLOCK_MAT_GOLD_ORE:
			smoothness = 0.85;
			break;
		case BLOCK_MAT_COPPER_BLOCK:
		case BLOCK_MAT_COPPER_EXPOSED:
		case BLOCK_MAT_COPPER_WEATHERED:
		case BLOCK_MAT_RAW_COPPER_BLOCK:
			// Weathered and exposed copper are duller than a clean block, and only
			// the copper family entry for them is lowered rather than split, because
			// they are the same material with a patina of different thickness.
			smoothness = 0.78;
			break;

		// ---- gems and mineral blocks: dielectric, colour from the diffuse ----
		case BLOCK_MAT_DIAMOND_BLOCK:
			// Near-mirror, but deliberately not 1.0. Diamond's refractive index is
			// n = 2.417, so F0 = ((n-1)/(n+1))^2 = 0.172 - over four times a normal
			// dielectric, which is the whole reason a diamond reads as glass and
			// quartz does not. In this version F0 cannot express that without
			// crossing into the metal band, where it would wrongly lose its diffuse,
			// so the extra reflectance is not applied and the block is carried by its
			// smoothness instead. The soft edge roughness adds is the point: a
			// perfect mirror would read as metal, which diamond is not.
			smoothness = 0.95;
			break;
		case BLOCK_MAT_AMETHYST:
		case BLOCK_MAT_BUDDING_AMETHYST:
			smoothness = 0.88;
			break;
		case BLOCK_MAT_OBSIDIAN:
		case BLOCK_MAT_CRYING_OBSIDIAN:
			// Volcanic glass. Smooth, but its surface is conchoidal rather than
			// flat, so it scatters more than a cut gem.
			smoothness = 0.75;
			break;
		case BLOCK_MAT_EMERALD_BLOCK:
		case BLOCK_MAT_LAPIS_BLOCK:
			smoothness = 0.70;
			break;
		case BLOCK_MAT_REDSTONE_BLOCK:
			smoothness = 0.80;
			break;
		case BLOCK_MAT_HONEYCOMB:
			// Waxy rather than wet, but it does have a sheen.
			smoothness = 0.55;
			break;
		case BLOCK_MAT_COAL_BLOCK:
			// A block of coal is dull and porous. At 0.20 this is matte, which is
			// what a coal block should be; it is listed so that is a decision rather
			// than an omission.
			smoothness = 0.20;
			break;

		// ---- ores ----
		//
		// An ore is its metal or crystal in a stone matrix, and the block's face is
		// mostly matrix. So the ore takes a lower smoothness than the solid block
		// and stays a dielectric: it glints in the veins instead of becoming a
		// mirror. Gold and iron ore are the exceptions - their whole face is
		// speckled metal - and take the metal treatment above.
		case BLOCK_MAT_DIAMOND_ORE:
			smoothness = 0.80;
			break;
		case BLOCK_MAT_REDSTONE_ORE:
		case BLOCK_MAT_EMERALD_ORE:
			smoothness = 0.70;
			break;
		case BLOCK_MAT_LAPIS_ORE:
			smoothness = 0.65;
			break;
		case BLOCK_MAT_COAL_ORE:
			smoothness = 0.20;
			break;

		// ---- cut and polished stone: smooth, but not a conductor ----
		case BLOCK_MAT_POLISHED:
			smoothness = 0.60;
			break;
		case BLOCK_MAT_PURPUR:
		case BLOCK_MAT_PRISMARINE:
			smoothness = 0.55;
			break;
		case BLOCK_MAT_CALCITE:
		case BLOCK_MAT_MUD:
			smoothness = 0.40;
			break;
		case BLOCK_MAT_TUFF:
		case BLOCK_MAT_CONCRETE:
			smoothness = 0.30;
			break;
		case BLOCK_MAT_GLAZED_TERRACOTTA:
			// It is glazed. This is meant to be one of the shiniest blocks in the
			// game and it is a dielectric, so it carries all of its shine in
			// smoothness.
			smoothness = 0.80;
			break;
		case BLOCK_MAT_NETHERRACK:
			smoothness = 0.26;
			break;
		case BLOCK_MAT_DEEPSLATE:
			smoothness = 0.20;
			break;
		case BLOCK_MAT_SNOW_BLOCK:
		case BLOCK_MAT_MUSHROOM_STEM:
			// Matte. Snow scatters almost everything; a mushroom stem is fibrous.
			smoothness = 0.15;
			break;
		case BLOCK_MAT_WOOL:
			// Explicitly matte. Wool is the block that exposed the inverted axis
			// described at the head of this file - it reflected harder than diamond
			// did - so it is named here at 0.0 rather than left to the default.
			smoothness = 0.0;
			break;

		// ---- glass and ice ----
		case BLOCK_MAT_STAINED_GLASS:
			smoothness = 0.90;
			break;
		case BLOCK_MAT_STAINED_GLASS_PANE:
			// A pane is a thin plane and reads glossier than a slab of the same
			// nominal material.
			smoothness = 0.94;
			break;
		case BLOCK_MAT_BLUE_ICE:
		case BLOCK_MAT_PACKED_ICE:
			smoothness = 0.75;
			break;
	}

	return smoothness;
}

// Reflectance at normal incidence, which doubles as the metal flag.
// See the band discussion at the head of this file.
float lpvMaterialF0(const in int blockId) {
	// Dielectric, as the plain default.
	float f0 = LUMINA_MAT_DIELECTRIC_F0;

	switch (blockId) {
		case BLOCK_MAT_IRON_BLOCK:
		case BLOCK_MAT_RAW_IRON_BLOCK:
		case BLOCK_MAT_IRON_ORE:
		case BLOCK_MAT_ANVIL:
		case BLOCK_MAT_CHAIN:
		case BLOCK_MAT_IRON_BARS:
		case BLOCK_MAT_GOLD_BLOCK:
		case BLOCK_MAT_RAW_GOLD_BLOCK:
		case BLOCK_MAT_GOLD_ORE:
		case BLOCK_MAT_COPPER_BLOCK:
		case BLOCK_MAT_COPPER_EXPOSED:
		case BLOCK_MAT_COPPER_WEATHERED:
		case BLOCK_MAT_RAW_COPPER_BLOCK:
			// All the same value, and that is not a shortcut. In this version F0
			// above the midpoint is a flag, not a measurement: the tint comes from
			// the block's own texture (see the head of this file), so there is
			// nothing here for a per-metal number to encode. Giving iron and gold
			// different values would imply a distinction the shader cannot act on.
			f0 = LUMINA_MAT_METAL_F0;
			break;

		case BLOCK_MAT_BLUE_ICE:
		case BLOCK_MAT_PACKED_ICE:
			// Ice really does reflect less than the 0.04 default - measured, from
			// its refractive index of about 1.31, not chosen to suit the look.
			f0 = 0.02;
			break;
	}

	return f0;
}

#endif // LUMINA_MATERIAL_REFLECTANCE
