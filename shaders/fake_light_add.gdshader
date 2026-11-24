// Mika-style lightweight additive fake light volume (W3/W5):
// Soft radial warm glow spheres and ground-hugging spill domes blended over the scene with zero
// OmniLight3D and zero depth-buffer copy (TBDR-safe on iPhone). Kept hidden by day (0 draws);
// driven by time-of-day glow in W5.
shader_type spatial;
render_mode unshaded, fog_disabled, blend_add, depth_draw_never, cull_back;

#include "res://shaders/stillwater.gdshaderinc"

uniform float global_intensity = 0.0;
// Optional per-mesh fallback color/intensity when rendered on a single MeshInstance3D (player warmth pool).
uniform vec4 single_light = vec4(1.0, 0.72, 0.34, 0.0);

varying vec3 v_wn;
varying vec3 v_wpos;
varying vec4 v_light; // rgb: linear light color, a: per-light intensity
varying float v_phase;

void vertex() {
	vec3 wp = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	mat3 m = mat3(MODEL_MATRIX);
	vec3 inv_sq = vec3(
		1.0 / max(dot(m[0], m[0]), 1e-12),
		1.0 / max(dot(m[1], m[1]), 1e-12),
		1.0 / max(dot(m[2], m[2]), 1e-12)
	);
	v_wn = w_normalize(m * (NORMAL * inv_sq));
	v_wpos = wp;
	v_light = single_light.a > 0.001 ? single_light : INSTANCE_CUSTOM;
	v_phase = MODEL_MATRIX[3].x * 0.73 + MODEL_MATRIX[3].z * 1.19;
}

void fragment() {
	vec3 vw = w_normalize(CAMERA_POSITION_WORLD - v_wpos);
	float ndv = max(dot(w_normalize(v_wn), vw), 0.0);
	// Soft cubic spherical glow falloff + subtle candle/hearth flicker (zero pow of negative).
	float fall = ndv * ndv * ndv;
	float flick = 0.93 + 0.07 * sin(TIME * 4.4 + v_phase);
	float master = single_light.a > 0.001 ? 1.0 : global_intensity;
	vec3 glow = v_light.rgb * (v_light.a * master * fall * flick);
	glow = w_denan(glow, vec3(0.0));
	// When post is on, output linear HDR directly for additive bloom; when post is off, scale softly.
	ALBEDO = post_on > 0.5 ? godot_out(clamp(glow, vec3(0.0), vec3(12.0))) : godot_out(clamp(glow * 0.72, vec3(0.0), vec3(1.0)));
}
