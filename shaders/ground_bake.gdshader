// Near-ring ground colour bake (systems/terrain.gd).
// Draws one 128 x 128 slot (125 usable intervals + 1 px gutter on every side) into the RGBA8
// SubViewport atlas. Texels 1 and 126 sit on the exact world tile edges, so neighbouring slots
// sample identical world coordinates at their boundary and bilinear filtering never bleeds across
// slots.
shader_type canvas_item;
render_mode blend_disabled;

#define W_NOISE(uv) textureLod(noise_tex, uv, 0.0)
#include "res://shaders/stillwater.gdshaderinc"
#include "res://shaders/world.gdshaderinc"
#include "res://shaders/ground_bake_common.gdshaderinc"

uniform vec2 tile_origin = vec2(0.0);
uniform vec2 slot_origin = vec2(0.0);
uniform float tile_size = 12.0;
uniform float slot_use = 125.0;

void fragment() {
	vec2 local_px = floor(FRAGCOORD.xy) - slot_origin;
	vec2 u = (local_px - vec2(1.0)) / slot_use;
	vec2 xz = tile_origin + u * tile_size;
	COLOR = bake_ground_albedo(xz, true);
}
