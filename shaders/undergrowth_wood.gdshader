// Painterly round mossy logs & woodland stumps shader (W4):
// Opaque, zero discard (render_priority = -1 for Apple TBDR HSR). Keeps true cylindrical radial
// normals so fallen logs and fluted stumps read as round painted timber, using lengthwise bark
// furrows matched to tree_opaque.gdshader, lighter cut-wood end rings, curved upper moss cap
// matched to paint_palette.gdshaderinc (P_T1..P_T3), 3-band cylindrical shading, and base AO.
shader_type spatial;
render_mode unshaded, fog_disabled, cull_back, depth_draw_opaque;

#include "res://shaders/stillwater.gdshaderinc"
#include "res://shaders/atmosphere.gdshaderinc"

#define W_NOISE(uv) textureLod(noise_tex, uv, 0.0)
uniform vec4 ao_spot = vec4(615.25, 796.96, 8.5, 0.0);
#include "res://shaders/paint_palette.gdshaderinc"

uniform float dist_scale = 1.0;

varying vec3 v_wpos;
varying vec3 v_lpos;
varying vec3 v_wn;
varying vec4 v_col;   // rgb: linear base tint, a: end_t (0 middle..1 cut end on logs)
varying vec2 v_uv;    // x: part (0 bark, 0.35 cut end-grain, 0.55 shelf, 0.85 moss), y: height/radial 0..1
varying vec3 v_moss_tint;
varying vec3 v_atm_mul;
varying vec3 v_atm_add;
varying vec2 v_meta;  // x: sun_vis, y: cam_d

void vertex() {
	vec3 ip = MODEL_MATRIX[3].xyz;
	vec3 cam = CAMERA_POSITION_WORLD;
	float cam_d = length(ip - cam);
	float max_d = max(INSTANCE_CUSTOM.x * dist_scale, 30.0);
	float keep = 1.0 - smoothstep(max_d * 0.72, max_d, cam_d);
	vec3 lp = VERTEX * keep;
	VERTEX = lp;

	vec3 wp = (MODEL_MATRIX * vec4(lp, 1.0)).xyz;
	mat3 m = mat3(MODEL_MATRIX);
	vec3 inv_sq = vec3(
		1.0 / max(dot(m[0], m[0]), 1e-12),
		1.0 / max(dot(m[1], m[1]), 1e-12),
		1.0 / max(dot(m[2], m[2]), 1e-12)
	);
	vec3 wn = w_normalize(m * (NORMAL * inv_sq));
	// Preserve full cylindrical radial normal on bark so round curvature reads clearly; gently
	// soften explicit moss dome normals (0.18) so moss wraps around the rounded silhouette.
	float is_moss = smoothstep(0.72, 0.88, UV.x);
	v_wn = w_normalize(mix(wn, vec3(0.0, 1.0, 0.0), is_moss * 0.18));
	v_wpos = wp;
	v_lpos = lp;
	v_col = vec4(CUSTOM0.rgb, clamp(abs(VERTEX.x) * 2.0, 0.0, 1.0));
	v_uv = UV;

	// Ground-matched moss tint sampled from shared paint_palette (P_T1..P_T3).
	float gv = clamp(INSTANCE_CUSTOM.z, 0.14, 0.90);
	v_moss_tint = mix(w_paint_tone(gv, 0.25), P_T2, 0.35);

	float sun_vis = w_cloud_shadow_v(ip + vec3(0.0, 1.5, 0.0), cam);
	v_meta = vec2(sun_vis, cam_d);

	vec3 am;
	vec3 aa;
	w_atmosphere(wp, cam, am, aa);
	float fog_k = smoothstep(24.0, 180.0, cam_d);
	v_atm_mul = mix(vec3(1.0), am, fog_k);
	v_atm_add = aa * fog_k;
}

