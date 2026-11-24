// Far terrain shader (systems/terrain.gd): nodes beyond the near/mid split or outside the 4 km
// valley map. Uses the exact same CDLOD vertices and skirt as terrain_baked.gdshader so the split
// is crack-free, moves normals, cloud shadow, toon ramp and peak rim to the vertex stage, reads
// the one-time valley bake inside the valley and 2-fetch painted mountain strata beyond, and keeps
// analytic aerial perspective per pixel so large distant triangles never show fog banding.
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

uniform sampler2D valley_tex : filter_linear, repeat_disable;
uniform float valley_ready = 0.0;

varying vec3 v_wpos;
varying vec3 v_n;
varying vec3 v_direct;
varying vec3 v_hemi;
varying vec3 v_rim;

void vertex() {
	float size = INSTANCE_CUSTOM.z;
	vec2 grid = floor(VERTEX.xz * grid_n + 0.5);
	vec2 xz = INSTANCE_CUSTOM.xy + VERTEX.xz * size;
	float d = length(vec2(length(xz - cam_xz), cam_dy));
	float morph = clamp((d / (lod_k * size) - 1.55) / 0.35, 0.0, 1.0);
	if (size >= 16384.0) morph = 0.0;
	vec2 frac_g = fract(grid * 0.5) * 2.0;
	xz -= frac_g * (size / grid_n) * morph;
	vec3 cam = CAMERA_POSITION_WORLD;
	float fb = w_near_blend(xz);
	float d_est = length(xz - cam_xz);
	float e_near = clamp(d_est * 0.0018, 1.0, 10.0);
	float e_mtn = clamp(d_est * 0.0062, 28.0, 74.0);
	float e = mix(e_near, max(e_near, e_mtn), max(fb, smoothstep(1150.0, 2300.0, d_est)));
	vec3 n;
	float h_surf = w_height_n(xz, e, n);
	float h = h_surf - UV.x * (2.0 + size * 0.015) * skirt_on;
	VERTEX = vec3(xz.x, h, xz.y);
	NORMAL = vec3(0.0, 1.0, 0.0);
	v_wpos = VERTEX;
	v_n = n;
	float dist = length(VERTEX - cam);

	float sun_vis = w_cloud_shadow_v(VERTEX, cam);
	float ramp = w_toon_ramp(dot(n, sun_dir), 0.14, 0.24, 0.40, dist);
	v_direct = ramp * light_col * sun_vis / PI;

	float sky_k = smoothstep(-0.35, 0.85, n.y);
	v_hemi = mix(hemi_ground, hemi_sky, sky_k);

	vec3 rim_col = vec3(0.0);
	float highPeakOnly = smoothstep(1050.0, 1620.0, h) * smoothstep(1400.0, 3400.0, dist);
	if (highPeakOnly > 0.0) {
		vec3 Vw = w_normalize(cam - VERTEX);
		float rim_base = max(1.0 - max(dot(n, Vw), 0.0), 1e-6);
		float rim = pow(rim_base, 2.8) * highPeakOnly;
		float sunSide = smoothstep(0.02, 0.58, dot(n, sun_dir));
		rim_col = light_col * vec3(1.0, 0.95, 0.86) * rim * sunSide * 0.04 * sun_vis * smoothstep(0.0, 0.12, sun_dir.y);
	}
	v_rim = rim_col;
}

