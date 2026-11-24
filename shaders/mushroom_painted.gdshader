// High-readability woodland mushrooms shader (W4):
// Single SwapMultiMesh draw call for both crimson white-spotted toadstools (INSTANCE_CUSTOM.y < 0.5)
// and golden chanterelles (INSTANCE_CUSTOM.y > 0.5). Opaque, zero discard (render_priority = -1),
// zero texture fetches in fragment, spherical upward cap normals, bright readable accent colors.
shader_type spatial;
render_mode unshaded, fog_disabled, cull_back, depth_draw_opaque;

#include "res://shaders/stillwater.gdshaderinc"
#include "res://shaders/atmosphere.gdshaderinc"

uniform float dist_scale = 1.0;

varying vec3 v_wn;
varying vec2 v_uv;      // x: part (0 pad, 0.4 stem, 1.0 cap), y: local height 0..1
varying vec3 v_cap_pos; // local cap xyz for crisp procedural toadstool spots
varying vec4 v_meta;    // x: is_golden, y: sun_vis, z: cam_d, w: seed
varying vec3 v_atm_mul;
varying vec3 v_atm_add;

void vertex() {
	vec3 ip = MODEL_MATRIX[3].xyz;
	vec3 cam = CAMERA_POSITION_WORLD;
	float cam_d = length(ip - cam);
	float max_d = max(INSTANCE_CUSTOM.x * dist_scale, 18.0);
	float keep = 1.0 - smoothstep(max_d * 0.68, max_d, cam_d);

	float is_golden = INSTANCE_CUSTOM.y;
	float stem_h = INSTANCE_CUSTOM.z;
	float cap_r = INSTANCE_CUSTOM.w;

	vec3 lp = VERTEX;
	float part = UV.x;
	if (part > 0.75) {
		// Cap vertices are built around local origin with unit radius 1.0; place atop stem.
		float ch = is_golden > 0.5 ? 0.50 : 0.76;
		vec3 cp = lp;
		// Chanterelle: gently flare outer cap edge slightly upward into a funnel silhouette.
		if (is_golden > 0.5) {
			float r2 = clamp(dot(cp.xz, cp.xz), 0.0, 1.0);
			cp.y = cp.y * ch + r2 * 0.24 - 0.08;
		} else {
			cp.y *= ch;
		}
		v_cap_pos = lp;
		lp = vec3(cp.x * cap_r, stem_h * 0.88 + cp.y * cap_r, cp.z * cap_r);
	} else if (part > 0.20) {
		// Stem vertices: y in [0..1] scaled by stem_h, radius scaled with cap_r.
		float sr = cap_r * 0.42;
		lp = vec3(lp.x * sr, lp.y * (stem_h + 0.04) - 0.03, lp.z * sr);
		v_cap_pos = vec3(0.0);
	} else {
		// Grounding humus pad at base.
		lp = vec3(lp.x * cap_r * 1.18, lp.y * 0.035, lp.z * cap_r * 1.18);
		v_cap_pos = vec3(0.0);
	}

	lp *= keep;
	VERTEX = lp;
	vec3 wp = (MODEL_MATRIX * vec4(lp, 1.0)).xyz;
	mat3 m = mat3(MODEL_MATRIX);
	vec3 wn = w_normalize(m * NORMAL);
	// Soft upward-biased spherical cap normal so mushroom domes catch warm skylight cleanly.
	v_wn = part > 0.75 ? w_normalize(mix(wn, vec3(0.0, 1.0, 0.0), 0.38)) : wn;
	v_uv = UV;

	float sun_vis = w_cloud_shadow_v(ip + vec3(0.0, 1.0, 0.0), cam);
	float seed = fract(sin(dot(ip.xz, vec2(12.9898, 78.233))) * 43758.5453);
	v_meta = vec4(is_golden, sun_vis, cam_d, seed);

	vec3 am;
	vec3 aa;
	w_atmosphere(wp, cam, am, aa);
	float fog_k = smoothstep(20.0, 140.0, cam_d);
	v_atm_mul = mix(vec3(1.0), am, fog_k);
	v_atm_add = aa * fog_k;
}

void fragment() {
	vec3 n = w_normalize(v_wn);
	float is_golden = v_meta.x;
	float part = v_uv.x;

	vec3 base;
	if (part > 0.75) {
		if (is_golden > 0.5) {
			// Luminous saffron-amber chanterelle cap with bright sunlit rim.
			float rim = smoothstep(0.35, 0.92, length(v_cap_pos.xz));
			base = mix(vec3(0.92, 0.54, 0.07), vec3(1.00, 0.76, 0.18), rim);
		} else {
			// High-readability crimson-vermilion toadstool cap with crisp ivory spots.
			vec3 red_cap = mix(vec3(0.76, 0.09, 0.07), vec3(0.94, 0.17, 0.11), smoothstep(0.1, 0.85, v_cap_pos.y));
			// 6 deterministic crisp polka spots on the upper dome (zero texture fetches).
			vec2 p = v_cap_pos.xz;
			float ang_off = v_meta.w * 6.283185;
			float spot = 0.0;
			// Central crown spot
			spot = max(spot, w_rstep(0.22, 0.15, length(p - vec2(0.08, -0.05))));
			// 5 ring spots around dome
			for (int k = 0; k < 5; k++) {
				float a = ang_off + float(k) * 1.256637;
				vec2 sc = vec2(cos(a), sin(a)) * 0.56;
				spot = max(spot, w_rstep(0.21, 0.14, length(p - sc)));
			}
			spot *= smoothstep(0.18, 0.42, v_cap_pos.y);
			base = mix(red_cap, vec3(0.98, 0.96, 0.90), spot);
		}
		// Subtle warm cream gill underside if facing down.
		float under = w_rstep(0.08, -0.10, v_cap_pos.y);
		base = mix(base, is_golden > 0.5 ? vec3(0.84, 0.58, 0.18) : vec3(0.86, 0.80, 0.68), under);
	} else if (part > 0.20) {
		// Stem with slight grounded shadow at base.
		vec3 stem_col = is_golden > 0.5 ? vec3(0.90, 0.70, 0.24) : vec3(0.94, 0.90, 0.80);
		base = stem_col * mix(0.68, 1.0, smoothstep(0.0, 0.45, v_uv.y));
	} else {
		// Dark forest humus contact pad grounding the mushroom solidly to the moss.
		base = vec3(0.045, 0.11, 0.038);
	}

	float ndl = dot(n, sun_dir);
	float ramp = w_toon_ramp(ndl, 0.42, 0.16, 0.52, v_meta.z);
	vec3 direct = ramp * light_col * v_meta.y * base / PI;
	vec3 ind = w_indirect(n, base);
	// Slight accent lift on caps so mushrooms remain clearly readable in dappled forest shade.
	float accent = part > 0.75 ? 1.18 : 1.0;
	vec3 lit = w_light_floor((direct + ind) * accent, base * accent);
	lit = lit * v_atm_mul + v_atm_add;
	ALBEDO = w_grade(lit, SCREEN_UV, VIEWPORT_SIZE);
}
