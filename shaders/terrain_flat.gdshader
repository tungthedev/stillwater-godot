// Minimal terrain shader for ?bench=sweep's terrain_flat variant: runs the exact same CDLOD
// vertex placement and skirt depth as terrain.gdshader so depth occlusion is identical, while
// replacing the fragment shader with a single flat colour to isolate terrain fragment cost.
shader_type spatial;
render_mode unshaded, fog_disabled, cull_back;

uniform sampler2D noise_tex : filter_linear_mipmap, repeat_enable;

#include "res://shaders/world.gdshaderinc"

uniform float grid_n = 32.0;
uniform float lod_k = 3.0;
uniform float cam_dy;
uniform float skirt_on = 1.0;

void vertex() {
	float size = INSTANCE_CUSTOM.z;
	vec2 grid = floor(VERTEX.xz * grid_n + 0.5);
	vec2 xz = INSTANCE_CUSTOM.xy + VERTEX.xz * size;
	float d = length(vec2(length(xz - CAMERA_POSITION_WORLD.xz), cam_dy));
	float morph = clamp((d / (lod_k * size) - 1.55) / 0.35, 0.0, 1.0);
	if (size >= 16384.0) morph = 0.0;
	vec2 frac_g = fract(grid * 0.5) * 2.0;
	xz -= frac_g * (size / grid_n) * morph;
	float h = w_height(xz) - UV.x * (2.0 + size * 0.015) * skirt_on;
	VERTEX = vec3(xz.x, h, xz.y);
	NORMAL = vec3(0.0, 1.0, 0.0);
}

void fragment() {
	ALBEDO = vec3(0.22, 0.34, 0.18);
}
