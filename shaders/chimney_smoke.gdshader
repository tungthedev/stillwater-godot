// Cottage chimney woodsmoke plume (W5):
// 20 small camera-facing billowing puffs rising gently from the cobbled stone chimney pot,
// curling downwind purely in vertex via TIME (0.000 ms GDScript). Distance-culled at 520 m so
// forest, lake and waterfall pay 0 draws. Soft radial + noise feathering, zero hard card edges.
shader_type spatial;
render_mode unshaded, fog_disabled, blend_mix, depth_draw_never, cull_disabled, skip_vertex_transform;

#include "res://shaders/stillwater.gdshaderinc"
#include "res://shaders/atmosphere.gdshaderinc"

uniform float smoke_strength = 1.0;

varying vec2 v_q;
varying float v_seed;
varying float v_alpha;
varying vec3 v_col;
varying vec3 v_atm_mul;
varying vec3 v_atm_add;

void vertex() {
	vec3 cam = CAMERA_POSITION_WORLD;
	vec3 origin = MODEL_MATRIX[3].xyz;
	float phase = INSTANCE_CUSTOM.x;
	float seed = INSTANCE_CUSTOM.y;

	float t = fract(phase + TIME * 0.075);
	vec2 wdir = w_normalize(vec3(wind_dir.x, 0.0, wind_dir.y)).xz;
	vec2 wperp = vec2(-wdir.y, wdir.x);
	float sway = sin(t * 7.0 + seed * 19.0 + TIME * 0.55) * (0.35 + t * 1.15);
	vec3 center = origin;
	center.y += t * 14.5;
	center.xz += wdir * (t * t * 6.8 + t * 1.4) + wperp * sway;

	vec3 to_cam = w_normalize(cam - center);
	vec3 right = w_normalize(cross(vec3(0.0, 1.0, 0.0), to_cam));
	if (dot(right, right) < 0.01) {
		right = vec3(1.0, 0.0, 0.0);
	}
	vec3 upv = cross(to_cam, right);

	float rad = mix(0.42, 2.75, pow(max(t, 0.0), 0.72));
	vec3 wp = center + (right * VERTEX.x + upv * VERTEX.y) * rad;
	POSITION = PROJECTION_MATRIX * (VIEW_MATRIX * vec4(wp, 1.0));

	v_q = VERTEX.xy;
	v_seed = seed;

	float dist = length(cam - center);
	float dist_fade = smoothstep(3.0, 9.0, dist) * w_rstep(520.0, 320.0, dist);
	float env_a = smoothstep(0.0, 0.14, t) * w_rstep(1.0, 0.30, t);
	v_alpha = env_a * 0.44 * dist_fade * smoke_strength;

	// Warm sunlit cream-grey woodsmoke by day, luminous lavender-silver mist at dusk & night.
	vec3 sky_up = w_sky(vec3(0.0, 1.0, 0.0));
	vec3 day_smoke = (mix(hemi_sky, sky_up, 0.40) * 0.95 + light_col * 0.24) * vec3(0.96, 0.95, 0.94);
	vec3 night_smoke = mix(hemi_sky, vec3(0.54, 0.68, 0.98), 0.58) * 1.18;
	v_col = mix(day_smoke, night_smoke, night_weight);

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
	vec2 uv_n = (v_q * 0.5 + 0.5) * 0.82 + vec2(v_seed * 3.7, v_seed * 6.1 - TIME * 0.03);
	float billow = texture(noise_tex, uv_n).a;
	float edge = w_rstep(1.0, 0.10, r2);
	float a = edge * smoothstep(0.16, 0.74, billow) * v_alpha;
	vec3 col = v_col * v_atm_mul + v_atm_add;
	ALBEDO = w_grade(col, SCREEN_UV, VIEWPORT_SIZE);
	ALPHA = clamp(a, 0.0, 0.55);
}
