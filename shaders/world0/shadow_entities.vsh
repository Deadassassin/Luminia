#version 120
#include "/lib/settings.glsl"

/*
   Entity shadows: your own silhouette, and mobs'.

   WHY THIS FILE EXISTS
   -------------------
   The shadow map is rendered, filtered with 13 taps, and sampled by the surface
   lighting at composite1.fsh:1048 via ComputeShadowMap. All of that was working.
   What was missing is anything to put an entity INTO the map. The engine asks for
   a program named shadow_entities (confirmed in the jar:
   dev/vitrail/pack/model/ProgramFallbacks lists shadow, shadow_solid,
   shadow_cutout, shadow_water, shadow_entities, shadow_lightning, shadow_block),
   and Penumbra had no shadow_entities.vsh or .fsh to answer it.

   So the map held terrain and nothing else. No player, no mobs, no dropped items.
   There was no silhouette in it to sample, which is why walking past a torch
   produced no shadow - not a faint one, none. Mob textures were not being read
   into the map at all.

   Eclipse has this pair. Rethinking Voxels does not, and it does not cast entity
   shadows either. That is the whole difference between them on this feature.

   WHAT IS HERE
   ------------
   The entity arrives in view space. shadow.vsh does exactly the same job for
   terrain: transform to the shadow camera's space, project, bias, divide z. That
   is the entire content of this file beyond the boilerplate.

   Cut down from Chocapic13's shadow_entities as it survives in Eclipse. Removed,
   because none of it applies here:
     - the LPV voxel write. A player is not a block, and writing an entity into
       the voxel mask is how mob and dropped-item lights get into the flood fill,
       which is a different feature from casting a shadow.
     - WAVY_PLANTS, PLANET_CURVATURE, CUSTOM_MOON_ROTATION, DISTORT_SHADOWMAP
     - the Distant Horizons dither fade
     - the lightning discard, which needs entityId and an entities header

   Kept, because they are what put the silhouette in the map at the right place:
   the world -> shadow-view transform, toClipSpace3, the projection bias, and the
   z divide.
*/

#define RENDER_SHADOW
#define ENTITIES_SHADOW

#define SHADOW_MAP_BIAS 0.5
const float PI = 3.1415927;

varying vec4 color;
varying vec2 texcoord;
varying vec3 playerpos;

uniform float frameTimeCounter;
uniform mat4 shadowProjectionInverse;
uniform mat4 shadowProjection;
uniform mat4 shadowModelViewInverse;
uniform mat4 shadowModelView;
uniform mat4 gbufferModelView;
uniform mat4 gbufferModelViewInverse;
uniform mat4 gbufferProjection;
uniform mat4 gbufferProjectionInverse;
uniform int hideGUI;
uniform vec3 cameraPosition;
uniform vec3 relativeEyePosition;
uniform float screenBrightness;
uniform vec3 sunVec;
uniform float aspectRatio;
uniform float sunElevation;
uniform vec3 sunPosition;
uniform float lightSign;
uniform float cosFov;
uniform vec3 shadowViewDir;
uniform vec3 shadowCamera;
uniform vec3 shadowLightVec;
uniform float shadowMaxProj;

vec3 viewToWorld(vec3 viewPos) {
    vec4 pos;
    pos.xyz = viewPos;
    pos.w = 0.0;
    pos = shadowModelViewInverse * pos;
    return pos.xyz;
}

#include "/lib/Shadow_Params.glsl"

// These two are #defines rather than functions inside shadow.vsh, so they are
// repeated here. There is no shared header for them, and adding one for two
// macros would be a larger change than this file.
#define diagonal3(m) vec3((m)[0].x, (m)[1].y, m[2].z)
#define  projMAD(m, v) (diagonal3(m) * (v) + (m)[3].xyz)

uniform float dhFarPlane;

#include "/lib/DistantHorizons_projections.glsl"

vec4 toClipSpace3(vec3 viewSpacePosition) {
    return vec4(projMAD(gl_ProjectionMatrix, viewSpacePosition), 1.0);
}

void main() {
	texcoord.xy = gl_MultiTexCoord0.xy;
	color = gl_Color;

	vec3 position = mat3(gl_ModelViewMatrix) * vec3(gl_Vertex) + gl_ModelViewMatrix[3].xyz;

	playerpos = mat3(shadowModelViewInverse) * position + shadowModelViewInverse[3].xyz;

	vec3 worldpos = playerpos;

	position = mat3(shadowModelView) * worldpos + shadowModelView[3].xyz;

	// The bias, matching shadow.vsh. Without it the surface facing the light is
	// inside its own depth and the entity stipples against itself.
	#ifdef DISTORT_SHADOWMAP
		gl_Position = BiasShadowProjection(toClipSpace3(position));
	#else
		gl_Position = toClipSpace3(position);
	#endif

	// Also matching shadow.vsh, and not a mistake: this pack's shadow projection
	// is scaled by 6, and every writer into the map divides by the same factor so
	// they agree. Omitting it puts the entity at the wrong depth - either invisible,
	// or occluding the terrain in front of it.
	gl_Position.z /= 6.0;
}
