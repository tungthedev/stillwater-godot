// Painterly chunky faceted rocks (W3): Genshin-style blur-slope rock shader with 1 noise fetch
// (replaces 9-tap 3-scale triplanar granite noise), crisp moss caps on top faces, alpine lichen,
// shoreline/waterfall wetness, and smooth distance shrink-out before CPU cull so rocks never pop.
// Opaque, zero discard, render_priority = -1.
shader_type spatial;
render_mode unshaded, fog_disabled, cull_back, depth_draw_opaque;

#include "res://shaders/stillwater.gdshaderinc"
#include "res://shaders/atmosphere.gdshaderinc"

uniform vec4 waterfall = vec4(-893.95, 132.59, 118.0, 58.0);
uniform float dist_scale = 1.0;

varying vec3 v_wpos;
varying vec3 v_wn;
varying vec3 v_atm_mul;
varying vec3 v_atm_add;
varying vec4 v_info; // x: cavity AO, y: hue seed, z: sun_vis, w: cam dist

void vertex() {
	vec3 ip = MODEL_MATRIX[3].xyz;
	vec3 cam = CAMERA_POSITION_WORLD;
	float cam_d = length(ip - cam);
	float max_d = max(INSTANCE_CUSTOM.x * dist_scale, 40.0);
	// Smooth shrink-out well inside the CPU cull radius so distant boulders never pop.
	float keep = 1.0 - smoothstep(max_d * 0.74, max_d, cam_d);
	VERTEX *= keep;

	vec3 wp = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	mat3 m = mat3(MODEL_MATRIX);
	vec3 inv_sq = vec3(
		1.0 / max(dot(m[0], m[0]), 1e-12),
		1.0 / max(dot(m[1], m[1]), 1e-12),
		1.0 / max(dot(m[2], m[2]), 1e-12)
	);
	v_wn = w_normalize(m * (NORMAL * inv_sq));
	v_wpos = wp;
	float sun_vis = w_cloud_shadow_v(ip + vec3(0.0, 1.0, 0.0), cam);
	v_info = vec4(CUSTOM0.r, INSTANCE_CUSTOM.y, sun_vis, cam_d);

	vec3 atm_mul;
	vec3 atm_add;
	w_atmosphere(wp, cam, atm_mul, atm_add);
	v_atm_mul = atm_mul;
	v_atm_add = atm_add;
}

void fragment() {
	vec3 wp = v_wpos;
	vec3 n = w_normalize(v_wn);
	float up = n.y;

	// Single cheap brushstroke noise fetch for blur-slope transitions and organic moss edges.
	vec4 nb = texture(noise_tex, wp.xz * 0.095 + vec2(wp.y * 0.115, -wp.y * 0.075));
	float brush = nb.r * 0.55 + nb.g * 0.45;
	float up_blur = up + (brush - 0.5) * 0.18;

	// 3-step painterly alpine granite planes: cool blue-slate shadow side -> warm mid bevel -> sunlit top.
	vec3 shadow_stone = vec3(0.22, 0.24, 0.32);
	vec3 mid_stone = vec3(0.47, 0.45, 0.43);
	vec3 top_stone = vec3(0.65, 0.61, 0.53);
	float s_mid = smoothstep(0.14, 0.32, up_blur);
	float s_top = smoothstep(0.56, 0.72, up_blur);
	vec3 base = mix(shadow_stone, mid_stone, s_mid);
	base = mix(base, top_stone, s_top);

	// Subtle per-rock warm/cool stone variety + baked facet crevice/edge modulation.
	float hue_v = v_info.y;
	base *= mix(vec3(0.95, 0.96, 1.03), vec3(1.05, 1.01, 0.94), hue_v);
	base *= (0.82 + 0.28 * v_info.x) * (0.94 + 0.12 * nb.b);

	// Moss cap on top faces below treeline (crisp cap that preserves faceted granite sides).
	float moss_field = up + (nb.g - 0.5) * 0.22 + (nb.a - 0.5) * 0.10;
	float low_moss = smoothstep(0.76, 0.88, moss_field) * w_rstep(405.0, 315.0, wp.y);
	vec3 moss_col = mix(vec3(0.068, 0.215, 0.052), vec3(0.150, 0.335, 0.070), smoothstep(0.30, 0.72, nb.b * 0.6 + nb.r * 0.4));
	base = mix(base, moss_col, low_moss * 0.82);

	// Warm sage alpine lichen at mid-high elevation.
	float high_lichen = smoothstep(0.64, 0.82, up * 0.70 + nb.g * 0.30) * smoothstep(330.0, 410.0, wp.y) * w_rstep(1150.0, 680.0, wp.y);
	vec3 lichen_col = mix(vec3(0.36, 0.40, 0.24), vec3(0.50, 0.48, 0.29), nb.r);
	base = mix(base, lichen_col, high_lichen * 0.50);

	// Wet darkened granite near lake shore & waterfall spray.
	float near_water = 1.0 - smoothstep(0.0, 1.25, abs(wp.y - water_level));
	float near_fall = waterfall.w > 0.1 ? (1.0 - smoothstep(waterfall.w * 0.35, waterfall.w, length(wp.xz - waterfall.xz))) : 0.0;
	float wet = clamp(max(near_water, near_fall * 0.85), 0.0, 1.0);
	base *= mix(1.0, 0.56, wet);

	// High-altitude snow dusting.
	float snow_k = smoothstep(1450.0, 1660.0, wp.y) * smoothstep(0.30, 0.70, up);
	base = mix(base, vec3(0.92, 0.94, 0.98), snow_k);

	// Matte painterly toon lighting + cool blue-violet ambient + light floor.
	float ramp = w_toon_ramp(dot(n, sun_dir), 0.22, 0.20, 0.48, v_info.w);
	vec3 direct = ramp * light_col * v_info.z * base / PI;
	vec3 ind = w_indirect(n, base);
	vec3 lit = w_light_floor(direct + ind, base);

	lit = lit * v_atm_mul + v_atm_add;
	ALBEDO = w_grade(lit, SCREEN_UV, VIEWPORT_SIZE);
}