void fragment() {
	vec3 cam = CAMERA_POSITION_WORLD;
	vec3 wp = v_wpos;
	vec2 xz = wp.xz;
	float h = wp.y;
	float dist = length(wp - cam);
	float fb = w_near_blend(xz);
	float farZ = smoothstep(1150.0, 2250.0, dist);
	float far_mix = max(farZ, fb);

	vec3 col = vec3(0.0);
	if (far_mix < 0.999) {
		vec4 val_s = valley_ready > 0.5
				? texture(valley_tex, clamp(xz / near_size + 0.5, vec2(0.0005), vec2(0.9995)))
				: vec4(0.32, 0.45, 0.22, 0.0);
		col = val_s.rgb * val_s.rgb;
	}

	if (far_mix > 0.001) {
		const mat2 R1 = mat2(vec2(0.8, -0.6), vec2(0.6, 0.8));
		const mat2 R2 = mat2(vec2(0.28, 0.96), vec2(-0.96, 0.28));
		vec4 nH = texture(noise_tex, R2 * xz * 0.00031 + 0.21);
		vec4 nz = texture(noise_tex, R1 * xz * 0.0019);
		vec3 n = w_normalize(v_n);
		float sB = 1.0 - n.y;
		float strataArg = h * 0.018 + wp.x * 0.00055 - wp.z * 0.00045 + nH.g * 2.2;
		float strataFlat = smoothstep(0.44, 0.56, sin(strataArg) * 0.5 + 0.5);
		float strataCrack = smoothstep(0.0, 0.085, abs(fract(strataArg * 0.31831) - 0.5));
		float diagA = fract((wp.x * 0.0011 + wp.z * 0.0008 - h * 0.0032) + nH.b * 0.55);
		float diagB = fract((wp.x * 0.0007 - wp.z * 0.0012 + h * 0.0024) + nz.r * 0.32);
		float crevInk = min(smoothstep(0.0, 0.055, abs(diagA - 0.5)), mix(0.45, 1.0, smoothstep(0.0, 0.065, abs(diagB - 0.5))));
		float inkPass = mix(0.56, 1.0, min(strataCrack, crevInk));
		vec3 lowPine = mix(vec3(0.055, 0.175, 0.082), vec3(0.115, 0.235, 0.095), smoothstep(0.38, 0.62, nH.r));
		lowPine = mix(lowPine, vec3(0.145, 0.225, 0.105), smoothstep(520.0, 920.0, h) * 0.45);
		float facVal = nH.b * 0.55 + nz.r * 0.45;
		float facBand = smoothstep(0.38, 0.46, facVal) * 0.5 + smoothstep(0.62, 0.70, facVal) * 0.5;
		vec3 stone = mix(vec3(0.11, 0.14, 0.24), vec3(0.24, 0.27, 0.37), smoothstep(0.0, 0.5, facBand));
		stone = mix(stone, vec3(0.40, 0.40, 0.46), smoothstep(0.5, 1.0, facBand) * 0.75 + strataFlat * 0.38);
		stone *= mix(1.0, inkPass, smoothstep(0.26, 0.44, sB));
		float timberAlt = 960.0 + (nH.g - 0.5) * 240.0 - sB * 1350.0;
		float rockMask = smoothstep(timberAlt - 65.0, timberAlt + 70.0, h);
		rockMask = max(rockMask, smoothstep(0.30, 0.37, sB) * smoothstep(460.0, 680.0, h));
		vec3 zc = mix(lowPine, stone, rockMask);
		float sl = 1160.0 + (nH.r - 0.5) * 190.0 - n.z * 110.0;
		float edgeJ = (nz.g - 0.5) * 0.045;
		float snSlope = w_rstep(0.38, 0.34, sB + edgeJ) * smoothstep(sl - 18.0, sl + 18.0, h);
		float snHighCap = w_rstep(0.50, 0.46, sB + edgeJ) * smoothstep(sl + 230.0, sl + 265.0, h);
		float snLedge = strataFlat * w_rstep(0.45, 0.36, sB) * smoothstep(sl + 20.0, sl + 80.0, h) * 0.75;
		float sn = smoothstep(0.35, 0.55, max(max(snSlope, snHighCap), snLedge));
		vec3 snowFarCol = mix(vec3(0.88, 0.93, 1.0), vec3(0.995, 0.998, 1.0), smoothstep(sl + 60.0, sl + 360.0, h));
		zc = mix(zc, snowFarCol, sn);
		col = far_mix >= 0.999 ? zc : mix(col, zc, far_mix);
	}

	vec3 ind = v_hemi * col;
	ind = max(mix(vec3(w_luma(ind)), ind, 1.18), 0.0) * shadow_ambient_tint * ambient_boost;
	ind = w_light_floor(ind, col);
	vec3 lit = w_light_floor(v_direct * col + ind + v_rim, col);
	vec3 atm_mul;
	vec3 atm_add;
	w_atmosphere(wp, cam, atm_mul, atm_add);
	if (DBG(DBG_NO_ATM)) {
		atm_mul = vec3(1.0);
		atm_add = vec3(0.0);
	}
	lit = lit * atm_mul + atm_add;
	if (DBG(DBG_OUT_ALBEDO)) {
		lit = col;
	}
	ALBEDO = w_grade(lit, SCREEN_UV, VIEWPORT_SIZE);
}
