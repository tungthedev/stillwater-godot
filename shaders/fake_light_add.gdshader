// Mika-style lightweight additive fake light volume (W3):
// Soft radial warm glow spheres blended over the scene with zero OmniLight3D and zero depth-buffer
// copy (TBDR-safe on iPhone). Kept hidden by day (0 draws); driven by time-of-day glow in W5.
shader_type spatial;
render_mode unshaded, fog_disabled, blend_add, depth_draw_never, cull_back;

#include "res://shaders/stillwater.gdshaderinc"

uniform float global_intensity = 0.0;

varying vec3 v_wn;
varying vec3 v_wpos;
varying vec4 v_light; // rgb: linear light color, a: per-light intensity

void vertex() {
	vec3 wp = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	mat3 m = mat3(MODEL_MATRIX);
	v_wn = w_normalize(m * NORMAL);
	v_wpos = wp;
	v_light = INSTANCE_CUSTOM;
}

void fragment() {
	vec3 vw = w_normalize(CAMERA_POSITION_WORLD - v_wpos);
	float ndv = max(dot(w_normalize(v_wn), vw), 0.0);
	// Soft quadratic-cubic spherical glow falloff (zero pow of negative).
	float fall = ndv * ndv * ndv;
	vec3 glow = v_light.rgb * (v_light.a * global_intensity * fall);
	glow = w_denan(glow, vec3(0.0));
	// When post is on, output linear HDR directly for additive bloom; when post is off, scale softly.
	ALBEDO = post_on > 0.5 ? godot_out(clamp(glow, vec3(0.0), vec3(12.0))) : godot_out(clamp(glow * 0.65, vec3(0.0), vec3(1.0)));
}
