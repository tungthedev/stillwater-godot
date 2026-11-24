// Painterly opaque stream + waterfall plunge pool (W2, 1 draw call, render_priority = -1).
// UV  = (across [-1..1], dist_along_m) for stream; (r_norm [0..1], 0) for plunge pool.
// UV2 = (steep [0..1], is_pool {0 = stream, 1 = plunge pool}).
// Zero alpha blending and zero discard; outer vertices tuck gently into the carved channel banks
// so the hardware depth test cuts an exact shoreline and heightmap depth drives crisp bank foam.
shader_type spatial;
render_mode unshaded, fog_disabled, cull_back, depth_draw_opaque;

#include "res://shaders/stillwater.gdshaderinc"
#include "res://shaders/atmosphere.gdshaderinc"
#include "res://shaders/world.gdshaderinc"

uniform vec3 impact_pt = vec3(-898.19, 132.59, 113.76);
uniform vec3 pool_center = vec3(-893.95, 132.59, 118.0);
uniform float pool_radius = 19.0;

varying vec3 v_wpos;
varying vec2 v_uv;
varying vec2 v_uv2;
varying vec3 v_atm_mul;
varying vec3 v_atm_add;
varying float v_cloud_sh;

void vertex() {
	vec3 wp = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	v_wpos = wp;
	v_uv = UV;
	v_uv2 = UV2;
	vec3 am;
	vec3 aa;
	w_atmosphere(wp, CAMERA_POSITION_WORLD, am, aa);
	v_atm_mul = am;
	v_atm_add = aa;
	v_cloud_sh = w_cloud_shadow_v(wp, CAMERA_POSITION_WORLD);
}

