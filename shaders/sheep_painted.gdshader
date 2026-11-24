// Chunky painted meadow sheep (W5):
// Vertex-animated grazing head nods/turns, natural leg stance/shift, and tail wag (0 per-frame
// GDScript), soft wrap-toon shading, warm coat variation, subtle wool texture, and crisp
// silver-blue moonlight rim at night so flocks stay clearly readable against dark pastures.
// Opaque, zero discard, render_priority = -1.
shader_type spatial;
render_mode unshaded, fog_disabled, cull_back, depth_draw_opaque;

#include "res://shaders/stillwater.gdshaderinc"
#include "res://shaders/atmosphere.gdshaderinc"

varying vec3 v_wpos;
varying vec3 v_wn;
varying vec4 v_col;   // rgb: base part albedo, a: part_id (0 wool, 1 head/eye, 2 leg, 3 tail)
varying vec3 v_coat;  // per-sheep coat tint
varying vec3 v_meta;  // x: sun_vis, y: cam dist, z: leg local y
varying vec3 v_atm_mul;
varying vec3 v_atm_add;

vec3 sheep_coat(float idx) {
	if (idx < 0.5) return vec3(1.00, 0.99, 0.95);
	if (idx < 1.5) return vec3(1.00, 0.94, 0.83);
	if (idx < 2.5) return vec3(0.92, 0.91, 0.89);
	if (idx < 3.5) return vec3(0.97, 0.92, 0.86);
	return vec3(0.66, 0.61, 0.57);
}

void vertex() {
	float graze = INSTANCE_CUSTOM.x;
	float walk = INSTANCE_CUSTOM.y;
	float phase = INSTANCE_CUSTOM.z;
	float coat_idx = INSTANCE_CUSTOM.w;

	vec4 c0 = CUSTOM0;
	float part = c0.a;
	vec3 pos = VERTEX;
	vec3 nrm = NORMAL;

	if (part > 0.5 && part < 1.5) {
		// Head & ears: grazing pitch nod + varied left/right curious glances.
		float ang = graze * 0.92 + sin(TIME * 1.7 + phase) * 0.06 * graze + sin(TIME * 0.6 + phase) * 0.08 * (1.0 - graze);
		float hyaw = sin(phase * 3.7 + 1.1) * 0.40 + sin(TIME * 0.45 + phase * 2.1) * 0.14;
		vec3 piv = vec3(0.0, 0.74, 0.42);
		vec3 q = pos - piv;
		float ca = cos(ang);
		float sa = sin(ang);
		q = vec3(q.x, q.y * ca - q.z * sa, q.y * sa + q.z * ca);
		nrm = vec3(nrm.x, nrm.y * ca - nrm.z * sa, nrm.y * sa + nrm.z * ca);
		float cy = cos(hyaw);
		float sy = sin(hyaw);
		q = vec3(q.x * cy + q.z * sy, q.y, -q.x * sy + q.z * cy);
		nrm = vec3(nrm.x * cy + nrm.z * sy, nrm.y, -nrm.x * sy + nrm.z * cy);
		pos = piv + q;
	} else if (part > 1.5 && part < 2.5) {
		// Legs: relaxed staggered standing stance + gentle idle shift / step.
		float side = (pos.x >= 0.0 ? 1.0 : -1.0) * (pos.z >= 0.0 ? 1.0 : -1.0);
		float leg_frac = clamp(1.0 - pos.y / 0.48, 0.0, 1.0);
		float stance = sin(phase * 2.7 + side * 1.4) * 0.065;
		float stride = sin(TIME * 3.4 + phase + side * 1.57) * 0.055 * walk;
		pos.z += (stance + stride) * leg_frac;
		pos.x += (pos.x >= 0.0 ? 1.0 : -1.0) * 0.020 * leg_frac;
	} else if (part > 2.5) {
		// Stubby bobtail wag.
		vec3 piv = vec3(0.0, 0.72, -0.50);
		vec3 q = pos - piv;
		float a = sin(TIME * 2.3 + phase) * 0.34;
		float ca = cos(a);
		float sa = sin(a);
		q = vec3(q.x, q.y * ca - q.z * sa, q.y * sa + q.z * ca);
		pos = piv + q;
	}

	vec3 wp = (MODEL_MATRIX * vec4(pos, 1.0)).xyz;
	vec3 cam = CAMERA_POSITION_WORLD;
	mat3 m = mat3(MODEL_MATRIX);
	vec3 inv_sq = vec3(
		1.0 / max(dot(m[0], m[0]), 1e-12),
		1.0 / max(dot(m[1], m[1]), 1e-12),
		1.0 / max(dot(m[2], m[2]), 1e-12)
	);
	v_wn = w_normalize(m * (nrm * inv_sq));
	v_wpos = wp;
	v_col = c0;
	v_coat = sheep_coat(coat_idx);
	float sun_vis = w_cloud_shadow_v(wp + vec3(0.0, 1.0, 0.0), cam);
	v_meta = vec3(sun_vis, length(wp - cam), (part > 1.5 && part < 2.5) ? VERTEX.y : 9.0);

	vec3 am;
	vec3 aa;
	w_atmosphere(wp, cam, am, aa);
	v_atm_mul = am;
	v_atm_add = aa;
	VERTEX = pos;
}

void fragment() {
	vec3 n = w_normalize(v_wn);
	vec3 vw = w_normalize(CAMERA_POSITION_WORLD - v_wpos);
	float is_wool = v_col.a < 0.5 ? 1.0 : 0.0;
	vec3 albedo = v_col.rgb;

	// Subtle curled-fleece noise mottling + coat tint (leaving crisp eye dots untinted).
	float wool_n = texture(noise_tex, v_wpos.xz * 3.8 + vec2(v_wpos.y * 2.9, -v_wpos.y * 1.7)).a;
	albedo *= 1.0 - is_wool * 0.11 * wool_n;
	bool is_eye = (albedo.r > 0.94 && albedo.g > 0.94 && albedo.b > 0.90 && is_wool < 0.5);
	if (!is_eye) {
		albedo *= mix(vec3(1.0), v_coat, is_wool > 0.5 ? 1.0 : 0.35);
	}
	if (v_meta.z < 5.0) {
		albedo *= mix(0.82, 1.0, smoothstep(0.16, 0.52, v_meta.z));
	}

	// Soft wrap-toon shading with clear sunny contrast against green meadow grass.
	float ramp = w_toon_ramp(dot(n, sun_dir), 0.65, 0.12, 0.58, v_meta.y);
	vec3 direct = ramp * light_col * v_meta.x * albedo / PI;
	vec3 ind = w_indirect(n, albedo);
	vec3 lit = w_light_floor(direct + ind, albedo);

	// Warm sunlit fleece rim by day + crisp silver-blue moonlight rim on wool backs at night.
	float rim_base = max(1.0 - max(dot(n, vw), 0.0), 0.0);
	float rim = rim_base * rim_base * sqrt(max(rim_base, 0.0));
	float top_m = smoothstep(0.05, 0.72, n.y);
	lit += albedo * light_col * (rim * 0.13 * v_meta.x * (0.30 + is_wool) * sun_disc_vis);
	lit += vec3(0.55, 0.72, 1.0) * (rim * 0.24 + top_m * 0.06) * (0.35 + is_wool) * night_weight;

	lit = lit * v_atm_mul + v_atm_add;
	ALBEDO = w_grade(lit, SCREEN_UV, VIEWPORT_SIZE);
}
