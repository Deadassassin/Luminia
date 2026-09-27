// Simulates the constants Iris injects into every shader before the pack source
// is preprocessed. Only used by tools/validate.py - it is NOT part of the pack.

#ifndef IRIS8
#define IRIS8

// GL internal formats, as accepted by the <buffer>Format const directive.
#define RGBA          0x1908
#define R8            0x8229
#define RG8           0x822B
#define RGB8          0x8051
#define RGBA8         0x8058
#define R16           0x822A
#define RG16          0x822C
#define RGB16         0x8054
#define RGBA16        0x805B
#define R16F          0x822D
#define RG16F         0x822F
#define RGB16F        0x881B
#define RGBA16F       0x881A
#define R32F          0x822E
#define RG32F         0x8230
#define RGB32F        0x8815
#define RGBA32F       0x8814
#define RGB10_A2      0x8059
#define RGBA4         0x8056
#define RGB5_A1       0x8057
#define RGB565        0x8D62
#define RGBA2         0x8055
#define R3_G3_B2      0x8032
#define R11F_G11F_B10F 0x8C3A

// Iris environment macros.
#define IS_IRIS 1
#define IRIS_VERSION 10011

// Render stages, as Iris defines them.
#define MC_RENDER_STAGE_NONE               0
#define MC_RENDER_STAGE_SKY                1
#define MC_RENDER_STAGE_SUNSET             2
#define MC_RENDER_STAGE_CUSTOM_SKY         3
#define MC_RENDER_STAGE_SUN                4
#define MC_RENDER_STAGE_MOON               5
#define MC_RENDER_STAGE_STARS              6
#define MC_RENDER_STAGE_VOID               7
#define MC_RENDER_STAGE_TERRAIN_SOLID      8
#define MC_RENDER_STAGE_ENTITIES           9
#define MC_RENDER_STAGE_BLOCK_ENTITIES     10
#define MC_RENDER_STAGE_DESTROY            11
#define MC_RENDER_STAGE_OUTLINE            12
#define MC_RENDER_STAGE_DEBUG              13
#define MC_RENDER_STAGE_HAND_SOLID         14
#define MC_RENDER_STAGE_TERRAIN_TRANSLUCENT 15
#define MC_RENDER_STAGE_TRIPWIRE           16
#define MC_RENDER_STAGE_PARTICLES          17
#define MC_RENDER_STAGE_CLOUDS             18
#define MC_RENDER_STAGE_RAIN_SNOW          19
#define MC_RENDER_STAGE_WORLD_BORDER       20
#define MC_RENDER_STAGE_HAND_TRANSLUCENT   21

// Uniform / matrix names that Iris (and vanilla) provide. Declaring them keeps
// glslangValidator happy; the real values come from the game at runtime.
// The legacy gl_* built-ins (gl_ModelViewMatrix, gl_NormalMatrix,
// gl_TextureMatrix, gl_FragData, ...) still exist in the compatibility profile,
// so they must NOT be redeclared here.
uniform mat4 shadowModelView;
uniform mat4 shadowModelViewInverse;
uniform mat4 shadowProjection;
uniform mat4 shadowProjectionInverse;
uniform mat4 gbufferPreviousModelViewInverse;
uniform mat4 gbufferPreviousProjectionInverse;
uniform float alphaTestRef;

#endif
