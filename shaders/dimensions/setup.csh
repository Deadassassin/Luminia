// FauxTracer - the LPV setup pass is now a no-op
// ---------------------------------------------------------------------------
// This used to build a 1D storage image of per-block light colour, range and
// tint, by running a comparison chain per block id. It had two problems on this
// engine:
//
//   1. 1D is not one of the bindable sampler shapes - the set is 2D, 2DShadow,
//      2DArray, 2DArrayShadow, 2DMS, 2DMSArray, Cube, CubeShadow, CubeArray,
//      CubeArrayShadow, with any i/u prefix stripped - so the pass that read the
//      image would not compile at all:
//
//        compute world0/shadowcomp SPIR-V failed: ShaderCompileException:
//        Unsupported texture dimensions '1D' for sampler imgBlockData
//
//   2. The engine skips this pass outright, reporting "compute programs skipped,
//      no stage exists for them yet: [setup]". So the image was never written
//      even in principle, and everything that read it was reading whatever the
//      allocator handed back.
//
// Fixing (1) alone would have fixed neither, because the writer does not run.
//
// The fix was to stop needing the buffer. Every entry in the table is a
// compile-time constant selected by block id, so the table is now a function -
// ptBlockLightData() in lib/lpv_blocks.glsl - and there is nothing left for a
// setup pass to do. tools/port_lpv_table.py generates that function from what
// this file used to contain, so the table is still the same table.
//
// The file is kept, empty, on purpose. shaders.properties switches it off and the
// engine skips it regardless, but deleting it would leave those directives and
// any reference to the name dangling, and a program the pack lists but does not
// ship is reported differently from one it ships and does not run.

layout (local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

const ivec3 workGroups = ivec3(6, 6, 1);

void main() {
	// Intentionally empty. See above.
}