void fragment() {
	vec3 n = w_normalize(v_wn);
	float ndl = dot(n, sun_dir);
	// Stretch noise along the trunk axis (v_lpos.x) and wrap around circumference (v_uv.y) so
	// bark furrows visibly follow the round cylinder grain instead of reading as flat blobs.
	vec2 grain_uv = vec2(v_lpos.x * 0.45 + v_wpos.x * 0.06, v_uv.y * 2.1 + v_lpos.z * 0.35 + v_wpos.z * 0.06);
	vec4 nb = texture(noise_tex, grain_uv);
	float stroke = (nb.r * 0.55 + nb.g * 0.45) - 0.5;

	float is_bark = w_rstep(0.22, 0.10, v_uv.x);
	float is_end = smoothstep(0.22, 0.30, v_uv.x) * w_rstep(0.48, 0.42, v_uv.x);
	float is_moss_mesh = smoothstep(0.72, 0.88, v_uv.x);

	// 1. Rich warm oak/walnut bark matching tree_opaque.gdshader (deep furrow -> warm chestnut -> ridge).
	float furrow = smoothstep(0.28, 0.72, nb.r * 0.46 + nb.g * 0.36 + nb.b * 0.18);
	vec3 bark_col = mix(vec3(0.048, 0.028, 0.016), vec3(0.175, 0.102, 0.056), smoothstep(0.14, 0.54, furrow));
	bark_col = mix(bark_col, vec3(0.31, 0.195, 0.112), smoothstep(0.54, 0.88, furrow) * 0.76);

	// 2. Lighter cut wood end-grain with concentric growth rings and outer dark bark rind.
	float r_cap = clamp(v_uv.y, 0.0, 1.0);
	float ring_wave = 0.5 + 0.5 * sin(r_cap * 22.0 + nb.r * 2.4);
	vec3 heartwood = mix(vec3(0.50, 0.34, 0.18), vec3(0.80, 0.63, 0.39), smoothstep(0.20, 0.78, ring_wave));
	heartwood *= 0.88 + 0.22 * nb.g;
	float bark_rim = smoothstep(0.82, 0.95, r_cap + stroke * 0.05);
	vec3 end_col = mix(heartwood, bark_col * 0.90, bark_rim);

	// 3. Shelf polypore bracket color.
	vec3 shelf_col = v_col.rgb * (0.90 + 0.20 * nb.g);

	vec3 wood_alb = mix(shelf_col, bark_col, is_bark);
	wood_alb = mix(wood_alb, end_col, is_end);

	// 4. Curved upper moss cap strictly on the top arc (feathered organically before cut ends).
	float end_keep = w_rstep(0.95, 0.64, v_col.a);
	float crown_moss = is_bark * smoothstep(0.68, 0.88, n.y + stroke * 0.24) * smoothstep(0.54, 0.80, v_uv.y) * end_keep;
	float moss_w = clamp(max(is_moss_mesh, crown_moss * 0.92), 0.0, 1.0);

	// 3-band painted cylindrical shading combining sun direction and sky-facing arc so even
	// shadow-side logs show a clear dark underside -> warm mid-bark -> lit top shoulder roll.
	float up_arc = clamp(n.y * 0.5 + 0.5, 0.0, 1.0);
	float l_val = clamp((ndl + 0.32) / 1.32, 0.0, 1.0) * 0.62 + up_arc * 0.38 + stroke * 0.10;
	float band_mid = smoothstep(0.24, 0.36, l_val);
	float band_lit = smoothstep(0.56, 0.68, l_val);
	float cyl_wrap = mix(0.64, 1.12, smoothstep(0.10, 0.92, up_arc));

	vec3 moss_sh = vec3(0.024, 0.112, 0.046);
	vec3 moss_mid = mix(v_moss_tint * 0.86, P_T2, 0.35);
	vec3 moss_lit = P_T3 * vec3(0.92, 1.04, 0.84);
	vec3 moss_col = mix(mix(moss_sh, moss_mid, band_mid), moss_lit, band_lit) * (0.88 + 0.22 * nb.b);

	vec3 base = mix(wood_alb * cyl_wrap, moss_col, moss_w);

	// Grounded dark humus contact shadow where the lower cylinder curve tucks into the moss/earth.
	float base_ao = mix(smoothstep(0.05, 0.34, v_uv.y + stroke * 0.06), 1.0, is_end);
	base *= mix(vec3(0.36, 0.36, 0.34), vec3(1.0), base_ao);

	vec3 lit;
	if (painterly > 0.5) {
		float ramp = mix(mix(0.16, 0.56, band_mid), 1.0, band_lit);
		vec3 direct = ramp * light_col * v_meta.x * base / PI;
		float ind_y = mix(mix(0.08, 0.36, band_mid), 0.72, band_lit);
		vec3 ind = w_indirect(vec3(0.0, ind_y, 0.0), base);
		lit = w_light_floor(direct + ind, base * mix(0.65, 1.0, base_ao));
	} else {
		float ramp = w_toon_ramp(ndl, 0.34, 0.16, 0.52, v_meta.y);
		vec3 direct = ramp * light_col * v_meta.x * base / PI;
		vec3 ind = w_indirect(n, base);
		lit = w_light_floor(direct + ind, base);
	}

	lit = lit * v_atm_mul + v_atm_add;
	ALBEDO = w_grade(lit, SCREEN_UV, VIEWPORT_SIZE);
}
