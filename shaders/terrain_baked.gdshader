// Near and mid-range baked terrain (systems/terrain.gd).
//
// Vertex stage: exact CDLOD morph and skirt as terrain.gdshader, plus normal, cloud shadow,
// toon sun ramp, hemisphere fill, forest glade sun pools and analytic atmosphere.
// Fragment stage: 1 baked ground fetch (from the near-ring tile atlas, fading into the one-time
// valley macro bake over 54-68 m), 1 mipmapped detail-noise fetch under 22 m, cheap indirect +
// light floor and w_grade.
shader_type spatial;
render_mode unshaded, fog_disabled, cull_back;

#define W_DBG
#include "res://shaders/stillwater.gdshaderinc"
#include "res://shaders/atmosphere.gdshaderinc"
#include "res://shaders/world.gdshaderinc"

uniform float grid_n = 32.0;
uniform float lod_k = 3.0;
uniform vec2 cam_xz;
uniform float cam_dy;
uniform float skirt_on = 1.0;

uniform vec4 ao_spot = vec4(615.25, 796.96, 7.5, 0.35);

uniform sampler2D ground_atlas : filter_linear, repeat_disable;
uniform sampler2D ground_grid_tex : filter_nearest, repeat_disable;
uniform sampler2D valley_tex : filter_linear, repeat_disable;
uniform vec2 ground_grid_origin = vec2(0.0);
uniform float ground_grid_w = 16.0;
uniform float ground_tile_size = 12.0;
uniform float ground_slot_px = 128.0;
uniform float ground_slot_use = 125.0;
uniform vec2 ground_atlas_size = vec2(1536.0);
uniform float ground_fade_start = 40.0;
uniform float ground_fade_end = 54.0;
uniform float valley_ready = 0.0;

varying vec3 v_wpos;
varying vec3 v_direct;
varying vec3 v_hemi;
varying vec3 v_atm_mul;
varying vec3 v_atm_add;
varying vec3 v_params;

void vertex() {
	float size = INSTANCE_CUSTOM.z;
	vec2 grid = floor(VERTEX.xz * grid_n + 0.5);
	vec2 xz = INSTANCE_CUSTOM.xy + VERTEX.xz * size;
	float d = length(vec2(length(xz - cam_xz), cam_dy));
	float morph = clamp((d / (lod_k * size) - 1.55) / 0.35, 0.0, 1.0);
	if (size >= 16384.0) morph = 0.0;
	vec2 frac_g = fract(grid * 0.5) * 2.0;
	xz -= frac_g * (size / grid_n) * morph;
	vec3 n;
	float h_surf = w_height_n(xz, 2.0, n);
	float h = h_surf - UV.x * (2.0 + size * 0.015) * skirt_on;
	VERTEX = vec3(xz.x, h, xz.y);
	NORMAL = vec3(0.0, 1.0, 0.0);
	v_wpos = VERTEX;

	vec3 cam = CAMERA_POSITION_WORLD;
	float dist = length(VERTEX - cam);

	float sun_vis = w_cloud_shadow_v(VERTEX, cam);
	float ramp = w_toon_ramp(dot(n, sun_dir), 0.14, 0.24, 0.40, dist);
	vec3 direct_mul = ramp * light_col * sun_vis / PI;

	// Forest glade sun pools have 15-35 m wavelengths, smooth over 2 m vertices.
	vec2 map_uv = clamp(xz / near_size + 0.5, vec2(0.0), vec2(1.0));
	float bio_r = textureLod(biome_tex, map_uv, 0.0).r;
	float cotClear = ao_spot.z > 0.1 ? smoothstep(26.0, 48.0, length(xz - ao_spot.xy)) : 1.0;
	float fz = smoothstep(0.46, 0.82, bio_r) * cotClear * (1.0 - w_near_blend(xz));
	if (fz > 0.0) {
		float sunH = smoothstep(0.05, 0.22, sun_dir.y);
		vec2 sunProj = xz - sun_dir.xz / max(sun_dir.y, 0.25) * 6.0;
		vec2 dp1 = sunProj * 0.028 + wind_dir * sin(TIME * 0.28) * 0.02;
		vec2 dp2 = mat2(vec2(0.8, -0.6), vec2(0.6, 0.8)) * sunProj * 0.064;
		float n1 = textureLod(noise_tex, dp1, 0.0).r;
		float n2 = textureLod(noise_tex, dp2 + 0.31, 0.0).g;
		float pool = smoothstep(0.50, 0.70, n1 * 0.60 + n2 * 0.40);
		float midGlade = smoothstep(14.0, 26.0, dist) * (1.0 - smoothstep(38.0, 58.0, dist));
		float gladePool = max(pool * 0.95, midGlade * smoothstep(0.24, 0.58, n1 * 0.65 + n2 * 0.35) * 1.35);
		float trail_raw = (textureLod(near_tex, map_uv, 0.0).b * 255.0 - 128.0) / 127.0;
		float trailBoost = 1.0 + 0.38 * smoothstep(0.12, 0.55, max(trail_raw, 0.0));
		direct_mul += light_col * vec3(1.18, 0.98, 0.52) * gladePool * fz * 0.96 * trailBoost * sunH;
	}
	v_direct = direct_mul;

	float sky_k = smoothstep(-0.35, 0.85, n.y);
	v_hemi = mix(hemi_ground, hemi_sky, sky_k);

	vec3 atm_mul;
	vec3 atm_add;
	w_atmosphere(VERTEX, cam, atm_mul, atm_add);
	v_atm_mul = atm_mul;
	v_atm_add = atm_add;
	v_params = vec3(
		1.0 - smoothstep(ground_fade_start, ground_fade_end, dist),
		1.0 - smoothstep(10.0, 28.0, dist),
		smoothstep(0.08, 0.24, sun_dir.y)
	);
}

