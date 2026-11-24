// Painterly chunky faceted rocks: crisp 3-tone painted granite (lit warm top/bevel vs cool
// blue-violet shadow side), 1-tap brushstroke blur-slope shading, meadow-matched moss cap on
// upper crowns, darker ground-contact collar so boulders sit in the grass, and suppressed
// close-range mist lift so nearby boulders keep rich form. Opaque, zero discard, render_priority = -1.
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
varying vec4 v_geom; // x: cavity AO, y: local height (0 base..1 crown), z: cut ridge edge, w: hue seed
varying vec2 v_meta; // x: sun_vis, y: cam dist

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
	v_geom = vec4(CUSTOM0.r, CUSTOM0.g, CUSTOM0.b, INSTANCE_CUSTOM.y);
	float sun_vis = w_cloud_shadow_v(ip + vec3(0.0, 1.0, 0.0), cam);
	v_meta = vec2(sun_vis, cam_d);

	vec3 atm_mul;
	vec3 atm_add;
	w_atmosphere(wp, cam, atm_mul, atm_add);
	// Keep nearby meadow/lakeside rocks crisp and free of low-elevation mist wash-out while
	// matching full aerial perspective at medium and far distances.
	float fog_k = smoothstep(32.0, 210.0, cam_d);
	v_atm_mul = mix(vec3(1.0), atm_mul, fog_k);
	v_atm_add = atm_add * fog_k;
}

void fragment() {
	vec3 wp = v_wpos;
	vec3 n = w_normalize(v_wn);
	float up = n.y;
	float cav_ao = v_geom.x;
	float h_loc = v_geom.y;
	float ridge = v_geom.z;
	float hue_v = v_geom.w;

	// Single cheap brushstroke noise fetch for painted plane breaks, moss edges, and mineral grain.
	vec4 nb = texture(noise_tex, wp.xz * 0.14 + vec2(wp.y * 0.16, -wp.y * 0.11));
	float brush = nb.r * 0.55 + nb.g * 0.45;
	float stroke = (brush - 0.5);

	// Crisp 3-tone painted light coordinate (cool blue-violet shadow / mid granite / sunlit warm stone).
	float ndl = dot(n, sun_dir);
	float l_val = clamp((ndl + 0.26) / 1.26, 0.0, 1.0) * 0.80 + clamp(up, 0.0, 1.0) * 0.20 + stroke * 0.14;
	float band_mid = smoothstep(0.22, 0.32, l_val);
	float band_lit = smoothstep(0.48, 0.60, l_val);

	// Alpine granite palette: cool periwinkle shadow, neutral slate midtone, warm sunlit stone.
	vec3 shadow_stone = vec3(0.18, 0.21, 0.30);
	vec3 mid_stone = vec3(0.34, 0.36, 0.40);
	vec3 lit_stone = vec3(0.54, 0.51, 0.45);
	vec3 stone = mix(mix(shadow_stone, mid_stone, band_mid), lit_stone, band_lit);
	// Subtle per-boulder warm/cool variety + subtle bevel highlight on lit cut ridges.
	stone *= mix(vec3(0.95, 0.96, 1.04), vec3(1.05, 1.01, 0.94), hue_v);
	stone *= (0.86 + 0.20 * cav_ao) * (0.93 + 0.14 * nb.b);
	stone += vec3(0.060, 0.055, 0.045) * ridge * band_lit;

	// Lush painted moss cap matching the meadow palette (paint_palette P_T1..P_T3) with organic
	// brushstroke breaks so sunlit granite rims and facets remain visible around the moss crown.
	float moss_field = up * 0.74 + (nb.g * 0.65 + nb.a * 0.35) * 0.36;
	float crown_mask = smoothstep(0.40, 0.66, h_loc + (nb.r - 0.5) * 0.14);
	float low_moss = smoothstep(0.79, 0.89, moss_field) * crown_mask * w_rstep(405.0, 315.0, wp.y);
	vec3 moss_sh = vec3(0.024, 0.112, 0.048);
	vec3 moss_mid = vec3(0.052, 0.215, 0.050);
	vec3 moss_lit = vec3(0.125, 0.325, 0.060);
	vec3 moss_col = mix(mix(moss_sh, moss_mid, band_mid), moss_lit, band_lit);
	moss_col *= 0.88 + 0.24 * nb.b;
	vec3 base = mix(stone, moss_col, low_moss * 0.94);

	// Warm sage alpine lichen at mid-high elevation.
	float high_lichen = smoothstep(0.64, 0.80, up * 0.72 + nb.g * 0.28) * crown_mask * smoothstep(330.0, 410.0, wp.y) * w_rstep(1150.0, 680.0, wp.y);
	vec3 lichen_col = mix(vec3(0.24, 0.29, 0.18), vec3(0.42, 0.41, 0.24), band_mid);
	base = mix(base, lichen_col, high_lichen * 0.58);

	// Wet darkened granite near lake shore & waterfall spray.
	float near_water = 1.0 - smoothstep(0.0, 1.25, abs(wp.y - water_level));
	float near_fall = waterfall.w > 0.1 ? (1.0 - smoothstep(waterfall.w * 0.35, waterfall.w, length(wp.xz - waterfall.xz))) : 0.0;
	float wet = clamp(max(near_water, near_fall * 0.85), 0.0, 1.0);
	base *= mix(1.0, 0.54, wet);

	// High-altitude snow dusting.
	float snow_k = smoothstep(1450.0, 1660.0, wp.y) * smoothstep(0.32, 0.68, up);
	base = mix(base, vec3(0.88, 0.91, 0.97), snow_k);

	// Grounded contact collar where the rock meets the grass/dirt so boulders sit in the turf.
	float base_ao = smoothstep(0.02, 0.36, h_loc + (nb.r - 0.5) * 0.10);
	vec3 contact_mul = mix(vec3(0.44, 0.50, 0.52), vec3(1.0), base_ao);
	base *= contact_mul;

	// Quantized 3-tone direct & indirect lighting in painterly mode so smooth n.y never washes out
	// the shadow terminator; classic mode keeps smooth w_toon_ramp.
	vec3 lit;
	if (painterly > 0.5) {
		float ramp = mix(mix(0.14, 0.54, band_mid), 1.0, band_lit);
		vec3 direct = ramp * light_col * v_meta.x * base / PI;
		float ind_y = mix(mix(0.08, 0.42, band_mid), 0.74, band_lit);
		vec3 ind = w_indirect(vec3(0.0, ind_y, 0.0), base);
		// Let the dark contact seam sit slightly deeper than the general light floor.
		lit = w_light_floor(direct + ind, base * mix(0.68, 1.0, base_ao));
	} else {
		float ramp = w_toon_ramp(ndl, 0.22, 0.20, 0.48, v_meta.y);
		vec3 direct = ramp * light_col * v_meta.x * base / PI;
		vec3 ind = w_indirect(n, base);
		lit = direct + ind;
	}

	lit = lit * v_atm_mul + v_atm_add;
	ALBEDO = w_grade(lit, SCREEN_UV, VIEWPORT_SIZE);
}