void fragment() {
	vec3 wp = v_wpos;
	float ground = w_height_near(wp.xz);
	float depth = max(wp.y - ground, 0.0);

	vec3 cam = CAMERA_POSITION_WORLD;
	vec3 to_cam = cam - wp;
	float dist = length(to_cam);
	vec3 V = w_normalize(to_cam);

	float t = TIME;
	float sun_up = clamp(sun_dir.y * 3.0, 0.0, 1.0);
	vec3 amb = w_sky(vec3(0.0, 1.0, 0.0));
	vec3 amb_fill = mix(hemi_sky, amb, 0.45) * shadow_ambient_tint * ambient_boost;
	vec3 foam_col = (amb_fill * 1.02 + light_col * 0.28 * sun_up * v_cloud_sh) * vec3(0.96, 0.99, 1.0);

	vec3 col;
	vec3 N;
	float foam = 0.0;

	if (v_uv2.y > 0.5) {
		// ---- Plunge pool: sapphire center -> turquoise rim + crisp scalloped expanding foam rings ----
		vec2 d_c = wp.xz - pool_center.xz;
		float r = clamp(length(d_c) / max(pool_radius, 1.0), 0.0, 1.2);
		vec2 d_i = wp.xz - impact_pt.xz;
		float ri = length(d_i) / max(pool_radius, 1.0);
		float ang_i = (abs(d_i.x) + abs(d_i.y) > 1e-4) ? atan(d_i.y, d_i.x) : 0.0;

		vec4 n1 = texture(noise_tex, wp.xz * 0.095 + vec2(t * 0.045, -t * 0.055));
		vec4 n2 = texture(noise_tex, wp.xz * 0.24 - vec2(t * 0.075, t * 0.065) + vec2(0.31, 0.57));

		float scallop = 0.052 * sin(ang_i * 8.0 + n1.a * 4.2) + 0.028 * cos(ang_i * 14.0 - n2.g * 3.2);
		float fw_r = clamp(fwidth(ri) * 1.4, 0.008, 0.06);

		// Churning whitewater core right beneath the cascade impact.
		float impact_core = w_rstep(0.28 + fw_r, max(0.28 - fw_r, 0.01), ri + scallop + (n2.g - 0.5) * 0.08);
		// Two crisp scalloped Ghibli foam rings expanding outward across the turquoise pool.
		float ring1_d = abs(ri - 0.48 + scallop * 0.9);
		float ring1 = w_rstep(0.062 + fw_r, max(0.024 - fw_r * 0.5, 0.002), ring1_d) * smoothstep(0.30, 0.50, n1.a * 0.55 + n2.b * 0.45);
		float ring2_d = abs(ri - 0.74 + scallop * 1.25);
		float ring2 = w_rstep(0.048 + fw_r, max(0.016 - fw_r * 0.5, 0.002), ring2_d) * smoothstep(0.40, 0.60, n2.g * 0.5 + n2.b * 0.5) * 0.88;
		// Crisp painted shoreline foam along pool rock rim.
		float d_wob = depth + (n1.a - 0.5) * 0.18;
		float fw_d = clamp(fwidth(d_wob) * 1.2, 0.01, 0.10);
		float bank_foam = w_rstep(0.18 + fw_d, max(0.18 - fw_d, 0.001), d_wob);

		foam = clamp(max(max(impact_core, ring1), max(ring2, bank_foam * 0.90)), 0.0, 0.96);

		float wave_p = ri * 16.0 - t * 2.8 + (n1.a - 0.5) * 2.6;
		vec2 r_dir = w_normalize(vec3(d_i.x, 0.0, d_i.y)).xz;
		vec2 g_r = r_dir * cos(wave_p) * 0.08 * w_rstep(1.05, 0.1, ri);
		N = w_normalize(vec3(g_r.x + (n2.g - 0.5) * 0.12, 1.0, g_r.y + (n2.b - 0.5) * 0.12));

		vec3 deep_p = vec3(0.014, 0.165, 0.375);
		vec3 turq_p = vec3(0.062, 0.455, 0.465);
		vec3 body_tint = mix(deep_p, turq_p, smoothstep(0.18, 0.85, r));
		col = body_tint * (amb_fill * 1.48 + light_col * 0.18 * sun_up * v_cloud_sh);
		col = w_light_floor(col, body_tint);
	} else {
		// ---- Stream: flow-direction painted streaks + crisp bank shoreline foam ----
		float across = abs(v_uv.x);
		float steep = v_uv2.x;
		float speed = 1.45 + steep * 4.2;
		vec2 flow_uv = vec2(v_uv.x * 0.55, v_uv.y * 0.062);
		vec4 n1 = texture(noise_tex, flow_uv - vec2(0.0, t * speed * 0.065));
		vec4 n2 = texture(noise_tex, flow_uv * vec2(2.3, 2.6) - vec2(0.0, t * speed * 0.125) + vec2(0.37, 0.21));

		// Depth-graded turquoise shallow banks -> alpine sapphire current center.
		float center_k = w_rstep(0.76, 0.14, across) * smoothstep(0.06, 0.36, depth);
		vec3 col_shallow = vec3(0.068, 0.445, 0.455);
		vec3 col_deep    = vec3(0.016, 0.170, 0.385);
		vec3 body_tint = mix(col_shallow, col_deep, center_k);
		// Subtle painted darker current ribbons in the center channel for flow readability.
		float dark_ribbon = smoothstep(0.56, 0.72, n1.r * 0.6 + n2.b * 0.4) * center_k;
		body_tint = mix(body_tint, col_deep * 0.78, dark_ribbon * 0.35);
		col = body_tint * (amb_fill * 1.48 + light_col * 0.17 * sun_up * v_cloud_sh);
		col = w_light_floor(col, body_tint);

		// Crisp painted flow-direction streaks & rapids whitewater.
		float streak_n = n1.b * 0.52 + n2.g * 0.48;
		float rapid = clamp(steep * 1.75 - 0.12, 0.0, 1.0);
		float fw_s = clamp(fwidth(streak_n) * 1.1, 0.02, 0.10);
		float streak_th = mix(0.76, 0.60, rapid);
		float streak_foam = smoothstep(streak_th - fw_s, streak_th + fw_s, streak_n) * (0.26 + 0.64 * rapid);

		// Crisp, delicate painted shoreline foam along both banks (never a thick white border).
		float d_wob = depth + (n1.a - 0.5) * 0.08 + (n2.g - 0.5) * 0.04;
		float fw_d = clamp(fwidth(d_wob) * 1.15, 0.008, 0.07);
		float depth_rim = w_rstep(0.11 + fw_d, max(0.11 - fw_d, 0.001), d_wob) * smoothstep(0.28, 0.52, n1.a * 0.55 + n2.b * 0.45);
		float edge_rim = smoothstep(0.82, 0.94, across + (n2.g - 0.5) * 0.12) * smoothstep(0.42, 0.66, n1.a * 0.5 + n2.b * 0.5);
		float bank_foam = clamp(max(depth_rim * 0.88, edge_rim * 0.76), 0.0, 0.90);

		// Visible bright ribbon from across the lake (distant steep cascade readability).
		float dist_white = smoothstep(0.14, 0.36, steep) * smoothstep(160.0, 420.0, dist) * 0.72;
		foam = clamp(max(max(streak_foam, bank_foam), dist_white), 0.0, 0.95);

		float near_k = mix(1.0, 0.35, smoothstep(50.0, 350.0, dist));
		N = w_normalize(vec3(((n1.r - 0.5) * 0.16 + (n2.g - 0.5) * 0.12) * near_k, 1.0, ((n1.g - 0.5) * 0.16 - (n2.b - 0.5) * 0.12) * near_k));
	}

	// Cheap sky-tinted Fresnel reflection + soft clamped sun sheen.
	float cos_t = max(dot(N, V), 0.0);
	float fres = clamp(0.08 + 0.68 * pow(max(1.0 - cos_t, 0.0), 3.6), 0.0, 0.72) * (1.0 - foam * 0.85);
	vec3 R = reflect(-V, N);
	vec3 sky_refl = w_horizon_color(w_normalize(vec3(R.x, max(R.y, 0.08), R.z)));
	col = mix(col, sky_refl * 0.88, fres * 0.42);

	vec3 H = w_normalize(sun_dir + V);
	float nh = max(dot(N, H), 0.0);
	float sheen = min(pow(nh, 120.0) * 2.4 + pow(nh, 26.0) * 0.45, 2.0) * sun_up * v_cloud_sh * (1.0 - foam * 0.65);
	col += light_col * vec3(1.0, 0.96, 0.86) * sheen * 0.20;

	col = mix(col, foam_col, foam);
	col = col * v_atm_mul + v_atm_add;
	ALBEDO = w_grade(col, SCREEN_UV, VIEWPORT_SIZE);
}
