// Penumbra - per-block light and tint data
// ---------------------------------------------------------------------------
// Provenance: the table below was lifted verbatim out of dimensions/setup.csh,
// lines 10-50 (the colour constants and the two matrix builders) and lines 59-1154
// (the id table, the saturation and the packing), by script rather than by hand,
// in commit a07cf68. It was lifted rather than copied because transcribing a
// thousand lines of table is how a colour constant gets dropped, and a dropped
// constant is a torch that lights a room the wrong colour with nothing to say so.
//
// This file is now the only copy, and it is meant to be edited in place. The
// script that did the lifting read setup.csh, and setup.csh is now an empty stub
// explaining that there is nothing left for it to do, so the script had no input
// and was removed rather than left to rot or to keep a second, drifting copy of
// the table alive.
//
// The two places to be careful when editing:
//   * every entry is chosen by `if (blockId == ...)`, so the order matters - a
//     later entry overwrites an earlier one rather than being skipped
//   * the packing at the bottom is what the readers unpack, and `lightRange` is
//     stored as lightRange/255 in an 8-bit unorm, so a range above 255 wraps
//
// This used to be a storage image.
//
//   layout(rg32ui) uniform writeonly uimage1D imgBlockData;
//
// 1D is not one of the sampler shapes this engine binds - the bindable set is
// 2D, 2DShadow, 2DArray, 2DArrayShadow, 2DMS, 2DMSArray, Cube, CubeShadow,
// CubeArray, CubeArrayShadow, with any i/u prefix stripped - so the compute pass
// that used it would not compile at all:
//
//   compute world0/shadowcomp SPIR-V failed: Unsupported texture dimensions
//   '1D' for sampler imgBlockData
//
// Making it a 2D image would fix the compile and nothing else, because the pass
// that populated it, setup.csh, is skipped by the engine outright ("compute
// programs skipped, no stage exists for them yet"). The buffer would be written
// by nothing and read as whatever was in it.
//
// It does not need to be a buffer. Every entry is a compile-time constant picked
// by block id - a light colour, a range, a tint and a mask - so a function of the
// id computes the identical value, with no binding, no format and no pass.
//
// The cost is that the chain of comparisons is evaluated per call rather than
// read once. That is cheap where it is called from (once per voxel in the flood
// fill, which does far more work per voxel) and effectively free in the fragment
// stage, where the only caller is the hand-held light path and runs for the
// frames where something is held up.

#include "/lib/items.glsl"
#include "/lib/blocks.glsl"
#include "/lib/entities.glsl"

    const vec3 LightColor_Amethyst = vec3(0.464, 0.227, 0.788);
    const vec3 LightColor_Candles = vec3(1.0, 0.4, 0.1);
    const vec3 LightColor_CopperBulb = vec3(1.0);
    const vec3 LightColor_LightBlock = vec3(1.0);
    const vec3 LightColor_RedstoneTorch = vec3(0.939, 0.305, 0.164);
    const vec3 LightColor_SeaPickle = vec3(0.283, 0.394, 0.212);

    const vec3 LightColor_Candles_Black = vec3(0.200);
    const vec3 LightColor_Candles_Blue = vec3(0.000, 0.259, 1.000);
    const vec3 LightColor_Candles_Brown = vec3(0.459, 0.263, 0.149);
    const vec3 LightColor_Candles_Cyan = vec3(0.000, 0.839, 0.839);
    const vec3 LightColor_Candles_Gray = vec3(0.329, 0.357, 0.388);
    const vec3 LightColor_Candles_Green = vec3(0.263, 0.451, 0.000);
    const vec3 LightColor_Candles_LightBlue = vec3(0.153, 0.686, 1.000);
    const vec3 LightColor_Candles_LightGray = vec3(0.631, 0.627, 0.624);
    const vec3 LightColor_Candles_Lime = vec3(0.439, 0.890, 0.000);
    const vec3 LightColor_Candles_Magenta = vec3(0.757, 0.098, 0.812);
    const vec3 LightColor_Candles_Orange = vec3(1.000, 0.459, 0.000);
    const vec3 LightColor_Candles_Pink = vec3(1.000, 0.553, 0.718);
    const vec3 LightColor_Candles_Purple = vec3(0.569, 0.000, 1.000);
    const vec3 LightColor_Candles_Red = vec3(0.859, 0.000, 0.000);
    const vec3 LightColor_Candles_White = vec3(1.000);
    const vec3 LightColor_Candles_Yellow = vec3(1.000, 0.878, 0.000);

    uint BuildLpvMask(const in uint north, const in uint east, const in uint south, const in uint west, const in uint up, const in uint down) {
        return east | (west << 1) | (down << 2) | (up << 3) | (south << 4) | (north << 5);
    }

    mat4 GetSaturationMatrix(const in float saturation) {
        const vec3 luminance = vec3(0.3086, 0.6094, 0.0820);
        
        vec3 lumSat = luminance * (1.0 - saturation);
        vec2 satZero = vec2(saturation, 0.0);
        
        return mat4(
            vec4(lumSat.r + satZero.xyy, 0.0),
            vec4(lumSat.g + satZero.yxy, 0.0),
            vec4(lumSat.b + satZero.yyx, 0.0),
            vec4(0.0, 0.0, 0.0, 1.0));
    }

