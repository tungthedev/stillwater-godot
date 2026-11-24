// Painterly waterfall curtains + cel-shaded base splash foam crown (W2, 1 draw call).
// Uses crisp cutout discard (no alpha blending) at render_priority = 1 (after -1 opaque draws).
// UV2.x < 0.5 : falling braided curtains, UV = (x_across [-1..1], s_down [0..1])
// UV2.x >= 0.5: base churning splash crown, UV = (arc_u [0..1], height_v [0..1])
shader_type spatial;
render_mode unshaded, fog_disabled, cull_disabled, depth_draw_opaque;

#include "res://shaders/stillwater.gdshaderinc"
#include "res://shaders/atmosphere.gdshaderinc"

uniform float drop_height = 48.0;

varying vec3 v_wpos;
varying vec2 v_uv;
varying float v_is_boil;
varying vec3 v_atm_mul;
varying vec3 v_atm_add;
varying float v_cloud_sh;

void vertex() {
	vec3 wp = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	v_wpos = wp;
	v_uv = UV;
	v_is_boil = UV2.x;
	vec3 am;
	vec3 aa;
	w_atmosphere(wp, CAMERA_POSITION_WORLD, am, aa);
	v_atm_mul = am;
	v_atm_add = aa;
	v_cloud_sh = w_cloud_shadow_v(wp, CAMERA_POSITION_WORLD);
}

void fragment() {
	vec3 wp = v_wpos;
	float t = TIME;
	float dist = length(CAMERA_POSITION_WORLD - wp);
	float sun_up = clamp(sun_dir.y * 3.0, 0.0, 1.0);
	vec3 amb = w_sky(vec3(0.0, 1.0, 0.0));
	vec3 amb_fill = mix(hemi_sky, amb, 0.45) * shadow_ambient_tint * ambient_boost;

	vec3 col;
	if (v_is_boil > 0.5) {
		// ---- Sculpted cel-shaded splash foam crown hugging cascade impact ----
		float n1 = texture(noise_tex, vec2(v_uv.x * 5.5, v_uv.y * 2.0 - t * 0.78)).a;
		float n2 = texture(noise_tex, vec2(v_uv.x * 13.0 + 0.31, v_uv.y * 3.8 - t * 1.35)).g;
		float lobe = n1 * 0.58 + n2 * 0.42;
		float top_cut = w_rstep(0.92, 0.68, v_uv.y + (0.55 - lobe) * 0.85);
		float bot_ok = smoothstep(0.0, 0.08, v_uv.y);
		float side_ok = smoothstep(0.0, 0.10, v_uv.x) * w_rstep(1.0, 0.90, v_uv.x);
		float mask = top_cut * bot_ok * side_ok * (0.68 + 0.52 * lobe);
		if (mask < 0.34) {
			discard;
		}
		// 2-tone painted foam: cool aqua-sapphire churning shadow base -> bright sunlit white crest.
		vec3 foam_shadow = amb_fill * 0.76 + vec3(0.04, 0.24, 0.40) * 0.65;
		vec3 foam_lit = (amb_fill * 1.08 + light_col * 0.30 * sun_up * v_cloud_sh) * vec3(0.98, 0.99, 1.0);
		float tone = smoothstep(0.34, 0.54, v_uv.y * 0.60 + n2 * 0.40);
		col = mix(foam_shadow, foam_lit, tone);
	} else {
		// ---- Multi-braided falling water curtains with ragged painted strand silhouettes ----
		float x = v_uv.x;
		float s = v_uv.y;
		float braid = 0.50 + 0.50 * sin(x * 8.2 + sin(s * 7.2) * 0.80);
		float st1 = texture(noise_tex, vec2(x * 1.7 + 0.17, s * drop_height * 0.036 - t * 0.74)).g;
		float st2 = texture(noise_tex, vec2(x * 4.4 + 0.59, s * drop_height * 0.085 - t * 1.24)).b;
		float streak = st1 * 0.55 + st2 * 0.45;

		float foam_lip = w_rstep(0.18, 0.0, s) * 0.88;
		float bounce_d = (s - 0.46) / 0.11;
		float foam_bounce = exp(-bounce_d * bounce_d) * 0.44;
		float foam_base = smoothstep(0.74, 1.0, s) * (0.42 + 0.36 * streak);
		float dist_bright = smoothstep(140.0, 440.0, dist) * 0.46;

		// Ragged organic side edges & top lip curl (never a rectangular card).
		float edge_noise = (st1 - 0.5) * 0.46 + (st2 - 0.5) * 0.28;
		float edge = w_rstep(0.95, 0.44, abs(x) + edge_noise);
		float strand = smoothstep(0.20, 0.46, streak + (1.0 - abs(x)) * 0.28 + foam_lip + foam_base + dist_bright);
		float top_lip = smoothstep(0.0, 0.065 + st1 * 0.05 + abs(x) * 0.04, s);
		float mask = edge * strand * top_lip;
		if (mask < 0.32) {
			discard;
		}

		float dist_gain = mix(0.94, 1.28, smoothstep(140.0, 420.0, dist));
		vec3 white = (amb_fill * 1.02 + light_col * 0.28 * sun_up * v_cloud_sh) * dist_gain * vec3(0.96, 0.99, 1.0);
		vec3 aqua = vec3(0.038, 0.38, 0.58) * (amb_fill * 1.32 + light_col * 0.20 * sun_up * v_cloud_sh);
		aqua = w_light_floor(aqua, vec3(0.038, 0.38, 0.58));

		float wf = clamp(smoothstep(0.32, 0.72, streak * (0.72 + 0.36 * braid)) * 0.76 + foam_lip + foam_bounce + foam_base + dist_bright, 0.16, 0.96);
		col = mix(aqua, white, wf);
	}

	col = col * v_atm_mul + v_atm_add;
	ALBEDO = w_grade(col, SCREEN_UV, VIEWPORT_SIZE);
}
