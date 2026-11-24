// Painterly mossy nurse logs & ancient forest stumps shader (W4):
// Opaque, zero discard (render_priority = -1 for Apple TBDR HSR). Uses upward-biased normals on
// velvet moss blankets, ground-matched moss palette from paint_palette.gdshaderinc (P_T0..P_T3),
// warm weathered bark + cut wood end-grain + shelf polypore fungi, and a dark humus contact collar
// so logs and stumps sit solidly in sloping forest ground.
shader_type spatial;
render_mode unshaded, fog_disabled, cull_back, depth_draw_opaque;

#include "res://shaders/stillwater.gdshaderinc"
#include "res://shaders/atmosphere.gdshaderinc"

#define W_NOISE(uv) textureLod(noise_tex, uv, 0.0)
uniform vec4 ao_spot = vec4(615.25, 796.96, 8.5, 0.0);
#include "res://shaders/paint_palette.gdshaderinc"

uniform float dist_scale = 1.0;

varying vec3 v_wpos;
varying vec3 v_wn;
varying vec4 v_col;   // rgb: linear albedo, a: baked contact AO
varying vec2 v_uv;    // x: part_kind (0 bark, 0.35 end-grain/shelf, 0.85 moss), y: local height 0..1
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
	// Upward-biased soft spherical normal on velvet moss caps so moss drapes softly like painted turf.
	float is_moss = smoothstep(0.60, 0.80, UV.x);
	v_wn = w_normalize(mix(wn, vec3(0.0, 1.0, 0.0), is_moss * 0.52));
	v_wpos = wp;
	v_col = CUSTOM0;
	v_uv = UV;

	// Ground-matched moss tint sampled from shared paint_palette (P_T1..P_T3).
	float gv = clamp(INSTANCE_CUSTOM.z, 0.12, 0.92);
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
	vec4 nb = texture(noise_tex, v_wpos.xz * 0.32 + vec2(v_wpos.y * 0.45, -v_wpos.y * 0.28));
	float stroke = (nb.r * 0.55 + nb.g * 0.45) - 0.5;

	float is_moss = smoothstep(0.60, 0.80, v_uv.x);
	float is_bark = 1.0 - smoothstep(0.15, 0.30, v_uv.x);
	// Upward-facing bark also picks up natural painterly moss flecks.
	float bark_moss = is_bark * smoothstep(0.55, 0.82, n.y + stroke * 0.30) * smoothstep(0.28, 0.65, v_uv.y);
	float moss_w = clamp(max(is_moss, bark_moss * 0.85), 0.0, 1.0);

	vec3 wood_alb = v_col.rgb * (0.88 + 0.24 * nb.g) * v_col.a;
	vec3 moss_alb = mix(v_moss_tint * 0.82, P_T3 * vec3(0.90, 1.02, 0.86), smoothstep(0.35, 0.85, nb.r)) * (0.86 + 0.24 * nb.b);
	vec3 base = mix(wood_alb, moss_alb, moss_w);

	// Grounded dark humus contact collar at log/stump base so trunks sit solidly in the forest floor.
	float base_ao = smoothstep(0.02, 0.28, v_uv.y + stroke * 0.08);
	base *= mix(vec3(0.46, 0.50, 0.48), vec3(1.0), base_ao);

	// Crisp 3-tone painted shading matching rock_painted.gdshader.
	float l_val = clamp((ndl + 0.28) / 1.28, 0.0, 1.0) * 0.82 + clamp(n.y, 0.0, 1.0) * 0.18 + stroke * 0.12;
	float band_mid = smoothstep(0.22, 0.34, l_val);
	float band_lit = smoothstep(0.48, 0.62, l_val);

	vec3 lit;
	if (painterly > 0.5) {
		float ramp = mix(mix(0.16, 0.56, band_mid), 1.0, band_lit);
		vec3 direct = ramp * light_col * v_meta.x * base / PI;
		float ind_y = mix(mix(0.10, 0.44, band_mid), 0.78, band_lit);
		vec3 ind = w_indirect(vec3(0.0, ind_y, 0.0), base);
		lit = w_light_floor(direct + ind, base * mix(0.70, 1.0, base_ao));
	} else {
		float ramp = w_toon_ramp(ndl, 0.30, 0.18, 0.50, v_meta.y);
		vec3 direct = ramp * light_col * v_meta.x * base / PI;
		vec3 ind = w_indirect(n, base);
		lit = direct + ind;
	}

	lit = lit * v_atm_mul + v_atm_add;
	ALBEDO = w_grade(lit, SCREEN_UV, VIEWPORT_SIZE);
}
