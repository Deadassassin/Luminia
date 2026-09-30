#version 120

#include "/lib/settings.glsl"

// Fragment half of the entity shadow pass. Its only job is to write the entity's
// colour and alpha into the shadow map, tinted by vertex colour, with
// alpha-tested fragments discarded - which is what gives the shadow the shape of
// the model rather than of its bounding box.
//
// Mirrors world0/shadow.fsh, which is the terrain half. Keeping the two
// structurally identical is deliberate: they write into the same attachment, and
// any difference between them shows up as a visible seam between a block's shadow
// and a mob's.

varying vec4 color;

varying vec2 texcoord;
uniform sampler2D tex;
uniform sampler2D noisetex;

//////////////////////////////VOID MAIN//////////////////////////////
//////////////////////////////VOID MAIN//////////////////////////////
//////////////////////////////VOID MAIN//////////////////////////////

float blueNoise(){
  return fract(texelFetch2D(noisetex, ivec2(gl_FragCoord.xy)%512, 0).a + 1.0/1.6180339887 );
}

void main() {
	gl_FragData[0] = vec4(texture2D(tex,texcoord.xy).rgb * color.rgb,  texture2DLod(tex, texcoord.xy, 0).a);

  	#ifdef Stochastic_Transparent_Shadows
		if(gl_FragData[0].a < blueNoise()) { discard; return;}
  	#endif
}
