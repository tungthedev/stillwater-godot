// Stylized painterly fern rosette shader (W4):
// Opaque, zero discard (render_priority = -1 for Apple TBDR HSR), using spherical upward-biased
// dome normals and ground-matched base tinting from paint_palette.gdshaderinc so fern rosettes
// melt into the forest floor with zero alpha-cutout overdraw. Lighting & atmosphere run per vertex
// so fragment executes zero texture fetches.
shader_type spatial;
render_mode unshaded, fog_disabled, cull_disabled, depth_draw_opaque;

#include "res://shaders/stillwater.gdshaderinc"
#include "res://shaders/atmosphere.gdshaderinc"

#define W_NOISE(uv) textureLod(noise_tex, uv, 0.0)
uniform vec4 ao_spot = vec4(615.25, 796.96, 8.5, 0.0);
#include "res://shaders/paint_palette.gdshaderinc"

uniform float dist_scale = 1.0;
uniform float wind_strength = 0.5;

varying vec3 v_lit;
varying vec3 v_tip_lit;
varying vec2 v_uv; // x: lateral rib->edge (0..1), y: base->tip along frond (0..1)
varying vec3 v_atm_mul;
varying vec3 v_atm_add;

void vertex() {
	vec3 ip = MODEL_MATRIX[3].xyz;
	vec3 cam = CAMERA_POSITION_WORLD;
	float cam_d = length(ip - cam);
	float max_d = max(INSTANCE_CUSTOM.x * dist_scale, 16.0);
	// Smooth shrink-out well inside CPU cull radius so ferns never pop.
	float keep = 1.0 - smoothstep(max_d * 0.62, max_d, cam_d);
	float near_k = smoothstep(0.30, 0.95, cam_d);
	float scale_k = keep * mix(0.75, 1.0, near_k);

	float tint_seed = INSTANCE_CUSTOM.y;
	float ground_v = INSTANCE_CUSTOM.z;
	float clump = INSTANCE_CUSTOM.w;

	vec3 lp = VERTEX * scale_k;
	float sway_ph = TIME * (1.45 + 0.35 * tint_seed) + ip.x * 0.37 + ip.z * 0.29 + tint_seed * 18.0;
	float sway = sin(sway_ph) * (0.032 + 0.028 * wind_strength) * lp.y;
	lp.x += sway * wind_dir.x;
	lp.z += sway * wind_dir.y;

	vec3 wp = (MODEL_MATRIX * vec4(lp, 1.0)).xyz;
	VERTEX = lp;
	v_uv = UV;

	// Spherical upward-biased dome normal so each fern rosette shades as one soft painted volume.
	mat3 m = mat3(MODEL_MATRIX);
	vec3 wn = w_normalize(m * NORMAL);
	vec3 dome_n = w_normalize(mix(wn, vec3(0.0, 1.0, 0.0), 0.58));

	// Ground-matched base tint from the shared painted meadow/forest palette (P_T0..P_T2),
	// transitioning smoothly up the frond into rich deep-emerald & sunlit woodland fern greens.
	vec3 ground_base = w_paint_tone(clamp(ground_v * 0.60, 0.0, 0.78), 0.28) * vec3(0.66, 0.80, 0.76);
	vec3 fern_warm = vec3(0.072, 0.228, 0.052);
	vec3 fern_mid  = vec3(0.038, 0.178, 0.048);
	vec3 fern_deep = vec3(0.022, 0.138, 0.052);
	vec3 frond_col = tint_seed < 0.28 ? fern_warm : (tint_seed < 0.68 ? fern_mid : fern_deep);
	frond_col *= 0.80 + 0.36 * clump;

	vec3 base_alb = mix(ground_base, frond_col, smoothstep(0.0, 0.44, UV.y));
	vec3 tip_alb = mix(frond_col, frond_col * vec3(1.28, 1.24, 0.86) + vec3(0.024, 0.038, 0.008), 0.50);

	float sun_vis = w_cloud_shadow_v(ip + vec3(0.0, 1.5, 0.0), cam);
	float ndl = dot(dome_n, sun_dir);
	float ramp = w_toon_ramp(ndl, 0.52, 0.14, 0.52, cam_d);

	// Soft dappled forest sunlight pools (matching Three.js undergrowth.js).
	vec2 dp1 = wp.xz * 0.055 + wind_dir * sin(TIME * 0.32) * 0.04;
	float pool = smoothstep(0.44, 0.72, textureLod(noise_tex, dp1, 0.0).r);
	float sun_up = smoothstep(0.05, 0.22, sun_dir.y);
	vec3 dapple = light_col * vec3(1.04, 0.98, 0.68) * (0.02 + pool * 0.18) * sun_up * sun_vis;

	vec3 direct_b = ramp * light_col * sun_vis * base_alb / PI;
	vec3 ind_b = w_indirect(dome_n, base_alb);
	v_lit = w_light_floor(direct_b + ind_b + base_alb * dapple * 0.30, base_alb);

	vec3 direct_t = ramp * light_col * sun_vis * tip_alb / PI;
	vec3 ind_t = w_indirect(vec3(0.0, 0.85, 0.0), tip_alb);
	v_tip_lit = w_light_floor(direct_t + ind_t + tip_alb * dapple * 0.78, tip_alb);

	vec3 am;
	vec3 aa;
	w_atmosphere(wp, cam, am, aa);
	v_atm_mul = am;
	v_atm_add = aa;
}

void fragment() {
	// Zero texture fetches: crisp painted fern pinna ribbing, central stem midrib & dark rosette core.
	float ax = abs(v_uv.x);
	float tip_k = smoothstep(0.28, 0.95, v_uv.y);
	vec3 lit = mix(v_lit, v_tip_lit, tip_k);
	// Angled botanical leaflet stripes fanning outward from the central rachis.
	float pinna = 0.5 + 0.5 * sin((v_uv.y * 14.0 - ax * 1.8) * 6.283185);
	float leaflet_shade = mix(0.84, 1.07, smoothstep(0.22, 0.78, pinna) * smoothstep(0.10, 0.32, ax));
	float midrib = w_rstep(0.14, 0.03, ax);
	float core_ao = mix(0.68, 1.05, smoothstep(0.05, 0.55, v_uv.y));
	lit *= core_ao * mix(leaflet_shade, 0.86, midrib * 0.65);
	lit = lit * v_atm_mul + v_atm_add;
	ALBEDO = w_grade(lit, SCREEN_UV, VIEWPORT_SIZE);
}
