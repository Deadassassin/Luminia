// The render-stage numbers, as `renderStage` reports them.
//
// `renderStage` is the engine's `dev.vitrail.pack.model.RenderStage` ordinal, and
// that enum is Iris's list in Iris's order - NONE, SKY, SUNSET, CUSTOM_SKY, SUN,
// MOON, STARS, VOID, TERRAIN_SOLID, ... HAND_TRANSLUCENT - so the numbers below
// are that enum's, read out of it rather than guessed from Iris's documentation.
//
// Iris hands these to packs as macros. This engine supplies `renderStage` itself
// but not the macros, so a pack that tests them does not compile here. That is
// not theoretical: this file is the only place in the pack that uses them, and
// the shadow pass that includes it failed to compile with
//
//     'MC_RENDER_STAGE_TERRAIN_SOLID' : undeclared identifier
//
// the moment the call to PopulateShadowVoxel was enabled - which is the call that
// writes imgVoxelMask, without which the flood fill sees an empty volume and
// light passes through walls. So the constants belong here, next to their only
// user, rather than in a header every program has to include for them.
//
// All of them, not just the six used below, so that the next use does not have to
// come back here and count the enum again.
#define MC_RENDER_STAGE_NONE 0
#define MC_RENDER_STAGE_SKY 1
#define MC_RENDER_STAGE_SUNSET 2
#define MC_RENDER_STAGE_CUSTOM_SKY 3
#define MC_RENDER_STAGE_SUN 4
#define MC_RENDER_STAGE_MOON 5
#define MC_RENDER_STAGE_STARS 6
#define MC_RENDER_STAGE_VOID 7
#define MC_RENDER_STAGE_TERRAIN_SOLID 8
#define MC_RENDER_STAGE_TERRAIN_CUTOUT_MIPPED 9
#define MC_RENDER_STAGE_TERRAIN_CUTOUT 10
#define MC_RENDER_STAGE_ENTITIES 11
#define MC_RENDER_STAGE_BLOCK_ENTITIES 12
#define MC_RENDER_STAGE_DESTROY 13
#define MC_RENDER_STAGE_OUTLINE 14
#define MC_RENDER_STAGE_DEBUG 15
#define MC_RENDER_STAGE_HAND_SOLID 16
#define MC_RENDER_STAGE_TERRAIN_TRANSLUCENT 17
#define MC_RENDER_STAGE_TRIPWIRE 18
#define MC_RENDER_STAGE_PARTICLES 19
#define MC_RENDER_STAGE_CLOUDS 20
#define MC_RENDER_STAGE_RAIN_SNOW 21
#define MC_RENDER_STAGE_WORLD_BORDER 22
#define MC_RENDER_STAGE_HAND_TRANSLUCENT 23

ivec3 GetVoxelIndex(const in vec3 playerPos) {
	vec3 cameraOffset = fract(cameraPosition);
	return ivec3(floor(playerPos + cameraOffset) + VoxelSize3/2u);
}

void SetVoxelBlock(const in vec3 playerPos, const in uint blockId) {
	ivec3 voxelPos = GetVoxelIndex(playerPos);
	if (clamp(voxelPos, ivec3(0), ivec3(VoxelSize-1u)) != voxelPos) return;

	imageStore(imgVoxelMask, voxelPos, uvec4(blockId));
}

void PopulateShadowVoxel(const in vec3 playerPos) {
	uint voxelId = 0u;
	vec3 originPos = playerPos;

	if (
		renderStage == MC_RENDER_STAGE_TERRAIN_SOLID || renderStage == MC_RENDER_STAGE_TERRAIN_TRANSLUCENT ||
		renderStage == MC_RENDER_STAGE_TERRAIN_CUTOUT || renderStage == MC_RENDER_STAGE_TERRAIN_CUTOUT_MIPPED
	) {
		voxelId = uint(mc_Entity.x + 0.5);

		#ifdef IRIS_FEATURE_BLOCK_EMISSION_ATTRIBUTE
			if (voxelId == 0u && at_midBlock.w > 0) voxelId = uint(BLOCK_LIGHT_1 + at_midBlock.w - 1);
		#endif

		if (voxelId == 0u) voxelId = 1u;

		originPos += at_midBlock.xyz/64.0;
	}
	
	#ifdef LPV_ENTITY_LIGHTS
		if (
			((renderStage == MC_RENDER_STAGE_ENTITIES && (currentRenderedItemId > 0 || entityId > 0)) || renderStage == MC_RENDER_STAGE_BLOCK_ENTITIES)
		) {
			if (renderStage == MC_RENDER_STAGE_BLOCK_ENTITIES) {
				if (blockEntityId > 0 && blockEntityId < 500)
					voxelId = uint(blockEntityId);
			}
			else if (currentRenderedItemId > 0 && currentRenderedItemId < 1200) {
				if (entityId != ENTITY_ITEM_FRAME && entityId != ENTITY_PLAYER) {
		            uint blockDataR = ptBlockLightData(currentRenderedItemId).r;
		            float lightRange = unpackUnorm4x8(blockDataR).a * 255.0;

		            if (lightRange > 0.0)
						voxelId = uint(currentRenderedItemId);
				}
			}
			else {
				switch (entityId) {
					case ENTITY_BLAZE:
					case ENTITY_END_CRYSTAL:
					// case ENTITY_FIREBALL_SMALL:
					case ENTITY_GLOW_SQUID:
					case ENTITY_MAGMA_CUBE:
					case ENTITY_SPECTRAL_ARROW:
					case ENTITY_TNT:
						voxelId = uint(entityId);
						break;
				}
			}
		}
	#endif

	if (voxelId > 0u)
		SetVoxelBlock(originPos, voxelId);
}