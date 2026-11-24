// Near and mid-range baked terrain (systems/terrain.gd).
//
// Vertex stage: exact CDLOD morph and skirt as terrain.gdshader, plus normal, cloud shadow,
// toon sun ramp, hemisphere fill, forest glade sun pools, biome channels and analytic atmosphere.
// Fragment stage: smooth baked macro ground + forest-floor mask (near-ring atlas fading into the
// one-time valley bake over 40-54 m), live near_tex trail field so paths stay sharp from 1 m to
// 700 m, and two isotropic mipmapped noise_tex fetches with fwidth()-widened thresholds to
// reconstruct crisp painted patch edges, fallen leaf flecks and dirt pebbles without grazing streaks.
shader_type spatial;
render_mode unshaded, fog_disabled, cull_back;

#define W_DBG
#include "res://shaders/stillwater.gdshaderinc"
#include "res://shaders/atmosphere.gdshaderinc"
#include "res://shaders/world.gdshaderinc"

uniform float grid_n = 32.0;
uniform float lod_k = 3.0;
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
uniform float painted_ground = 1.0;

varying vec3 v_wpos;
varying vec3 v_direct;
varying vec3 v_hemi;
varying vec3 v_atm_mul;
varying vec3 v_atm_add;
varying vec4 v_params;
varying vec2 v_bio;

