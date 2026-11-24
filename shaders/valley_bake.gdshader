// One-time 1024 x 1024 RGBA8 valley macro bake over the 4096 m near map ([-2048, +2048]^2).
// Serves as the mid-range terrain colour (beyond the near baked tile ring) and as the instant
// seamless fallback before a near tile finishes baking.
shader_type canvas_item;
render_mode blend_disabled;

#define W_NOISE(uv) textureLod(noise_tex, uv, 0.0)
#include "res://shaders/stillwater.gdshaderinc"
#include "res://shaders/world.gdshaderinc"
#include "res://shaders/ground_bake_common.gdshaderinc"

uniform float valley_res = 1024.0;

void fragment() {
	vec2 uv = FRAGCOORD.xy / valley_res;
	vec2 xz = (uv - vec2(0.5)) * near_size;
	COLOR = bake_ground_albedo(xz, false);
}
