// Mika-style lightweight multiplicative fake shadow decal disc (W3):
// Soft cool blue-violet contact shadow pools blended over ground/surfaces with zero real-time
// shadow maps and zero depth-buffer copy. Hidden by default when cost is unnecessary.
shader_type spatial;
render_mode unshaded, fog_disabled, blend_mul, depth_draw_never, cull_back;

#include "res://shaders/stillwater.gdshaderinc"

uniform float global_strength = 1.0;

varying vec2 v_uv;
varying vec4 v_shadow; // rgb: shadow tint, a: strength

void vertex() {
	v_uv = UV;
	v_shadow = INSTANCE_CUSTOM;
}

void fragment() {
	vec2 q = v_uv * 2.0 - 1.0;
	float r2 = clamp(dot(q, q), 0.0, 1.0);
	float fall = (1.0 - r2) * (1.0 - r2);
	float k = clamp(fall * v_shadow.a * global_strength, 0.0, 0.85);
	vec3 mul_col = mix(vec3(1.0), v_shadow.rgb, k);
	ALBEDO = godot_out(clamp(w_denan(mul_col, vec3(1.0)), vec3(0.0), vec3(1.0)));
}