void vertex() {
	float size = INSTANCE_CUSTOM.z;
	vec2 grid = floor(VERTEX.xz * grid_n + 0.5);
	vec2 xz = INSTANCE_CUSTOM.xy + VERTEX.xz * size;
	vec3 cam = CAMERA_POSITION_WORLD;
	float d = length(vec2(length(xz - cam.xz), cam_dy));
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

	float dist = length(VERTEX - cam);

	float sun_vis = w_cloud_shadow_v(VERTEX, cam);
	float ramp = w_toon_ramp(dot(n, sun_dir), 0.14, 0.24, 0.40, dist);
	vec3 direct_mul = ramp * light_col * sun_vis / PI;

	// Biome texels are 8 m wide (4x coarser than near vertices), so interpolating them from the
	// vertex stage is exact and avoids an extra fragment fetch.
	vec2 map_uv = clamp(xz / near_size + 0.5, vec2(0.0), vec2(1.0));
	vec3 bio3 = textureLod(biome_tex, map_uv, 0.0).rgb;
	float cotClear = ao_spot.z > 0.1 ? smoothstep(26.0, 48.0, length(xz - ao_spot.xy)) : 1.0;
	float fz = smoothstep(0.46, 0.82, bio3.r) * cotClear * (1.0 - w_near_blend(xz));
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

	float fl_w = smoothstep(26.0, 58.0, dist) * (1.0 - smoothstep(120.0, 165.0, dist)) * smoothstep(0.18, 0.52, bio3.g + bio3.b * 0.18);
	v_bio = vec2(bio3.r, fl_w);
	v_params = vec4(
		1.0 - smoothstep(ground_fade_start, ground_fade_end, dist),
		1.0 - smoothstep(95.0, 170.0, dist),
		1.0 - smoothstep(35.0, 95.0, dist),
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
				near_s = textureLod(ground_atlas, px / ground_atlas_size, 0.0);
				got_near = true;
			}
		}
	}

	vec2 map_uv = clamp(xz / near_size + 0.5, vec2(0.0005), vec2(0.9995));
	vec4 baked;
	if (got_near && near_k >= 0.999) {
		baked = near_s;
	} else {
		vec4 val_s = valley_ready > 0.5
				? textureLod(valley_tex, map_uv, 0.0)
				: vec4(0.32, 0.45, 0.22, 0.0);
		baked = got_near ? mix(val_s, near_s, near_k) : val_s;
	}

	vec3 albedo = baked.rgb * baked.rgb;
	float ff = baked.a;

	// Two isotropic mipmapped noise fetches cover wavelengths from 3.3 m down to 2 cm (noise_tex
	// packs fbm4, fbm8, fbm16 and 1-worley into RGBA). Mipmapping prevents grazing-angle streaks,
	// while fwidth()-widened thresholds keep near patch edges and leaf flecks crisp at 1-2 m.
	float mid_k = v_params.y;
	float hi_k = v_params.z;
	vec4 n_mid = mid_k > 0.001 ? texture(noise_tex, xz * 0.075) : vec4(0.5);
	const mat2 R2 = mat2(vec2(0.28, 0.96), vec2(-0.96, 0.28));
	vec4 n_hi = hi_k > 0.001 ? texture(noise_tex, R2 * xz * 1.65 + 0.17) : vec4(0.5);

	// ---- crisp painted meadow & turf variation ----
	if (mid_k > 0.001 && ff < 0.99) {
		// Inside the near painted-grass ring, keep per-pixel turf variation restrained so the
		// baked 4-tone strokes stay cohesive with the clumped grass bases.
		float paint_calm = painted_ground > 0.5 ? (1.0 - near_k * 0.65) : 1.0;
		float g_cool_f = n_mid.g * 0.62 + n_mid.b * 0.24 + n_hi.r * 0.14;
		float fw_g = clamp(fwidth(g_cool_f) * 1.1, 0.02, 0.16);
		float g_cool = smoothstep(0.54 - fw_g, 0.54 + fw_g, g_cool_f);
		float g_warm = smoothstep(0.56 - fw_g, 0.56 + fw_g, (1.0 - n_mid.g) * 0.62 + n_mid.b * 0.24 + n_hi.r * 0.14);
		vec3 g_col = mix(albedo, albedo * vec3(0.64, 0.84, 0.72), g_cool * 0.42 * hi_k * paint_calm);
		g_col = mix(g_col, g_col * vec3(1.18, 1.10, 0.76), g_warm * 0.34 * hi_k * paint_calm);
		g_col *= 1.0 + (n_mid.b - 0.5) * 0.18 * mid_k * paint_calm + (n_hi.b - 0.5) * 0.18 * hi_k * (0.45 + 0.55 * paint_calm);
		float soil_p = smoothstep(0.76, 0.88, n_hi.a) * smoothstep(0.46, 0.74, n_mid.r) * hi_k * paint_calm;
		g_col = mix(g_col, vec3(0.16, 0.15, 0.08), soil_p * 0.42);
		float fl_k = v_bio.y * hi_k;
		if (fl_k > 0.005) {
			float sp = smoothstep(0.72, 0.80, n_hi.a) * smoothstep(0.35, 0.70, n_mid.b);
			vec3 fcol = n_hi.r < 0.45 ? vec3(0.92, 0.72, 0.20) : (n_hi.r < 0.65 ? vec3(0.86, 0.52, 0.72) : vec3(0.84, 0.84, 0.78));
			g_col = mix(g_col, fcol, sp * fl_k * 0.52);
		}
		albedo = mix(g_col, albedo, ff);
	}

	// ---- crisp forest floor moss cushions, dark soil & fallen leaf litter (0-170 m) ----
	if (ff > 0.005 && mid_k > 0.001) {
		float moss_f = n_mid.g * 0.48 + n_mid.b * 0.32 + mix(0.5, n_hi.r, hi_k) * 0.20;
		float fw_m = clamp(fwidth(moss_f) * 1.1, 0.018, 0.16);
		float moss_m = smoothstep(0.51 - fw_m, 0.51 + fw_m, moss_f);

		float soil_f = n_mid.r * 0.54 + (1.0 - n_mid.g) * 0.30 + mix(0.5, n_hi.r, hi_k) * 0.16;
		float fw_s = clamp(fwidth(soil_f) * 1.1, 0.022, 0.16);
		float soil_m = smoothstep(0.50 - fw_s, 0.50 + fw_s, soil_f);

		vec3 fBase = vec3(0.036, 0.088, 0.032) * (0.78 + 0.42 * n_mid.g);
		vec3 mossC = mix(vec3(0.042, 0.168, 0.038), vec3(0.112, 0.275, 0.055), smoothstep(0.32, 0.76, mix(n_mid.b, n_hi.g, hi_k)));
		fBase = mix(fBase, mossC * (0.84 + 0.32 * n_hi.b), moss_m * 0.84);
		fBase = mix(fBase, vec3(0.086, 0.056, 0.035) * (0.78 + 0.40 * n_hi.b), soil_m * 0.84);

		// Delicate scattered autumn leaf flecks up close (2-7 cm Worley dabs) transitioning smoothly
		// into mipmapped mid-scale leaf-litter clusters out to 170 m.
		float leaf_bed = smoothstep(0.36, 0.68, n_mid.b * 0.55 + n_mid.r * 0.45);
		float leaf_hi_src = n_hi.a * 0.72 + n_hi.b * 0.28;
		float fw_lh = clamp(fwidth(leaf_hi_src) * 0.9, 0.014, 0.14);
		float leaf_hi = smoothstep(0.67 - fw_lh, 0.67 + fw_lh, leaf_hi_src) * smoothstep(0.35, 0.72, n_hi.r) * leaf_bed * hi_k;

		float leaf_mid_src = n_mid.a * 0.58 + n_mid.b * 0.42;
		float fw_lm = clamp(fwidth(leaf_mid_src) * 1.05, 0.025, 0.16);
		float leaf_mid = smoothstep(0.64 - fw_lm, 0.64 + fw_lm, leaf_mid_src) * leaf_bed * (1.0 - hi_k * 0.65);

		float leaf_w = clamp(max(leaf_hi * 0.88, leaf_mid * 0.52), 0.0, 0.88);
		vec3 leafCol = mix(vec3(0.24, 0.125, 0.048), vec3(0.38, 0.22, 0.072), smoothstep(0.46, 0.84, mix(n_mid.a, n_hi.b, hi_k)));
		fBase = mix(fBase, leafCol, leaf_w);

		if (hi_k > 0.35 && soil_m > 0.2) {
			float fpeb = smoothstep(0.84, 0.92, n_hi.a) * smoothstep(0.50, 0.78, n_mid.b) * soil_m * hi_k;
			fBase = mix(fBase, vec3(0.36, 0.33, 0.29) * (0.86 + 0.28 * n_hi.b), fpeb * 0.65);
		}
		albedo = mix(albedo, fBase, ff * 0.94 * mid_k);
	}

	// ---- crisp hiking trail reconstructed per pixel from near_tex.b (1 m to 700 m) ----
	float trail_raw = (texture(near_tex, map_uv).b * 255.0 - 128.0) / 127.0;
	float trail = max(trail_raw, 0.0);
	float trail_glow = 0.0;
	if (trail > 0.01) {
		float h = v_wpos.y;
		float tr1 = mix(0.5, n_mid.g, mid_k);
		float tr2 = mix(0.5, n_mid.b, mid_k);
		float tr3 = mix(0.5, n_hi.r, hi_k);
		float summitNarrow = smoothstep(210.0, 345.0, h) * 0.36;
		float trTuftTongue = smoothstep(0.48, 0.80, tr2 * 0.58 + tr3 * 0.42) * (1.0 - smoothstep(0.58, 0.84, trail)) * 0.18 * mid_k;
		float trailEdge2 = trail + (n_mid.a - 0.5) * 0.10 * mid_k + (tr1 - 0.5) * 0.10 + (tr2 - 0.5) * 0.18 + (tr3 - 0.5) * 0.15 - summitNarrow - trTuftTongue;
		float fw_tr = clamp(fwidth(trailEdge2) * 0.85, 0.010, 0.10);
		float twTrail = smoothstep(0.495 - fw_tr, 0.495 + fw_tr, trailEdge2);

		vec3 tcol = vec3(0.74, 0.50, 0.26) * (0.84 + 0.24 * tr2) * (0.90 + 0.18 * n_mid.r);
		float r1 = (trail - 0.74) * 8.5;
		float r2 = (trail - 0.91) * 9.5;
		float rut = exp(-(r1 * r1)) * 0.32 + exp(-(r2 * r2)) * 0.22;
		tcol *= 1.0 - rut;

		float peb_src = n_hi.a * 0.70 + n_hi.b * 0.30;
		float fw_p = clamp(fwidth(peb_src) * 0.9, 0.014, 0.12);
		float pebbles = smoothstep(0.74 - fw_p, 0.74 + fw_p, peb_src) * smoothstep(0.36, 0.76, n_hi.g) * hi_k;
		float pebShadow = smoothstep(0.62, 0.74, peb_src) * (1.0 - pebbles) * hi_k;
		tcol *= 1.0 - pebShadow * 0.24;
		tcol = mix(tcol, vec3(0.64, 0.58, 0.49) * (0.86 + 0.28 * n_hi.b), pebbles * 0.56);

		float fpath = smoothstep(0.28, 0.68, v_bio.x);
		if (fpath > 0.005) {
			float fLeaf = smoothstep(0.69 - fw_p, 0.69 + fw_p, peb_src) * smoothstep(0.38, 0.74, n_hi.r) * smoothstep(0.30, 0.72, tr1) * hi_k;
			float fLeafMid = smoothstep(0.64, 0.78, n_mid.a) * (1.0 - hi_k * 0.65) * mid_k;
			vec3 earth = vec3(0.155, 0.105, 0.062) * (0.82 + 0.28 * tr2) * (0.88 + 0.24 * n_hi.b);
			earth = mix(earth, vec3(0.095, 0.065, 0.038), smoothstep(0.45, 0.78, n_mid.r) * 0.50);
			earth = mix(earth, mix(vec3(0.34, 0.175, 0.055), vec3(0.46, 0.26, 0.078), n_hi.b), clamp(max(fLeaf * 0.82, fLeafMid * 0.38), 0.0, 0.82));
			earth *= 1.0 - rut * 0.85;
			tcol = mix(tcol, earth, fpath);
		}

		float alp = smoothstep(195.0, 320.0, h) * 0.92;
		if (alp > 0.005) {
			float aCrack = smoothstep(0.0, 0.14, abs(n_hi.g - 0.5));
			float aRock = smoothstep(0.56, 0.72, tr2 * 0.55 + n_hi.b * 0.45);
			float aMoss = smoothstep(0.46, 0.70, tr1) * (1.0 - smoothstep(0.50, 0.76, trailEdge2));
			vec3 alpinePath = vec3(0.28, 0.24, 0.20) * (0.72 + 0.36 * aCrack) * (0.86 + 0.28 * n_hi.b);
			alpinePath = mix(alpinePath, vec3(0.50, 0.46, 0.40) * (0.86 + 0.26 * n_hi.b), aRock * 0.68);
			alpinePath = mix(alpinePath, vec3(0.58, 0.54, 0.47), pebbles * 0.64);
			alpinePath = mix(alpinePath, vec3(0.095, 0.24, 0.055), aMoss * 0.84);
			alpinePath *= 1.0 - rut * 0.90;
			tcol = mix(tcol, alpinePath, alp);
		}

		tcol *= mix(0.62, 1.04, smoothstep(0.49, 0.62, trailEdge2));
		float vergeLip = smoothstep(0.32, 0.48, trailEdge2) * (1.0 - twTrail);
		albedo = mix(albedo, albedo * 0.60 + vec3(0.018, 0.022, 0.008), vergeLip * 0.76);
		albedo = mix(albedo, tcol, twTrail);

		float trM = smoothstep(0.35, 0.60, trail);
		float openPath = 1.0 - smoothstep(0.32, 0.68, v_bio.x) * 0.85;
		trail_glow = trM * openPath;
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
	vec3 emis = vec3(0.12, 0.08, 0.035) * trail_glow * v_params.w;
	vec3 lit = w_light_floor(v_direct * albedo + ind + emis, albedo);
	if (!DBG(DBG_NO_ATM)) {
		lit = lit * v_atm_mul + v_atm_add;
	}
	if (DBG(DBG_OUT_ALBEDO)) {
		lit = albedo;
	}
	ALBEDO = w_grade(lit, SCREEN_UV, VIEWPORT_SIZE);
}
