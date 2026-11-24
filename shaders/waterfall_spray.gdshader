// Waterfall plunge-pool mist & crest-lip spray puffs (W4):
// 28 small animated camera-facing billow quads anchored at the plunge pool flanks and top lip
// (culled outside 450 m -> 0 draws everywhere except waterfall). Pure vertex animation via TIME
// (0.000 ms GDScript), soft radial + noise billow feathering (zero hard card edges).
shader_type spatial;
render_mode unshaded, fog_disabled, blend_mix, depth_draw_never, cull_disabled, skip_vertex_transform;

#include "res://shaders/stillwater.gdshaderinc"
#include "res://shaders/atmosphere.gdshaderinc"

uniform float spray_strength = 1.0;

varying vec2 v_q;
varying float v_seed;
varying float v_alpha;
varying vec3 v_col;
varying vec3 v_atm_mul;
varying vec3 v_atm_add;

void vertex() {
	vec3 cam = CAMERA_POSITION_WORLD;
	vec3 origin = MODEL_MATRIX[3].xyz;
	// Pack drift vector in MODEL_MATRIX[0].xyz and base radius in MODEL_MATRIX[1].y.
	vec3 drift = MODEL_MATRIX[0].xyz;
	float base_r = MODEL_MATRIX[1].y;
	float seed = INSTANCE_CUSTOM.x;
	float alpha_scale = INSTANCE_CUSTOM.y;

	float t = fract(seed * 3.7 + TIME * 0.17);
	vec3 center = origin + drift * t;

	vec3 to_cam = w_normalize(cam - center);
	vec3 right = w_normalize(cross(vec3(0.0, 1.0, 0.0), to_cam));
	if (dot(right, right) < 0.01) {
		right = vec3(1.0, 0.0, 0.0);
	}
	vec3 upv = cross(to_cam, right);

	float rad = base_r * (0.72 + t * 0.78);
	vec3 wp = center + (right * VERTEX.x + upv * VERTEX.y) * rad;
	POSITION = PROJECTION_MATRIX * (VIEW_MATRIX * vec4(wp, 1.0));

	v_q = VERTEX.xy;
	v_seed = seed;

	float dist = length(cam - center);
	float dist_fade = smoothstep(4.5, 13.0, dist) * w_rstep(440.0, 250.0, dist);
	v_alpha = sin(t * 3.1415926) * mix(0.32, 0.06, t) * alpha_scale * dist_fade * spray_strength;

	float sun_up = clamp(sun_dir.y * 3.0, 0.0, 1.0);
	vec3 amb = w_sky(vec3(0.0, 1.0, 0.0));
	vec3 amb_fill = mix(hemi_sky, amb, 0.45) * shadow_ambient_tint * ambient_boost;
	v_col = (amb_fill * 1.02 + light_col * 0.28 * sun_up) * vec3(0.95, 0.99, 1.0);

	vec3 am;
	vec3 aa;
	w_atmosphere(center, cam, am, aa);
	v_atm_mul = am;
	v_atm_add = aa;
}

void fragment() {
	float r2 = dot(v_q, v_q);
	if (r2 > 1.0) {
		discard;
	}
	vec2 uv_n = (v_q * 0.5 + 0.5) * 0.76 + vec2(v_seed * 3.1, v_seed * 5.7 - TIME * 0.04);
	float billow = texture(noise_tex, uv_n).a;
	float edge = w_rstep(1.0, 0.12, r2);
	float a = edge * smoothstep(0.14, 0.76, billow) * v_alpha;
	vec3 col = v_col * v_atm_mul + v_atm_add;
	ALBEDO = w_grade(col, SCREEN_UV, VIEWPORT_SIZE);
	ALPHA = clamp(a, 0.0, 0.62);
}
