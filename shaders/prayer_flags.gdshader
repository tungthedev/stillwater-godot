// Summit Tibetan prayer flags (W3): opaque cull_disabled (zero discard!), lively alpine wind
// cloth ripple in vertex, painted border & motif in fragment, warm sunlit translucency.
shader_type spatial;
render_mode unshaded, fog_disabled, cull_disabled, depth_draw_opaque;

#include "res://shaders/stillwater.gdshaderinc"
#include "res://shaders/atmosphere.gdshaderinc"

uniform float wind_strength = 0.5;

varying vec3 v_wpos;
varying vec3 v_wn;
varying vec2 v_uv;
varying vec4 v_col; // rgb: flag cloth albedo, a: phase seed
varying float v_ripple;
varying vec3 v_atm_mul;
varying vec3 v_atm_add;
varying vec2 v_meta; // x: sun_vis, y: cam dist

void vertex() {
	float u = UV.x;
	float v = UV.y;
	float ph = COLOR.a * 40.0;
	vec3 perp = w_normalize(vec3(NORMAL.x, 0.0, NORMAL.z));
	float billow = 0.22 + 0.20 * sin(TIME * 2.4 + ph * 0.9);
	float ripple = sin(TIME * 6.5 + ph + u * 5.2 + v * 4.5) * 0.55
		+ sin(TIME * 10.5 + ph * 1.7 + u * 9.0 - v * 6.0) * 0.25;
	float amp = 0.28 + wind_strength * 0.42;
	float v_pow = v * sqrt(max(v, 0.0));
	VERTEX += perp * (billow + ripple * 0.52) * v_pow * amp;
	VERTEX.y += v_pow * (0.12 * billow + 0.07 * ripple) * amp;

	vec3 wp = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	vec3 cam = CAMERA_POSITION_WORLD;
	v_wpos = wp;
	v_wn = perp;
	v_uv = UV;
	v_col = COLOR;
	v_ripple = ripple;
	v_meta = vec2(w_cloud_shadow_v(wp + vec3(0.0, 2.0, 0.0), cam), length(wp - cam));

	vec3 atm_mul;
	vec3 atm_add;
	w_atmosphere(wp, cam, atm_mul, atm_add);
	v_atm_mul = atm_mul;
	v_atm_add = atm_add;
}

void fragment() {
	vec2 q = v_uv;
	float ph = v_col.a * 40.0;
	float border = step(0.08, q.x) * step(q.x, 0.92) * step(0.08, q.y) * step(q.y, 0.90);
	float kind = mod(floor(ph * 0.6), 3.0);
	float d_ring = abs(length((q - vec2(0.5, 0.45)) * vec2(1.0, 1.3)) - 0.20);
	float ring = w_rstep(0.032, 0.0, d_ring);
	vec2 dq = abs(q - vec2(0.5, 0.5));
	float diamond = w_rstep(0.032, 0.0, abs(dq.x + dq.y * 0.8 - 0.25));
	float wheel = w_rstep(0.032, 0.0, abs(length(q - 0.5) - 0.18)) + step(length(q - 0.5), 0.05);
	float motif = kind < 0.5 ? ring : (kind < 1.5 ? diamond : wheel);
	float lines = step(0.5, fract(q.y * 7.0)) * step(0.64, q.y) * step(0.2, q.x) * step(q.x, 0.8) * 0.5;

	vec3 col = v_col.rgb * mix(0.76, 1.0, border) * (1.0 - 0.44 * max(motif, lines));
	col = mix(col, vec3(0.92, 0.89, 0.82), 0.14 + 0.18 * fract(ph * 0.41));
	col *= 0.88 + 0.16 * v_ripple * q.y;

	vec3 n = FRONT_FACING ? w_normalize(v_wn) : -w_normalize(v_wn);
	float ramp = w_toon_ramp(dot(n, sun_dir), 0.45, 0.14, 0.52, v_meta.y);
	vec3 direct = ramp * light_col * v_meta.x * col / PI;
	vec3 ind = w_indirect(n, col);
	vec3 vw = w_normalize(v_wpos - CAMERA_POSITION_WORLD);
	float b0 = max(dot(vw, sun_dir), 0.0);
	float back = b0 * b0 * sqrt(b0);
	vec3 emis = col * light_col * (back * 0.55 + 0.06) * v_meta.x;
	vec3 lit = w_light_floor(direct + ind + emis, col);
	lit = lit * v_atm_mul + v_atm_add;
	ALBEDO = w_grade(lit, SCREEN_UV, VIEWPORT_SIZE);
}