uvec2 ptBlockLightData(int blockId) {
    // The original returned early for ids past the image width.
    // Nothing indexes the table any more, so the guard is gone; the
    // callers already reject ids they do not have.

            vec3 lightColor = vec3(0.0);
            float lightRange = 0.0;
            float mixWeight = 0.0;
            // Only meaningful for the blocks below that are shaped like something
            // other than a cube - the stairs, the wall runs, the lamps. Those assign
            // a real mask and this default is overwritten.
            //
            // It is deliberately NOT consulted for solidity. shadowcomp.csh's
            // sampleShared decides "does light pass through this voxel" from whether
            // the block is empty, and asks the table only for the shape of blocks
            // that are not cubes. Reading this default as a pass-through bit is what
            // made every wall in the world transparent to light.
            uint mixMask = 0xFFFF;
            vec3 tintColor = vec3(1.0);

            if (blockId == BLOCK_SSS_WEAK || blockId == BLOCK_SSS_WEAK_3 || blockId == BLOCK_SSS_STRONG) {
                mixWeight = 1.0;
            }

            // The blocks that genuinely pass light, opting in explicitly.
            //
            // These set mixWeight but never set mixMask, so under the old code they
            // relied on the 0xFFFF default being read as "open". Now that a solid
            // voxel is closed without consulting the table, anything not listed here
            // is closed - which would put out glass, water and every plant in the
            // game. So they are named.
            //
            // The mask chosen per block is the shape, not a blanket pass:
            //
            //   - water is open on the top face only, so light falls in and pools
            //     rather than travelling sideways through an ocean
            //   - glass, ice and the seventeen glass colours are open on all six,
            //     because a glass-walled room should be lit
            //   - plants are open, since the voxel a plant occupies is the one light
            //     has to pass through on its way out of the block it grows on
            //
            // Emitters need this too - a torch seeds its own voxel and the light has
            // to leave it - but they are keyed off lightRange further down rather
            // than listed here, so that a new emitter added to the table cannot be
            // forgotten.
            if (blockId == BLOCK_WATER) {
                mixMask = BuildLpvMask(0u, 0u, 0u, 0u, 1u, 0u);
            }
            else if (blockId >= BLOCK_GLASS && blockId <= BLOCK_GLASS_YELLOW) {
                // The seventeen glass ids are contiguous, 301 through 317.
                mixMask = BuildLpvMask(1u, 1u, 1u, 1u, 1u, 1u);
            }
            else if (blockId == BLOCK_ICE) {
                mixMask = BuildLpvMask(1u, 1u, 1u, 1u, 1u, 1u);
            }
            else if (blockId == BLOCK_AIR_WAVING
                  || blockId == BLOCK_GROUND_WAVING || blockId == BLOCK_GROUND_WAVING_VERTICAL
                  || blockId == BLOCK_BAMBOO || blockId == BLOCK_SAPLING
                  || blockId == BLOCK_GRASS_SHORT || blockId == BLOCK_GRASS_TALL_UPPER
                  || blockId == BLOCK_GRASS_TALL_LOWER || blockId == BLOCK_SSS_WEAK
                  || blockId == BLOCK_SSS_WEAK_3 || blockId == BLOCK_SSS_STRONG) {
                mixMask = BuildLpvMask(1u, 1u, 1u, 1u, 1u, 1u);
            }

            switch (blockId) {
                case BLOCK_WATER:
                    mixWeight = 0.8;
                    break;

                case BLOCK_BAMBOO:
                    mixWeight = 0.8;
                    break;

                case BLOCK_GRASS_SHORT:
                case BLOCK_GRASS_TALL_UPPER:
                case BLOCK_GRASS_TALL_LOWER:
                    mixWeight = 0.85;
                    break;

                case BLOCK_GROUND_WAVING:
                case BLOCK_GROUND_WAVING_VERTICAL:
                case BLOCK_AIR_WAVING:
                    mixWeight = 0.9;
                    break;

                case BLOCK_SAPLING:
                    mixWeight = 0.9;
                    break;
            }

            // lightsources

            if (blockId == BLOCK_AMETHYST_BUD_LARGE || blockId == ITEM_AMETHYST_BUD_LARGE) {
                lightColor = LightColor_Amethyst;
                lightRange = 4.0;
                mixWeight = 0.6;
            }

            if (blockId == BLOCK_AMETHYST_BUD_MEDIUM || blockId == ITEM_AMETHYST_BUD_MEDIUM) {
                lightColor = LightColor_Amethyst;
                lightRange = 2.0;
                mixWeight = 0.8;
            }

            if (blockId == BLOCK_AMETHYST_CLUSTER || blockId == ITEM_AMETHYST_CLUSTER) {
                lightColor = LightColor_Amethyst;
                lightRange = 5.0;
                mixWeight = 0.4;
            }

            if (blockId == BLOCK_BEACON || blockId == ITEM_BEACON) {
                lightColor = vec3(1.0);
                lightRange = 15.0;
            }

            if (blockId == BLOCK_BREWING_STAND) {
                lightColor = vec3(0.636, 0.509, 0.179);
                lightRange = 1.0;
                mixWeight = 0.8;
            }

            #ifdef LPV_COLORED_CANDLES
                if (blockId >= BLOCK_CANDLES_PLAIN_LIT_1 && blockId <= BLOCK_CANDLES_YELLOW_LIT_4) {
                    switch (blockId) {
                        case BLOCK_CANDLES_PLAIN_LIT_1:
                            lightColor = LightColor_Candles;
                            lightRange = 3.0;
                            break;
                        case BLOCK_CANDLES_PLAIN_LIT_2:
                            lightColor = LightColor_Candles;
                            lightRange = 6.0;
                            break;
                        case BLOCK_CANDLES_PLAIN_LIT_3:
                            lightColor = LightColor_Candles;
                            lightRange = 9.0;
                            break;
                        case BLOCK_CANDLES_PLAIN_LIT_4:
                            lightColor = LightColor_Candles;
                            lightRange = 12.0;
                            break;

                        case BLOCK_CANDLES_BLACK_LIT_1:
                            lightColor = LightColor_Candles_Black;
                            lightRange = 3.0;
                            break;
                        case BLOCK_CANDLES_BLACK_LIT_2:
                            lightColor = LightColor_Candles_Black;
                            lightRange = 6.0;
                            break;
                        case BLOCK_CANDLES_BLACK_LIT_3:
                            lightColor = LightColor_Candles_Black;
                            lightRange = 9.0;
                            break;
                        case BLOCK_CANDLES_BLACK_LIT_4:
                            lightColor = LightColor_Candles_Black;
                            lightRange = 12.0;
                            break;

                        case BLOCK_CANDLES_BLUE_LIT_1:
                            lightColor = LightColor_Candles_Blue;
                            lightRange = 3.0;
                            break;
                        case BLOCK_CANDLES_BLUE_LIT_2:
                            lightColor = LightColor_Candles_Blue;
                            lightRange = 6.0;
                            break;
                        case BLOCK_CANDLES_BLUE_LIT_3:
                            lightColor = LightColor_Candles_Blue;
                            lightRange = 9.0;
                            break;
                        case BLOCK_CANDLES_BLUE_LIT_4:
                            lightColor = LightColor_Candles_Blue;
                            lightRange = 12.0;
                            break;

                        case BLOCK_CANDLES_BROWN_LIT_1:
                            lightColor = LightColor_Candles_Brown;
                            lightRange = 3.0;
                            break;
                        case BLOCK_CANDLES_BROWN_LIT_2:
                            lightColor = LightColor_Candles_Brown;
                            lightRange = 6.0;
                            break;
                        case BLOCK_CANDLES_BROWN_LIT_3:
                            lightColor = LightColor_Candles_Brown;
                            lightRange = 9.0;
                            break;
                        case BLOCK_CANDLES_BROWN_LIT_4:
                            lightColor = LightColor_Candles_Brown;
                            lightRange = 12.0;
                            break;

                        case BLOCK_CANDLES_CYAN_LIT_1:
                            lightColor = LightColor_Candles_Cyan;
                            lightRange = 3.0;
                            break;
                        case BLOCK_CANDLES_CYAN_LIT_2:
                            lightColor = LightColor_Candles_Cyan;
                            lightRange = 6.0;
                            break;
                        case BLOCK_CANDLES_CYAN_LIT_3:
                            lightColor = LightColor_Candles_Cyan;
                            lightRange = 9.0;
                            break;
                        case BLOCK_CANDLES_CYAN_LIT_4:
                            lightColor = LightColor_Candles_Cyan;
                            lightRange = 12.0;
                            break;

                        case BLOCK_CANDLES_GRAY_LIT_1:
                            lightColor = LightColor_Candles_Gray;
                            lightRange = 3.0;
                            break;
                        case BLOCK_CANDLES_GRAY_LIT_2:
                            lightColor = LightColor_Candles_Gray;
                            lightRange = 6.0;
                            break;
                        case BLOCK_CANDLES_GRAY_LIT_3:
                            lightColor = LightColor_Candles_Gray;
                            lightRange = 9.0;
                            break;
                        case BLOCK_CANDLES_GRAY_LIT_4:
                            lightColor = LightColor_Candles_Gray;
                            lightRange = 12.0;
                            break;

                        case BLOCK_CANDLES_GREEN_LIT_1:
                            lightColor = LightColor_Candles_Green;
                            lightRange = 3.0;
                            break;
                        case BLOCK_CANDLES_GREEN_LIT_2:
                            lightColor = LightColor_Candles_Green;
                            lightRange = 6.0;
                            break;
                        case BLOCK_CANDLES_GREEN_LIT_3:
                            lightColor = LightColor_Candles_Green;
                            lightRange = 9.0;
                            break;
                        case BLOCK_CANDLES_GREEN_LIT_4:
                            lightColor = LightColor_Candles_Green;
                            lightRange = 12.0;
                            break;

                        case BLOCK_CANDLES_LIGHT_BLUE_LIT_1:
                            lightColor = LightColor_Candles_LightBlue;
                            lightRange = 3.0;
                            break;
                        case BLOCK_CANDLES_LIGHT_BLUE_LIT_2:
                            lightColor = LightColor_Candles_LightBlue;
                            lightRange = 6.0;
                            break;
                        case BLOCK_CANDLES_LIGHT_BLUE_LIT_3:
                            lightColor = LightColor_Candles_LightBlue;
                            lightRange = 9.0;
                            break;
                        case BLOCK_CANDLES_LIGHT_BLUE_LIT_4:
                            lightColor = LightColor_Candles_LightBlue;
                            lightRange = 12.0;
                            break;

                        case BLOCK_CANDLES_LIGHT_GRAY_LIT_1:
                            lightColor = LightColor_Candles_LightGray;
                            lightRange = 3.0;
                            break;
                        case BLOCK_CANDLES_LIGHT_GRAY_LIT_2:
                            lightColor = LightColor_Candles_LightGray;
                            lightRange = 6.0;
                            break;
                        case BLOCK_CANDLES_LIGHT_GRAY_LIT_3:
                            lightColor = LightColor_Candles_LightGray;
                            lightRange = 9.0;
                            break;
                        case BLOCK_CANDLES_LIGHT_GRAY_LIT_4:
                            lightColor = LightColor_Candles_LightGray;
                            lightRange = 12.0;
                            break;

                        case BLOCK_CANDLES_LIME_LIT_1:
                            lightColor = LightColor_Candles_Lime;
                            lightRange = 3.0;
                            break;
                        case BLOCK_CANDLES_LIME_LIT_2:
                            lightColor = LightColor_Candles_Lime;
                            lightRange = 6.0;
                            break;
                        case BLOCK_CANDLES_LIME_LIT_3:
                            lightColor = LightColor_Candles_Lime;
                            lightRange = 9.0;
                            break;
                        case BLOCK_CANDLES_LIME_LIT_4:
                            lightColor = LightColor_Candles_Lime;
                            lightRange = 12.0;
                            break;

                        case BLOCK_CANDLES_MAGENTA_LIT_1:
                            lightColor = LightColor_Candles_Magenta;
                            lightRange = 3.0;
                            break;
                        case BLOCK_CANDLES_MAGENTA_LIT_2:
                            lightColor = LightColor_Candles_Magenta;
                            lightRange = 6.0;
                            break;
                        case BLOCK_CANDLES_MAGENTA_LIT_3:
                            lightColor = LightColor_Candles_Magenta;
                            lightRange = 9.0;
                            break;
                        case BLOCK_CANDLES_MAGENTA_LIT_4:
                            lightColor = LightColor_Candles_Magenta;
                            lightRange = 12.0;
                            break;

                        case BLOCK_CANDLES_ORANGE_LIT_1:
                            lightColor = LightColor_Candles_Orange;
                            lightRange = 3.0;
                            break;
                        case BLOCK_CANDLES_ORANGE_LIT_2:
                            lightColor = LightColor_Candles_Orange;
                            lightRange = 6.0;
                            break;
                        case BLOCK_CANDLES_ORANGE_LIT_3:
                            lightColor = LightColor_Candles_Orange;
                            lightRange = 9.0;
                            break;
                        case BLOCK_CANDLES_ORANGE_LIT_4:
                            lightColor = LightColor_Candles_Orange;
                            lightRange = 12.0;
                            break;

                        case BLOCK_CANDLES_PINK_LIT_1:
                            lightColor = LightColor_Candles_Pink;
                            lightRange = 3.0;
                            break;
                        case BLOCK_CANDLES_PINK_LIT_2:
                            lightColor = LightColor_Candles_Pink;
                            lightRange = 6.0;
                            break;
                        case BLOCK_CANDLES_PINK_LIT_3:
                            lightColor = LightColor_Candles_Pink;
                            lightRange = 9.0;
                            break;
                        case BLOCK_CANDLES_PINK_LIT_4:
                            lightColor = LightColor_Candles_Pink;
                            lightRange = 12.0;
                            break;

                        case BLOCK_CANDLES_PURPLE_LIT_1:
                            lightColor = LightColor_Candles_Purple;
                            lightRange = 3.0;
                            break;
                        case BLOCK_CANDLES_PURPLE_LIT_2:
                            lightColor = LightColor_Candles_Purple;
                            lightRange = 6.0;
                            break;
                        case BLOCK_CANDLES_PURPLE_LIT_3:
                            lightColor = LightColor_Candles_Purple;
                            lightRange = 9.0;
                            break;
                        case BLOCK_CANDLES_PURPLE_LIT_4:
                            lightColor = LightColor_Candles_Purple;
                            lightRange = 12.0;
                            break;

                        case BLOCK_CANDLES_RED_LIT_1:
                            lightColor = LightColor_Candles_Red;
                            lightRange = 3.0;
                            break;
                        case BLOCK_CANDLES_RED_LIT_2:
                            lightColor = LightColor_Candles_Red;
                            lightRange = 6.0;
                            break;
                        case BLOCK_CANDLES_RED_LIT_3:
                            lightColor = LightColor_Candles_Red;
                            lightRange = 9.0;
                            break;
                        case BLOCK_CANDLES_RED_LIT_4:
                            lightColor = LightColor_Candles_Red;
                            lightRange = 12.0;
                            break;

                        case BLOCK_CANDLES_WHITE_LIT_1:
                            lightColor = LightColor_Candles_White;
                            lightRange = 3.0;
                            break;
                        case BLOCK_CANDLES_WHITE_LIT_2:
                            lightColor = LightColor_Candles_White;
                            lightRange = 6.0;
                            break;
                        case BLOCK_CANDLES_WHITE_LIT_3:
                            lightColor = LightColor_Candles_White;
                            lightRange = 9.0;
                            break;
                        case BLOCK_CANDLES_WHITE_LIT_4:
                            lightColor = LightColor_Candles_White;
                            lightRange = 12.0;
                            break;

                        case BLOCK_CANDLES_YELLOW_LIT_1:
                            lightColor = LightColor_Candles_Yellow;
                            lightRange = 3.0;
                            break;
                        case BLOCK_CANDLES_YELLOW_LIT_2:
                            lightColor = LightColor_Candles_Yellow;
                            lightRange = 6.0;
                            break;
                        case BLOCK_CANDLES_YELLOW_LIT_3:
                            lightColor = LightColor_Candles_Yellow;
                            lightRange = 9.0;
                            break;
                        case BLOCK_CANDLES_YELLOW_LIT_4:
                            lightColor = LightColor_Candles_Yellow;
                            lightRange = 12.0;
                            break;
                    }
            #else
                if (blockId >= BLOCK_CANDLES_LIT_1 && blockId <= BLOCK_CANDLES_LIT_4) {
                    switch (blockId) {
                        case BLOCK_CANDLES_LIT_1:
                            lightColor = LightColor_Candles;
                            lightRange = 3.0;
                            break;
                        case BLOCK_CANDLES_LIT_2:
                            lightColor = LightColor_Candles;
                            lightRange = 6.0;
                            break;
                        case BLOCK_CANDLES_LIT_3:
                            lightColor = LightColor_Candles;
                            lightRange = 9.0;
                            break;
                        case BLOCK_CANDLES_LIT_4:
                            lightColor = LightColor_Candles;
                            lightRange = 12.0;
                            break;
                    }
            #endif

                mixWeight = 1.0;
            }

            if (blockId == ITEM_BLAZE_ROD) {
                // TODO
            }

            if (blockId == BLOCK_CAVE_VINE_BERRIES || blockId == ITEM_GLOW_BERRIES) {
                lightColor = vec3(1.0, 1.0, 0.5);

                lightRange = 14.0;
                mixWeight = 1.0;
            }

            #ifdef LPV_REDSTONE_LIGHTS
                if (blockId == BLOCK_COMPARATOR_LIT) {
                    lightColor = LightColor_RedstoneTorch;
                    lightRange = 4.0;
                }
            #endif

            switch (blockId) {
                case BLOCK_COPPER_BULB_LIT:
                    lightColor = LightColor_CopperBulb;
                    lightRange = 15.0;
                    break;
                case BLOCK_COPPER_BULB_EXPOSED_LIT:
                    lightColor = LightColor_CopperBulb;
                    lightRange = 12.0;
                    break;
                case BLOCK_COPPER_BULB_OXIDIZED_LIT:
                    lightColor = LightColor_CopperBulb;
                    lightRange = 4.0;
                    break;
                case BLOCK_COPPER_BULB_WEATHERED_LIT:
                    lightColor = LightColor_CopperBulb;
                    lightRange = 8.0;
                    break;
                case BLOCK_CONDUIT:
                    lightColor = vec3(1.0);
                    lightRange = 15.0;
                    break;
            }

            if (blockId == BLOCK_CRYING_OBSIDIAN) {
                lightColor = vec3(0.390, 0.065, 0.646);
                lightRange = 10.0;
            }

            if (blockId == BLOCK_END_GATEWAY) {
                lightColor = vec3(1.0);
                lightRange = 15.0;
            }

            if (blockId == BLOCK_END_ROD || blockId == ITEM_END_ROD) {
                lightColor = vec3(0.957, 0.929, 0.875);
                lightRange = 14.0;
            }

            if (blockId == BLOCK_FIRE) {
                lightColor = vec3(0.864, 0.598, 0.348);
                lightRange = 15.0;
                mixWeight = 1.0;
            }

            if (blockId == BLOCK_FIRE_FLIES) {
                lightColor = vec3(0.729, 0.639, 0.31);
                lightRange = 2.0;
                mixWeight = 1.0;
            }

            if (blockId == BLOCK_FROGLIGHT_OCHRE || blockId == ITEM_FROGLIGHT_OCHRE) {
                lightColor = vec3(0.768, 0.648, 0.108);
                lightRange = 15.0;
            }

            if (blockId == BLOCK_FROGLIGHT_PEARLESCENT || blockId == ITEM_FROGLIGHT_PEARLESCENT) {
                lightColor = vec3(0.737, 0.435, 0.658);
                lightRange = 15.0;
            }

            if (blockId == BLOCK_FROGLIGHT_VERDANT || blockId == ITEM_FROGLIGHT_VERDANT) {
                lightColor = vec3(0.463, 0.763, 0.409);
                lightRange = 15.0;
            }

            if (blockId == BLOCK_FURNACE_LIT) {
                lightColor = vec3(0.8, 0.7, 0.1);
                lightRange = 13.0;
            }

            if (blockId == BLOCK_GLOW_LICHEN || blockId == ITEM_GLOW_LICHEN) {
                lightColor = vec3(0.1, 0.2, 0.12);
                lightRange = 7.0;
            }

            if (blockId == BLOCK_GLOWSTONE || blockId == ITEM_GLOWSTONE) {
                lightColor = vec3(0.747, 0.594, 0.326);
                lightRange = 15.0;
            }

            if (blockId == ITEM_GLOWSTONE_DUST) {
                lightColor = vec3(0.747, 0.594, 0.326);
                lightRange = 8.0;
            }

            if (blockId == BLOCK_JACK_O_LANTERN || blockId == ITEM_JACK_O_LANTERN) {
                lightColor = vec3(0.864, 0.598, 0.348);
                lightRange = 15.0;
            }

            if (blockId == BLOCK_LANTERN || blockId == ITEM_LANTERN) {
                lightColor = vec3(0.839, 0.541, 0.2);
                lightRange = 15.0;
                mixWeight = 0.8;
            }

            if (blockId == BLOCK_LAVA) {
                lightColor = vec3(0.659, 0.302, 0.106);
                lightRange = 15.0;
            }
            else if (blockId == ITEM_LAVA_BUCKET) {
                lightColor = vec3(0.659, 0.302, 0.106);
                lightRange = 8.0;
            }

            if (blockId >= BLOCK_LIGHT_1 && blockId <= BLOCK_LIGHT_15) {
                lightColor = LightColor_LightBlock;
                mixWeight = 1.0;

                switch (blockId) {
                    case BLOCK_LIGHT_1:
                        lightRange = 1;
                        break;
                    case BLOCK_LIGHT_2:
                        lightRange = 2;
                        break;
                    case BLOCK_LIGHT_3:
                        lightRange = 3;
                        break;
                    case BLOCK_LIGHT_4:
                        lightRange = 4;
                        break;
                    case BLOCK_LIGHT_5:
                        lightRange = 5;
                        break;
                    case BLOCK_LIGHT_6:
                        lightRange = 6;
                        break;
                    case BLOCK_LIGHT_7:
                        lightRange = 7;
                        break;
                    case BLOCK_LIGHT_8:
                        lightRange = 8;
                        break;
                    case BLOCK_LIGHT_9:
                        lightRange = 9;
                        break;
                    case BLOCK_LIGHT_10:
                        lightRange = 10;
                        break;
                    case BLOCK_LIGHT_11:
                        lightRange = 11;
                        break;
                    case BLOCK_LIGHT_12:
                        lightRange = 12;
                        break;
                    case BLOCK_LIGHT_13:
                        lightRange = 13;
                        break;
                    case BLOCK_LIGHT_14:
                        lightRange = 14;
                        break;
                    case BLOCK_LIGHT_15:
                        lightRange = 15;
                        break;
                }
            }

            if (blockId == BLOCK_MAGMA || blockId == ITEM_MAGMA) {
                lightColor = vec3(0.747, 0.323, 0.110);
                lightRange = 3.0;
                mixWeight = 0.0;
            }

            if (blockId == BLOCK_RAIL_POWERED_ON) {
                lightColor = LightColor_RedstoneTorch;
                lightRange = 7.0;
                mixWeight = 0.9;
            }

            if (blockId == BLOCK_REDSTONE_LAMP_LIT) {
                lightColor = vec3(0.953, 0.796, 0.496);
                lightRange = 15.0;
                mixWeight = 0.0;
            }

            if (blockId == BLOCK_REDSTONE_ORE_LIT || blockId == BLOCK_DEEPSLATE_REDSTONE_ORE_LIT) {
                lightColor = LightColor_RedstoneTorch;
                lightRange = 7.0;
                mixWeight = 0.0;
            }

            if (blockId == BLOCK_REDSTONE_TORCH_LIT || blockId == ITEM_REDSTONE_TORCH) {
                lightColor = LightColor_RedstoneTorch;
                lightRange = 7.0;
                mixWeight = 0.9;
            }

            switch (blockId) {
            #ifdef LPV_REDSTONE_LIGHTS
                case BLOCK_REDSTONE_WIRE_1:
                    lightColor = LightColor_RedstoneTorch;
                    lightRange = 0.5;
                    break;
                case BLOCK_REDSTONE_WIRE_2:
                    lightColor = LightColor_RedstoneTorch;
                    lightRange = 1.0;
                    break;
                case BLOCK_REDSTONE_WIRE_3:
                    lightColor = LightColor_RedstoneTorch;
                    lightRange = 1.5;
                    break;
                case BLOCK_REDSTONE_WIRE_4:
                    lightColor = LightColor_RedstoneTorch;
                    lightRange = 2.0;
                    break;
                case BLOCK_REDSTONE_WIRE_5:
                    lightColor = LightColor_RedstoneTorch;
                    lightRange = 2.5;
                    break;
                case BLOCK_REDSTONE_WIRE_6:
                    lightColor = LightColor_RedstoneTorch;
                    lightRange = 3.0;
                    break;
                case BLOCK_REDSTONE_WIRE_7:
                    lightColor = LightColor_RedstoneTorch;
                    lightRange = 3.5;
                    break;
                case BLOCK_REDSTONE_WIRE_8:
                    lightColor = LightColor_RedstoneTorch;
                    lightRange = 4.0;
                    break;
                case BLOCK_REDSTONE_WIRE_9:
                    lightColor = LightColor_RedstoneTorch;
                    lightRange = 4.5;
                    break;
                case BLOCK_REDSTONE_WIRE_10:
                    lightColor = LightColor_RedstoneTorch;
                    lightRange = 5.0;
                    break;
                case BLOCK_REDSTONE_WIRE_11:
                    lightColor = LightColor_RedstoneTorch;
                    lightRange = 5.5;
                    break;
                case BLOCK_REDSTONE_WIRE_12:
                    lightColor = LightColor_RedstoneTorch;
                    lightRange = 6.0;
                    break;
                case BLOCK_REDSTONE_WIRE_13:
                    lightColor = LightColor_RedstoneTorch;
                    lightRange = 6.5;
                    break;
                case BLOCK_REDSTONE_WIRE_14:
                    lightColor = LightColor_RedstoneTorch;
                    lightRange = 7.0;
                    break;
                case BLOCK_REDSTONE_WIRE_15:
                    lightColor = LightColor_RedstoneTorch;
                    lightRange = 7.5;
                    break;

                case BLOCK_REPEATER_LIT:
                    lightColor = LightColor_RedstoneTorch;
                    lightRange = 4.0;
                    break;
            #endif

                case BLOCK_RESPAWN_ANCHOR_4:
                    lightColor = vec3(1.0, 0.2, 1.0);
                    lightRange = 15.0;
                    break;
                case BLOCK_SCULK_SENSOR_ACTIVE:
                    lightColor = vec3(0.1, 0.4, 1.0);
                    lightRange = 1.0;
                    break;
                case BLOCK_SEA_PICKLE_WET_1:
                    lightColor = LightColor_SeaPickle;
                    lightRange = 6.0;
                    mixWeight = 1.0;
                    break;
                case BLOCK_SEA_PICKLE_WET_2:
                    lightColor = LightColor_SeaPickle;
                    lightRange = 9.0;
                    mixWeight = 1.0;
                    break;
                case BLOCK_SEA_PICKLE_WET_3:
                    lightColor = LightColor_SeaPickle;
                    lightRange = 12.0;
                    mixWeight = 1.0;
                    break;
                case BLOCK_SEA_PICKLE_WET_4:
                    lightColor = LightColor_SeaPickle;
                    lightRange = 15.0;
                    mixWeight = 1.0;
                    break;
            }

            if (blockId == BLOCK_SEA_LANTERN || blockId == ITEM_SEA_LANTERN) {
                lightColor = vec3(0.553, 0.748, 0.859);
                lightRange = 15.0;
            }

            if (blockId == BLOCK_SHROOMLIGHT || blockId == ITEM_SHROOMLIGHT) {
                lightColor = vec3(0.848, 0.469, 0.205);
                lightRange = 15.0;
            }

            if (blockId == BLOCK_SOUL_FIRE) {
                lightColor = vec3(0.1, 0.6, 1.0);
                lightRange = 10.0;
                mixWeight = 1.0;
            }

            if (
                blockId == BLOCK_SOUL_TORCH || blockId == ITEM_SOUL_TORCH ||
                blockId == BLOCK_SOUL_LANTERN || blockId == ITEM_SOUL_LANTERN
            ) {
                lightColor = vec3(0.1, 0.6, 1.0);
                lightRange = 10.0;
                mixWeight = 0.8;
            }

            if (blockId == BLOCK_TORCH || blockId == ITEM_TORCH ||
                blockId == BLOCK_LANTERN || blockId == ITEM_LANTERN
            ) {
                lightColor = vec3(TORCH_R, TORCH_G, TORCH_B);
                lightRange = 14.0;
                mixWeight = 0.8;
            }

            if (blockId >= BLOCK_LAMP_LIT_BLACK && blockId <= BLOCK_LAMP_LIT_YELLOW) {
                lightRange = 15.0;
                mixWeight = 0.25;

                switch (blockId) {
                    case BLOCK_LAMP_LIT_BLACK:
                        lightColor = LightColor_Candles_Black;
                        break;
                    case BLOCK_LAMP_LIT_BLUE:
                        lightColor = LightColor_Candles_Blue;
                        break;
                    case BLOCK_LAMP_LIT_BROWN:
                        lightColor = LightColor_Candles_Brown;
                        break;
                    case BLOCK_LAMP_LIT_CYAN:
                        lightColor = LightColor_Candles_Cyan;
                        break;
                    case BLOCK_LAMP_LIT_GRAY:
                        lightColor = LightColor_Candles_Gray;
                        break;
                    case BLOCK_LAMP_LIT_GREEN:
                        lightColor = LightColor_Candles_Green;
                        break;
                    case BLOCK_LAMP_LIT_LIGHT_BLUE:
                        lightColor = LightColor_Candles_LightBlue;
                        break;
                    case BLOCK_LAMP_LIT_LIGHT_GRAY:
                        lightColor = LightColor_Candles_LightGray;
                        break;
                    case BLOCK_LAMP_LIT_LIME:
                        lightColor = LightColor_Candles_Lime;
                        break;
                    case BLOCK_LAMP_LIT_MAGENTA:
                        lightColor = LightColor_Candles_Magenta;
                        break;
                    case BLOCK_LAMP_LIT_ORANGE:
                        lightColor = LightColor_Candles_Orange;
                        break;
                    case BLOCK_LAMP_LIT_PINK:
                        lightColor = LightColor_Candles_Pink;
                        break;
                    case BLOCK_LAMP_LIT_PURPLE:
                        lightColor = LightColor_Candles_Purple;
                        break;
                    case BLOCK_LAMP_LIT_RED:
                        lightColor = LightColor_Candles_Red;
                        break;
                    case BLOCK_LAMP_LIT_WHITE:
                        lightColor = LightColor_Candles_White;
                        break;
                    case BLOCK_LAMP_LIT_YELLOW:
                        lightColor = LightColor_Candles_Yellow;
                        break;
                }
            }

            // reflective translucents / glass

            switch (blockId) {
                case BLOCK_GLASS:
                    tintColor = vec3(1.0);
                    mixWeight = 1.0;
                    break;
                case BLOCK_GLASS_BLACK:
                    tintColor = vec3(0.3);
                    mixWeight = 1.0;
                    break;
                case BLOCK_GLASS_BLUE:
                    tintColor = vec3(0.1, 0.1, 0.98);
                    mixWeight = 1.0;
                    break;
                case BLOCK_GLASS_BROWN:
                    tintColor = vec3(0.566, 0.388, 0.148);
                    mixWeight = 1.0;
                    break;
                case BLOCK_GLASS_CYAN:
                    tintColor = vec3(0.082, 0.533, 0.763);
                    mixWeight = 1.0;
                    break;
                case BLOCK_GLASS_GRAY:
                    tintColor = vec3(0.4, 0.4, 0.4);
                    mixWeight = 1.0;
                    break;
                case BLOCK_GLASS_GREEN:
                    tintColor = vec3(0.125, 0.808, 0.081);
                    mixWeight = 1.0;
                    break;
                case BLOCK_GLASS_LIGHT_BLUE:
                    tintColor = vec3(0.320, 0.685, 0.955);
                    mixWeight = 1.0;
                    break;
                case BLOCK_GLASS_LIGHT_GRAY:
                    tintColor = vec3(0.7);
                    mixWeight = 1.0;
                    break;
                case BLOCK_GLASS_LIME:
                    tintColor = vec3(0.633, 0.924, 0.124);
                    mixWeight = 1.0;
                    break;
                case BLOCK_GLASS_MAGENTA:
                    tintColor = vec3(0.698, 0.298, 0.847);
                    mixWeight = 1.0;
                    break;
                case BLOCK_GLASS_ORANGE:
                    tintColor = vec3(0.919, 0.586, 0.185);
                    mixWeight = 1.0;
                    break;
                case BLOCK_GLASS_PINK:
                    tintColor = vec3(0.949, 0.274, 0.497);
                    mixWeight = 1.0;
                    break;
                case BLOCK_GLASS_PURPLE:
                    tintColor = vec3(0.578, 0.170, 0.904);
                    mixWeight = 1.0;
                    break;
                case BLOCK_GLASS_RED:
                    tintColor = vec3(0.999, 0.188, 0.188);
                    mixWeight = 1.0;
                    break;
                case BLOCK_GLASS_WHITE:
                    tintColor = vec3(0.96, 0.96, 0.96);
                    mixWeight = 1.0;
                    break;
                case BLOCK_GLASS_YELLOW:
                    tintColor = vec3(0.965, 0.965, 0.123);
                    mixWeight = 1.0;
                    break;
                case BLOCK_HONEY:
                    tintColor = vec3(0.984, 0.733, 0.251);
                    mixWeight = 1.0;
                    break;
                case BLOCK_NETHER_PORTAL:
                    lightColor = vec3(0.502, 0.165, 0.831);
                    tintColor = vec3(0.502, 0.165, 0.831);
                    lightRange = 11.0;
                    mixWeight = 1.0;
                    break;
                case BLOCK_SLIME:
                    tintColor = vec3(0.408, 0.725, 0.329);
                    mixWeight = 1.0;
                    break;

            // LPV shapes

                case BLOCK_LPV_IGNORE:
                    mixWeight = 1.00;
                    break;
                case BLOCK_LPV_MIN:
                    mixWeight = 0.75;
                    break;
                case BLOCK_LPV_MED:
                    mixWeight = 0.50;
                    break;
                case BLOCK_LPV_MAX:
                    mixWeight = 0.25;
                    break;

                case BLOCK_CARPET:
                    mixMask = BuildLpvMask(1u, 1u, 1u, 1u, 1u, 0u);
                    mixWeight = 0.9;
                    break;

                case BLOCK_DOOR_N:
                    mixMask = BuildLpvMask(0u, 1u, 1u, 1u, 1u, 1u);
                    mixWeight = 0.8;
                    break;
                case BLOCK_DOOR_E:
                    mixMask = BuildLpvMask(1u, 0u, 1u, 1u, 1u, 1u);
                    mixWeight = 0.8;
                    break;
                case BLOCK_DOOR_S:
                    mixMask = BuildLpvMask(1u, 1u, 0u, 1u, 1u, 1u);
                    mixWeight = 0.8;
                    break;
                case BLOCK_DOOR_W:
                    mixMask = BuildLpvMask(1u, 1u, 1u, 0u, 1u, 1u);
                    mixWeight = 0.8;
                    break;

                case BLOCK_PRESSURE_PLATE:
                    mixMask = BuildLpvMask(1u, 1u, 1u, 1u, 1u, 0u);
                    mixWeight = 0.9;
                    break;

                case BLOCK_SLAB_TOP:
                    mixMask = BuildLpvMask(1u, 1u, 1u, 1u, 0u, 1u);
                    mixWeight = 0.5;
                    break;
                case BLOCK_SLAB_BOTTOM:
                case BLOCK_SNOW_LAYERS:
                    mixMask = BuildLpvMask(1u, 1u, 1u, 1u, 1u, 0u);
                    mixWeight = 0.5;
                    break;

                case BLOCK_TRAPDOOR_BOTTOM:
                    mixMask = BuildLpvMask(1u, 1u, 1u, 1u, 1u, 0u);
                    mixWeight = 0.8;
                    break;
                case BLOCK_TRAPDOOR_TOP:
                    mixMask = BuildLpvMask(1u, 1u, 1u, 1u, 0u, 1u);
                    mixWeight = 0.8;
                    break;
                case BLOCK_TRAPDOOR_N:
                    mixMask = BuildLpvMask(0u, 1u, 1u, 1u, 1u, 1u);
                    mixWeight = 0.8;
                    break;
                case BLOCK_TRAPDOOR_E:
                    mixMask = BuildLpvMask(1u, 0u, 1u, 1u, 1u, 1u);
                    mixWeight = 0.8;
                    break;
                case BLOCK_TRAPDOOR_S:
                    mixMask = BuildLpvMask(1u, 1u, 0u, 1u, 1u, 1u);
                    mixWeight = 0.8;
                    break;
                case BLOCK_TRAPDOOR_W:
                    mixMask = BuildLpvMask(1u, 1u, 1u, 0u, 1u, 1u);
                    mixWeight = 0.8;
                    break;
            }

            // STAIRS
            if (blockId >= BLOCK_STAIRS_BOTTOM_N && blockId <= BLOCK_STAIRS_TOP_OUTER_S_W) {
                mixWeight = 0.25;

                switch (blockId) {
                    case BLOCK_STAIRS_BOTTOM_N:
                        mixMask = BuildLpvMask(1u, 1u, 0u, 1u, 1u, 0u);
                        break;
                    case BLOCK_STAIRS_BOTTOM_E:
                        mixMask = BuildLpvMask(1u, 1u, 1u, 0u, 1u, 0u);
                        break;
                    case BLOCK_STAIRS_BOTTOM_S:
                        mixMask = BuildLpvMask(0u, 1u, 1u, 1u, 1u, 0u);
                        break;
                    case BLOCK_STAIRS_BOTTOM_W:
                        mixMask = BuildLpvMask(1u, 0u, 1u, 1u, 1u, 0u);
                        break;
                    case BLOCK_STAIRS_BOTTOM_INNER_S_E:
                        mixMask = BuildLpvMask(0u, 1u, 1u, 0u, 0u, 1u);
                        break;
                    case BLOCK_STAIRS_BOTTOM_INNER_S_W:
                        mixMask = BuildLpvMask(0u, 0u, 1u, 1u, 0u, 1u);
                        break;
                    case BLOCK_STAIRS_BOTTOM_INNER_N_W:
                        mixMask = BuildLpvMask(1u, 0u, 0u, 1u, 0u, 1u);
                        break;
                    case BLOCK_STAIRS_BOTTOM_INNER_N_E:
                        mixMask = BuildLpvMask(1u, 1u, 0u, 0u, 0u, 1u);
                        break;
                }

                if (blockId >= BLOCK_STAIRS_BOTTOM_OUTER_N_W && blockId <= BLOCK_STAIRS_BOTTOM_OUTER_S_W) {
                    mixMask = BuildLpvMask(1u, 1u, 1u, 1u, 0u, 1u);
                }

                switch (blockId) {
                    case BLOCK_STAIRS_TOP_N:
                        mixMask = BuildLpvMask(1u, 1u, 0u, 1u, 0u, 1u);
                        break;
                    case BLOCK_STAIRS_TOP_E:
                        mixMask = BuildLpvMask(1u, 1u, 1u, 0u, 0u, 1u);
                        break;
                    case BLOCK_STAIRS_TOP_S:
                        mixMask = BuildLpvMask(0u, 1u, 1u, 1u, 0u, 1u);
                        break;
                    case BLOCK_STAIRS_TOP_W:
                        mixMask = BuildLpvMask(1u, 0u, 1u, 1u, 0u, 1u);
                        break;
                    case BLOCK_STAIRS_TOP_INNER_S_E:
                        mixMask = BuildLpvMask(0u, 1u, 1u, 0u, 0u, 1u);
                        break;
                    case BLOCK_STAIRS_TOP_INNER_S_W:
                        mixMask = BuildLpvMask(0u, 0u, 1u, 1u, 0u, 1u);
                        break;
                    case BLOCK_STAIRS_TOP_INNER_N_W:
                        mixMask = BuildLpvMask(1u, 0u, 0u, 1u, 0u, 1u);
                        break;
                    case BLOCK_STAIRS_TOP_INNER_N_E:
                        mixMask = BuildLpvMask(1u, 1u, 0u, 0u, 0u, 1u);
                        break;
                }

                if (blockId >= BLOCK_STAIRS_TOP_OUTER_N_W && blockId <= BLOCK_STAIRS_TOP_OUTER_S_W) {
                    mixMask = BuildLpvMask(1u, 1u, 1u, 1u, 0u, 1u);
                }
            }

            // WALL
            if (blockId >= BLOCK_WALL_MIN && blockId <= BLOCK_WALL_MAX) {
                mixWeight = 0.25;

                if (blockId == BLOCK_WALL_POST_TALL_ALL || blockId == BLOCK_WALL_TALL_ALL
                      || blockId == BLOCK_WALL_POST_TALL_N_W_S
                      || blockId == BLOCK_WALL_POST_TALL_N_E_S
                      || blockId == BLOCK_WALL_POST_TALL_W_N_E
                      || blockId == BLOCK_WALL_POST_TALL_W_S_E) {
                    mixMask = BuildLpvMask(0u, 0u, 0u, 0u, 1u, 1u);
                    mixWeight = 0.125;
                }
                else if (blockId == BLOCK_WALL_POST_TALL_N_S || blockId == BLOCK_WALL_TALL_N_S) {
                    mixMask = BuildLpvMask(1u, 0u, 1u, 0u, 1u, 1u);
                }
                else if (blockId == BLOCK_WALL_POST_TALL_W_E || blockId == BLOCK_WALL_TALL_W_E) {
                    mixMask = BuildLpvMask(0u, 1u, 0u, 1u, 1u, 1u);
                }
                // TODO: more walls
            }

            // Misc

            if (blockId == BLOCK_SIGN) {
                mixWeight = 0.9;
            }

            // Entities

            if (blockId == ENTITY_BLAZE) {
                lightColor = vec3(1.000, 0.592, 0.000);
                lightRange = 8.0;
            }

            if (blockId == ENTITY_END_CRYSTAL) {
                lightColor = vec3(1.000, 0.000, 1.000);
                lightRange = 8.0;
            }

            if (blockId == ENTITY_FIREBALL_SMALL) {
                lightColor = vec3(0.000, 1.000, 0.000);
                lightRange = 8.0;
                mixWeight = 1.0;
            }

            if (blockId == ENTITY_GLOW_SQUID) {
                lightColor = vec3(0.180, 0.675, 0.761);
                lightRange = 6.0;
                mixWeight = 0.5;
            }

            if (blockId == ENTITY_MAGMA_CUBE) {
                lightColor = vec3(0.747, 0.323, 0.110);
                lightRange = 9.0;
            }

            if (blockId == ENTITY_TNT) {
                lightColor = vec3(1.0);
                lightRange = 8.0;
            }

            if (blockId == ENTITY_SPECTRAL_ARROW) {
                lightColor = vec3(0.839, 0.541, 0.2);
                lightRange = 8.0;
                mixWeight = 1.0;
            }

            // hack to increase light (if set)
            if (lightRange > 0.0) lightRange += 1.0;

            // apply saturation changes to light color
            const float saturationF = LPV_SATURATION / 100.0;
            mat4 matSaturation = GetSaturationMatrix(saturationF);
            lightColor = (matSaturation * vec4(lightColor, 1.0)).rgb;

            // apply saturation changes to tint color
            const float tintSaturationF = LPV_TINT_SATURATION / 100.0;
            mat4 matTintSaturation = GetSaturationMatrix(tintSaturationF);
            tintColor = (matTintSaturation * vec4(tintColor, 1.0)).rgb;

            // lazy fix for migrating from mixWeight to tintColor
            tintColor *= mixWeight;

            // Anything that emits light must be able to pass it.
            //
            // The fill seeds an emitter's own voxel with its light, and that light
            // then has to leave the voxel to reach anything else. sampleShared asks
            // the table for the mask, and a torch - like everything else that is not
            // a cube - would come back closed. So it would light the single voxel it
            // occupies and nothing else, which looks exactly like a torch that does
            // not work.
            //
            // Keyed off lightRange rather than a list of the seventy-odd emitters,
            // because they all set a range and a range of zero means the block does
            // not emit. So this cannot open a block that was meant to stay solid, and
            // it cannot be forgotten when a new emitter is added to the table above.
            if (lightRange > 0.0)
                mixMask = BuildLpvMask(1u, 1u, 1u, 1u, 1u, 1u);

            uint lightColorRange = packUnorm4x8(vec4(lightColor, lightRange/255.0));
            uint tintColorMask = packUnorm4x8(vec4(tintColor, 0.0));
            tintColorMask |= mixMask << 24;


    return uvec2(lightColorRange, tintColorMask);
}

// Deliberately no convenience wrapper around this, such as
//
//     vec3 ptBlockLightColour(int blockId) {
//         return unpackUnorm4x8(ptBlockLightData(blockId).r);
//     }
//
// It was here, and it stopped the entire pack from drawing. `unpackUnorm4x8`
// returns a vec4 and the function returned a vec3; the compatibility profile
// truncates that silently, and the core profile - which is what the engine emits,
// `#version 460 core` - does not:
//
//     'return' : cannot convert return value to function return type
//
// Nothing called it, and it made no difference that nothing called it: GLSL
// compiles every function in a file, so a wrong one in an unreached corner of an
// include is exactly as fatal as one on the hot path. If a wrapper is ever wanted,
// it has to say `.rgb` itself.