void fragment() {
	vec2 xz = v_wpos.xz;
	float near_k = v_params.x;
	bool got_near = false;
	vec4 near_s = vec4(0.0);

	if (near_k > 0.001) {
		vec2 tf = xz / ground_tile_size;
		vec2 ti = floor(tf);
		ivec2 rel = ivec2(ti - ground_grid_origin);
		int gw = int(ground_grid_w);
		if (rel.x >= 0 && rel.x < gw && rel.y >= 0 && rel.y < gw) {
			vec4 cell = texelFetch(ground_grid_tex, rel, 0);
			if (cell.b > 0.5) {
				vec2 slot_xy = floor(cell.rg * 255.0 + 0.5);
				vec2 frac_uv = tf - ti;
				vec2 px = slot_xy * ground_slot_px + vec2(1.5) + frac_uv * ground_slot_use;
				near_s = texture(ground_atlas, px / ground_atlas_size);
				got_near = true;
			}
		}
	}

	vec4 baked;
	if (got_near && near_k >= 0.999) {
		baked = near_s;
	} else {
		vec4 val_s = valley_ready > 0.5
				? texture(valley_tex, clamp(xz / near_size + 0.5, vec2(0.0005), vec2(0.9995)))
				: vec4(0.32, 0.45, 0.22, 0.0);
		baked = got_near ? mix(val_s, near_s, near_k) : val_s;
	}

	vec3 albedo = baked.rgb * baked.rgb;

	// One mipmapped detail-noise fetch under 28 m breaks up the 9.6 cm texel grid and adds crisp
	// grit/pebbles on paths, fallen leaf flecks on dark forest floor, and turf grain on grass.
	float det_k = v_params.y;
	if (det_k > 0.001) {
		vec4 det = texture(noise_tex, xz * 1.35);
		float peb = smoothstep(0.72, 0.84, det.a) * smoothstep(0.40, 0.72, det.b);
		float peb_sh = smoothstep(0.56, 0.70, det.a) * (1.0 - peb) * smoothstep(0.35, 0.65, det.b);
		float is_earth = smoothstep(0.84, 1.12, albedo.r / max(albedo.g, 0.02));
		float is_forest = (1.0 - is_earth) * w_rstep(0.20, 0.12, albedo.g);
		float grain = (det.b - 0.5) * 0.28 + (det.g - 0.5) * 0.16;
		float grit = (det.b - 0.5) * 0.34 + (det.g - 0.5) * 0.18 - peb_sh * 0.18;
		albedo *= 1.0 + mix(grain, grit, is_earth) * det_k;
		vec3 earth_peb = albedo * vec3(1.48, 1.42, 1.30) + vec3(0.025, 0.022, 0.016);
		vec3 leaf_fleck = vec3(0.32, 0.17, 0.052) * (0.85 + 0.30 * det.b);
		vec3 speck_col = mix(leaf_fleck, earth_peb, is_earth);
		float speck_w = peb * (is_earth * 0.58 + is_forest * 0.52) * det_k;
		albedo = mix(albedo, speck_col, speck_w);
	}

	float depthW = water_level - v_wpos.y;
	if (depthW > 0.0) {
		vec2 cp = xz * 0.35;
		float c1 = texture(noise_tex, cp * 0.11 + TIME * 0.012).a;
		float c2 = texture(noise_tex, cp * 0.13 - TIME * 0.010 + 0.5).a;
		float c_raw = clamp(1.0 - abs(c1 - c2) * 3.5, 0.0, 1.0);
		float c_sq = c_raw * c_raw;
		float caust = c_sq * c_sq * c_raw;
		albedo += vec3(0.65, 0.98, 1.0) * caust * 0.42 * exp(-depthW * 0.24) * max(sun_dir.y, 0.0);
	}

	vec3 ind = v_hemi * albedo;
	ind = max(mix(vec3(w_luma(ind)), ind, 1.18), 0.0) * shadow_ambient_tint * ambient_boost;
	ind = w_light_floor(ind, albedo);
	vec3 emis = vec3(0.12, 0.08, 0.035) * baked.a * v_params.z;
	vec3 lit = w_light_floor(v_direct * albedo + ind + emis, albedo);
	if (!DBG(DBG_NO_ATM)) {
		lit = lit * v_atm_mul + v_atm_add;
	}
	if (DBG(DBG_OUT_ALBEDO)) {
		lit = albedo;
	}
	ALBEDO = w_grade(lit, SCREEN_UV, VIEWPORT_SIZE);
}
