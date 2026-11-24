// Stillwater's terrain (src/world/terrain.js + src/glsl/common.js + src/patch.js) on Godot.
//
// Geometry: one instanced grid patch drawn once per quadtree node (INSTANCE_CUSTOM = x0, z0, size),
// with Stillwater's CDLOD morph so a patch's edge vertices fold onto its coarser neighbour's grid,
// plus a skirt as a backstop.
//
// Heights are integer codes in 8-bit channels, sampled with texelFetch and filtered by hand:
// float-linear filtering is optional on iOS, and filtering the byte split in hardware is not exact.
//
// Lighting is Stillwater's own model done here (unshaded): the 3-band toon sun ramp, the
// hemisphere sky/ground fill with its cool tint, the emissive extras, then the analytic aerial
// perspective and the post grade. Not ported: the ray-marched terrain self-shadow (sun visibility
// uses the cloud shadow only), Godot's shadow map (no casters yet), bloom, FXAA, grain.
shader_type spatial;
render_mode unshaded, fog_disabled, cull_back;

#include "res://shaders/stillwater.gdshaderinc"

uniform sampler2D near_tex : filter_linear, repeat_disable;
uniform sampler2D far_tex : filter_nearest, repeat_disable;
uniform sampler2D biome_tex : filter_linear, repeat_disable;
uniform float near_size = 4096.0;
uniform float near_min;
uniform float near_step;
uniform float far_size = 32768.0;
uniform float far_min;
uniform float far_step;
uniform float water_level = 22.0;

uniform float grid_n = 32.0;
uniform float lod_k = 3.0;
uniform vec2 cam_xz;
uniform float cam_dy;
uniform float skirt_on = 1.0;

uniform vec3 hemi_sky = vec3(0.4036, 0.6208, 0.9223);
uniform vec3 hemi_ground = vec3(0.2488, 0.2827, 0.2194);
uniform vec3 fog_beta = vec3(2.4e-5, 4.6e-5, 1.18e-4);
uniform float fog_falloff = 0.00086957;
uniform float mist = 0.028;
uniform float cloud_cover = 0.329;
uniform vec2 cloud_offset = vec2(-223.16, -143.45);
uniform vec2 wind_dir = vec2(0.8253, 0.5646);
uniform vec4 ao_spot = vec4(615.25, 796.96, 7.5, 0.35);
uniform vec4 waterfall = vec4(-893.95, 132.59, 118.0, 58.0);

varying vec3 wpos;

// ---------------- heights ----------------
float near_code(ivec2 i) {
	vec2 t = floor(texelFetch(near_tex, i, 0).rg * 255.0 + 0.5);
	return t.x + t.y * 256.0;
}

float far_code(ivec2 i) {
	vec3 t = floor(texelFetch(far_tex, i, 0).rgb * 255.0 + 0.5);
	return t.x + t.y * 256.0 + t.z * 65536.0;
}

// HeightField._sample: texel centres, edge clamp at res - 1.001.
float w_height_near(vec2 xz) {
	float res = float(textureSize(near_tex, 0).x);
	vec2 f = clamp((xz / near_size + 0.5) * res - 0.5, vec2(0.0), vec2(res - 1.001));
	vec2 fl = floor(f);
	ivec2 i = ivec2(fl);
	vec2 t = f - fl;
	float a = near_code(i);
	float b = near_code(i + ivec2(1, 0));
	float c = near_code(i + ivec2(0, 1));
	float d = near_code(i + ivec2(1, 1));
	return near_min + near_step * mix(mix(a, b, t.x), mix(c, d, t.x), t.y);
}

float w_height_far(vec2 xz) {
	float res = float(textureSize(far_tex, 0).x);
	vec2 f = clamp((xz / far_size + 0.5) * res - 0.5, vec2(0.0), vec2(res - 1.001));
	vec2 fl = floor(f);
	ivec2 i = ivec2(fl);
	vec2 t = f - fl;
	float a = far_code(i);
	float b = far_code(i + ivec2(1, 0));
	float c = far_code(i + ivec2(0, 1));
	float d = far_code(i + ivec2(1, 1));
	return far_min + far_step * mix(mix(a, b, t.x), mix(c, d, t.x), t.y);
}

float w_near_blend(vec2 xz) {
	float e = max(abs(xz.x), abs(xz.y));
	return smoothstep(near_size * 0.5 - 220.0, near_size * 0.5 - 20.0, e);
}

float w_height(vec2 xz) {
	float t = w_near_blend(xz);
	if (t <= 0.0) return w_height_near(xz);
	if (t >= 1.0) return w_height_far(xz);
	return mix(w_height_near(xz), w_height_far(xz), t);
}

vec3 w_normal(vec2 xz, float e) {
	float hx0 = w_height(xz - vec2(e, 0.0));
	float hx1 = w_height(xz + vec2(e, 0.0));
	float hz0 = w_height(xz - vec2(0.0, e));
	float hz1 = w_height(xz + vec2(0.0, e));
	return normalize(vec3(hx0 - hx1, 2.0 * e, hz0 - hz1));
}

float w_trail_raw(vec2 xz) {
	vec2 uv = xz / near_size + 0.5;
	if (any(lessThan(uv, vec2(0.0))) || any(greaterThan(uv, vec2(1.0)))) return 0.0;
	return (texture(near_tex, uv).b * 255.0 - 128.0) / 127.0;
}

vec4 w_biome(vec2 xz) {
	vec4 b = vec4(texture(biome_tex, xz / near_size + 0.5).rgb, 1.0);
	return mix(b, vec4(0.55, 0.0, 0.3, 0.0), w_near_blend(xz));
}

vec3 w_grass_color(vec2 xz, float h) {
	vec4 a = texture(noise_tex, xz * 0.0014 + 0.11);
	vec4 b = texture(noise_tex, xz * 0.0075 + 0.37);
	vec4 big = texture(noise_tex, xz * 0.00052 + 0.6);
	vec4 mac = texture(noise_tex, xz * 0.00026 + 0.83);
	vec4 patch_m = texture(noise_tex, xz * 0.0034 + 0.19);
	float t = a.r * 0.54 + b.g * 0.46;
	vec3 c = mix(vec3(0.042, 0.195, 0.052), vec3(0.135, 0.375, 0.072), smoothstep(0.20, 0.56, t));
	c = mix(c, vec3(0.36, 0.46, 0.11), smoothstep(0.50, 0.80, t) * 0.82);
	c = mix(c, vec3(0.036, 0.215, 0.095), smoothstep(0.42, 0.74, big.g) * 0.68);
	c = mix(c, vec3(0.44, 0.45, 0.13), smoothstep(0.46, 0.76, big.b) * 0.62);
	c = mix(c, vec3(0.49, 0.41, 0.15), smoothstep(0.50, 0.76, mac.r) * 0.58);
	c = mix(c, vec3(0.052, 0.24, 0.105), smoothstep(0.48, 0.76, patch_m.b) * 0.52);
	c = mix(c, vec3(0.28, 0.42, 0.12), smoothstep(0.58, 0.82, patch_m.r) * 0.42);
	c = mix(c, vec3(0.42, 0.46, 0.18), smoothstep(640.0, 1020.0, h + (a.b - 0.5) * 180.0));
	return c;
}

// ---------------- clouds and atmosphere ----------------
float w_cloud_shadow(vec3 wp, vec3 cam) {
	vec3 L = sun_dir;
	vec2 xz = wp.xz + L.xz / max(L.y, 0.12) * (2600.0 - wp.y);
	vec2 p = (xz + cloud_offset) * 0.000048;
	vec4 a = texture(noise_tex, p);
	vec4 b = texture(noise_tex, p * 2.2 + a.xy * 0.12 + 0.37);
	float n = a.r * 0.70 + a.g * 0.20 + b.b * 0.10;
	float d = smoothstep(1.0 - cloud_cover - 0.08, 1.0 - cloud_cover + 0.46, n);
	float far_k = smoothstep(400.0, 1800.0, length(wp - cam));
	float mountain_fade = 1.0 - smoothstep(220.0, 400.0, wp.y);
	float strength = mix(0.24, 0.44, far_k) * mountain_fade * smoothstep(0.03, 0.16, L.y);
	return 1.0 - strength * smoothstep(0.18, 0.74, d);
}

// w_atmosphere with the terrain self-shadow term at 1 (not ported).
void w_atmosphere(vec3 wp, vec3 cam, out vec3 atm_mul, out vec3 atm_add) {
	vec3 d = wp - cam;
	float dist = length(d);
	vec3 dir = d / max(dist, 1e-3);
	float fh = fog_falloff;
	float k = dir.y * dist * fh;
	float integ = abs(k) > 1e-4 ? (1.0 - exp(-k)) / k : 1.0;
	float od = min(dist * exp(-cam.y * fh) * integ, 8500.0 + dist * 0.22);
	vec3 ext = exp(-od * fog_beta);
	float mf = 1.0 / 55.0;
	float ya = cam.y - (water_level + 8.0);
	float yb = wp.y - (water_level + 8.0);
	float dy = yb - ya;
	float avg_d = abs(dy) > 0.5 ? (exp(-max(min(ya, yb), 0.0) * mf) - exp(-max(max(ya, yb), 0.0) * mf)) / (abs(dy) * mf) : exp(-max(ya, 0.0) * mf);
	float extm = exp(-mist * dist * avg_d * 0.0018);

	vec3 hd = normalize(vec3(dir.x, max(dir.y, 0.0) * 0.8 + 0.04 + max(-dir.y, 0.0) * 0.55, dir.z));
	vec3 insc = w_sky(hd);
	{
		float li = w_luma(insc);
		insc = max(mix(vec3(li), insc, 1.18), 0.0);
		insc.g = min(insc.g, (insc.r + insc.b) * 0.55);
	}
	vec3 zen = w_sky(vec3(0.0, 1.0, 0.0));
	float zl = w_luma(zen);
	vec3 mist_col = mix(vec3(zl), zen, 0.55) * vec3(0.92, 0.98, 1.16) * 1.55 + light_col * 0.05 * pow(max(dot(dir, sun_dir), 0.0), 4.0);

	atm_mul = ext * extm;
	atm_add = (insc * (1.0 - ext)) * extm + mist_col * (1.0 - extm);

	if (dist > 1450.0) {
		vec3 sky_hor = w_sky(normalize(vec3(dir.x, 0.14, dir.z)));
		vec3 sky_mid = w_sky(normalize(vec3(dir.x, 0.28, dir.z)));
		float lh = w_luma(sky_hor);
		vec3 airy = max(mix(vec3(lh), mix(sky_hor, sky_mid, 0.45), 1.12) * vec3(0.92, 0.98, 1.18), vec3(0.0));
		float high_look = smoothstep(200.0, 380.0, cam.y) * smoothstep(0.05, -0.18, dir.y);
		float low_basin = exp(-max(wp.y - water_level - 18.0, 0.0) / 260.0);
		float peak_crisp = 1.0 - 0.42 * smoothstep(520.0, 1450.0, wp.y);
		float a1 = clamp(smoothstep(1450.0, 3600.0, dist) * (0.10 + 0.32 * low_basin) * peak_crisp * (1.0 - 0.56 * high_look), 0.0, 0.40);
		vec3 tint1 = mix(airy * 1.06, insc * 1.04, 0.22);
		atm_mul *= 1.0 - a1;
		atm_add = atm_add * (1.0 - a1) + tint1 * a1;
		float a2 = clamp(smoothstep(3500.0, 7200.0, dist) * (0.16 + 0.18 * low_basin) * peak_crisp, 0.0, 0.38);
		vec3 tint2 = mix(airy * 1.12, insc * 1.06, 0.28);
		atm_mul *= 1.0 - a2;
		atm_add = atm_add * (1.0 - a2) + tint2 * a2;
		float peak_clear = smoothstep(1150.0, 1950.0, wp.y);
		float a3 = clamp(smoothstep(6800.0, 14200.0, dist) * mix(0.42, 0.22, peak_clear), 0.0, 0.48);
		vec3 tint3 = mix(airy * 1.18, insc * 1.08, 0.30);
		atm_mul *= 1.0 - a3;
		atm_add = atm_add * (1.0 - a3) + tint3 * a3;
	}
}

// ---------------- surface ----------------
vec4 cliff_plane(vec2 p) {
	vec4 vn = texture(noise_tex, p * 0.022);
	vec4 vf = texture(noise_tex, p * 0.14 + 0.37);
	float hi1 = n_noise(p * 0.45 + vec2(3.1, 7.4));
	float hi2 = n_noise(p * 1.35 + vec2(9.2, 1.8));
	float y_warp = p.y + (vn.r - 0.5) * 0.78 + (hi1 - 0.5) * 0.32;
	float x_warp = p.x + (vn.g - 0.5) * 1.25 + (hi1 - 0.5) * 0.42;
	float strata_band = fract(y_warp * 0.18 + vn.b * 0.10);
	float strata_top = smoothstep(0.68, 0.78, strata_band);
	float strata_under = smoothstep(0.18, 0.04, strata_band);
	float b1 = texture(noise_tex, vec2(x_warp * 0.055 + 0.13, floor(y_warp * 0.18) * 0.27)).r;
	float b2 = texture(noise_tex, vec2(x_warp * 0.11 + 0.47, y_warp * 0.085)).g;
	float facet = b1 * 0.52 + b2 * 0.32 + hi1 * 0.16;
	float plane_step = smoothstep(0.32, 0.37, facet) * 0.50 + smoothstep(0.60, 0.65, facet) * 0.50;
	float shelf_edge = max(strata_top * 0.88, smoothstep(0.62, 0.72, b2 * 0.7 + hi1 * 0.3) * smoothstep(0.36, 0.66, vn.b));
	float joint_h = smoothstep(0.0, 0.055, abs(strata_band - 0.04));
	float joint_v = smoothstep(0.0, 0.045, abs(fract(x_warp * 0.095 + floor(y_warp * 0.18) * 0.41 + vn.a * 0.22) - 0.5));
	float crevice = mix(0.28, 1.0, min(joint_h, joint_v) * 0.78 + 0.22 * smoothstep(0.24, 0.68, vf.b * 0.6 + hi2 * 0.4));
	vec3 c = mix(vec3(0.10, 0.13, 0.21), vec3(0.35, 0.36, 0.40), smoothstep(0.0, 0.50, plane_step));
	c = mix(c, vec3(0.60, 0.56, 0.48), smoothstep(0.46, 1.0, plane_step) * 0.82 + strata_top * 0.52);
	c *= mix(1.0, 0.42, strata_under * 0.85);
	c *= crevice * (0.88 + 0.22 * hi2);
	float moss_spot = shelf_edge * smoothstep(0.36, 0.60, vn.g * 0.6 + hi1 * 0.4);
	return vec4(c, (moss_spot * 1.25 + strata_top * 0.62) - strata_under * 0.92 - (1.0 - crevice) * 0.80);
}

void vertex() {
	float size = INSTANCE_CUSTOM.z;
	vec2 grid = floor(VERTEX.xz * grid_n + 0.5);
	vec2 xz = INSTANCE_CUSTOM.xy + VERTEX.xz * size;
	float d = length(vec2(length(xz - cam_xz), cam_dy));
	float morph = clamp((d / (lod_k * size) - 1.55) / 0.35, 0.0, 1.0);
	if (size >= 16384.0) morph = 0.0;
	vec2 frac_g = fract(grid * 0.5) * 2.0;
	xz -= frac_g * (size / grid_n) * morph;
	float h = w_height(xz) - UV.x * (2.0 + size * 0.015) * skirt_on;
	VERTEX = vec3(xz.x, h, xz.y);
	NORMAL = vec3(0.0, 1.0, 0.0);
	wpos = VERTEX;
}

void fragment() {
	vec3 cam = CAMERA_POSITION_WORLD;
	vec3 wp = wpos;
	float dist = length(wp - cam);
	vec2 xz = wp.xz;
	float fb = w_near_blend(xz);
	float h = wp.y;
	float e_near = clamp(dist * 0.0018, 1.0, 10.0);
	float e_mtn = clamp(dist * 0.0062, 28.0, 74.0);
	float e = mix(e_near, max(e_near, e_mtn), max(fb, smoothstep(1150.0, 2300.0, dist)));
	vec3 n = w_normal(xz, e);
	const mat2 R1 = mat2(vec2(0.8, -0.6), vec2(0.6, 0.8));
	const mat2 R2 = mat2(vec2(0.28, 0.96), vec2(-0.96, 0.28));
	vec4 nH = texture(noise_tex, R2 * xz * 0.00031 + 0.21);
	vec4 nz = texture(noise_tex, R1 * xz * 0.0019);
	float fadeM = 1.0 - smoothstep(600.0, 2600.0, dist);
	float fadeD = 1.0 - smoothstep(80.0, 450.0, dist);
	float fadeF = 1.0 - smoothstep(18.0, 100.0, dist);
	vec4 nm = mix(vec4(0.5), texture(noise_tex, xz * 0.013), fadeM);
	vec4 nd = mix(vec4(0.5), texture(noise_tex, R2 * xz * 0.11), fadeD);
	vec4 nf = mix(vec4(0.5), texture(noise_tex, xz * 0.63), fadeF);
	float slope_fine = 1.0 - n.y;
	vec3 n_pre = n;
	float slope = slope_fine;
	float broad_k = smoothstep(700.0, 2800.0, dist) * 0.72;
	if (broad_k > 0.0) {
		float broad_e = mix(e, max(e * 2.0, 32.0), smoothstep(600.0, 2800.0, dist));
		slope = mix(slope_fine, 1.0 - w_normal(xz, broad_e).y, broad_k);
	}
	vec4 bio = w_biome(xz);
	float trail_raw = w_trail_raw(xz);
	float trail = max(trail_raw, 0.0);
	float bed = max(-trail_raw, 0.0);
	vec2 fall = normalize(n.xz + 1e-4);
	vec2 across = vec2(-fall.y, fall.x);
	vec2 gp = vec2(dot(xz, across) * 0.018, dot(xz, fall) * 0.0024);
	float gully = texture(noise_tex, gp).g * 0.58 + texture(noise_tex, gp * 3.1 + 0.4).b * 0.42;
	float t_wet = 0.0;
	float t_snow_far = 0.0;

	vec3 forestF = vec3(0.045, 0.155, 0.055);
	vec3 rockA = vec3(0.32, 0.31, 0.34);
	vec3 rockB = vec3(0.58, 0.53, 0.48);
	vec3 rockW_ = vec3(0.56, 0.46, 0.37);
	vec3 dirt = vec3(0.74, 0.50, 0.26);
	vec3 sand = vec3(0.76, 0.66, 0.47);
	vec3 snow = vec3(0.99, 0.995, 1.0);
	vec3 mud = vec3(0.28, 0.31, 0.22);

	vec3 grass = w_grass_color(xz, h) * (0.90 + 0.18 * nd.b);
	{
		float nearK = 1.0 - smoothstep(26.0, 96.0, dist);
		if (nearK > 0.005) {
			float gMacro = n_noise(xz * 0.42 + vec2(1.9, 7.3));
			float gClover = n_noise(xz * 1.45 + vec2(4.2, 1.9));
			float gTuft = n_noise(xz * 4.8 + vec2(8.7, 3.3));
			float gStroke = n_noise(vec2(xz.x * 9.5 + gClover * 1.6, xz.y * 4.2));
			grass = mix(grass, grass * vec3(0.56, 0.78, 0.68), smoothstep(0.46, 0.76, gClover * 0.6 + gMacro * 0.4) * nearK * 0.68);
			grass = mix(grass, grass * vec3(1.24, 1.12, 0.72), smoothstep(0.52, 0.80, (1.0 - gClover) * 0.55 + gMacro * 0.45) * nearK * 0.54);
			grass *= mix(1.0, 0.76 + 0.44 * smoothstep(0.20, 0.80, gTuft * 0.55 + gStroke * 0.45), nearK);
			float soilPeek = smoothstep(0.72, 0.88, gTuft) * smoothstep(0.50, 0.78, nd.r) * nearK;
			grass = mix(grass, vec3(0.16, 0.15, 0.08), soilPeek * 0.55);
		}
		float tuftK = smoothstep(12.0, 38.0, dist) * (1.0 - smoothstep(550.0, 1450.0, dist));
		vec4 tf = texture(noise_tex, xz * 0.24 + 0.77);
		vec4 tf2 = texture(noise_tex, xz * 0.78 + 0.19);
		grass *= mix(1.0, 0.84 + 0.30 * smoothstep(0.24, 0.76, tf.a * 0.65 + tf2.g * 0.35), tuftK);
		grass = mix(grass, grass * vec3(1.20, 1.10, 0.74), smoothstep(0.46, 0.76, texture(noise_tex, xz * 0.032 + 0.13).b) * tuftK * 0.64);
		grass = mix(grass, grass * vec3(0.70, 0.90, 0.80), smoothstep(0.48, 0.76, texture(noise_tex, xz * 0.018 + 0.61).r) * tuftK * 0.54);
		float flK = smoothstep(26.0, 58.0, dist) * (1.0 - smoothstep(160.0, 320.0, dist)) * smoothstep(0.18, 0.52, bio.g + bio.b * 0.18);
		vec4 fs1 = texture(noise_tex, xz * 0.85 + 0.41);
		float speck = smoothstep(0.70, 0.78, fs1.a);
		vec3 fcol = fs1.r < 0.45 ? vec3(0.92, 0.72, 0.20) : fs1.r < 0.65 ? vec3(0.86, 0.52, 0.72) : vec3(0.84, 0.84, 0.78);
		grass = mix(grass, fcol, speck * flK * 0.68);
	}
	vec3 col = grass;
	float forest = smoothstep(0.12, 0.55, bio.r);
	float farF = fb * smoothstep(1040.0, 860.0, h + (nH.g - 0.5) * 90.0) * smoothstep(0.48, 0.28, slope) * smoothstep(160.0, 340.0, h);
	forest = max(forest * (1.0 - fb), farF);
	float crowns = texture(noise_tex, xz * 0.042).a * 0.6 + texture(noise_tex, xz * 0.014).a * 0.4;
	vec3 forestHue = mix(forestF, vec3(0.068, 0.20, 0.062), smoothstep(0.32, 0.78, nH.r));
	forestHue = mix(forestHue, vec3(0.032, 0.14, 0.095), smoothstep(0.52, 0.80, nz.b) * 0.65);
	vec3 canopy = mix(vec3(0.042, 0.165, 0.072), vec3(0.078, 0.225, 0.074), smoothstep(0.30, 0.78, nH.r));
	canopy *= 0.80 + 0.32 * smoothstep(0.26, 0.76, crowns);
	vec3 fCol = mix(forestHue * (0.72 + 0.54 * crowns), canopy, smoothstep(260.0, 920.0, dist));
	col = mix(col, fCol, forest);
	col *= mix(1.0, 0.68, smoothstep(0.28, 0.74, bio.r) * (1.0 - fb));
	{
		float cotClear = ao_spot.z > 0.1 ? smoothstep(26.0, 48.0, length(xz - ao_spot.xy)) : 1.0;
		float ff = smoothstep(0.44, 0.80, bio.r) * cotClear * fadeD;
		if (ff > 0.005) {
			vec4 lf = texture(noise_tex, xz * 0.14 + 0.13);
			float mossCushion = n_noise(xz * 1.45 + vec2(2.3, 5.7));
			float leafLarge = n_noise(xz * 5.8 + vec2(7.1, 1.4));
			float leafCrisp = n_noise(xz * 14.5 + vec2(3.9, 8.2));
			float rootStreak = n_noise(vec2(xz.x * 2.2 + mossCushion * 1.4, xz.y * 7.5));
			float fPebble = smoothstep(0.84, 0.91, n_noise(xz * 8.2 + vec2(11.3, 4.1))) * smoothstep(0.45, 0.75, lf.b);
			vec3 fBase = vec3(0.036, 0.088, 0.032) * (0.78 + 0.42 * mossCushion);
			float mossMask = smoothstep(0.36, 0.66, mossCushion * 0.65 + lf.g * 0.35);
			vec3 mossC = mix(vec3(0.042, 0.175, 0.038), vec3(0.115, 0.285, 0.058), smoothstep(0.35, 0.75, leafLarge));
			fBase = mix(fBase, mossC * (0.82 + 0.36 * leafCrisp), mossMask * 0.85);
			float soilMask = smoothstep(0.45, 0.74, lf.r * 0.6 + (1.0 - mossCushion) * 0.4);
			fBase = mix(fBase, vec3(0.088, 0.058, 0.036) * (0.76 + 0.44 * leafCrisp), soilMask * 0.82);
			fBase = mix(fBase, vec3(0.16, 0.11, 0.068), smoothstep(0.76, 0.88, rootStreak) * soilMask * 0.55);
			float leafBed = smoothstep(0.44, 0.68, leafLarge * 0.6 + lf.b * 0.4);
			float leafFleck = smoothstep(0.54, 0.76, leafCrisp) * leafBed;
			vec3 leafCol = mix(vec3(0.24, 0.125, 0.048), vec3(0.38, 0.22, 0.072), smoothstep(0.58, 0.86, leafCrisp));
			fBase = mix(fBase, leafCol, leafFleck * 0.88);
			fBase = mix(fBase, vec3(0.34, 0.33, 0.31) * (0.85 + 0.3 * leafCrisp), fPebble * 0.78);
			col = mix(col, fBase, ff * 0.94);
		}
	}

	float strata = smoothstep(0.28, 0.72, sin(h * 0.045 + nz.g * 3.4 + gully * 3.2) * 0.5 + 0.5);
	vec3 rock = mix(rockA, rockB, strata * 0.22 + gully * 0.52 + nH.b * 0.22);
	rock = mix(rock, rockW_, smoothstep(0.55, 0.8, nH.g) * 0.42 * (1.0 - smoothstep(600.0, 2000.0, dist)));
	rock *= 0.88 + 0.22 * nf.g;

	vec3 cliffNAdd = vec3(0.0);
	float cliffW = smoothstep(0.26, 0.50, slope_fine);
	float wfZone = waterfall.w > 0.1 ? (1.0 - smoothstep(waterfall.w * 0.55, waterfall.w * 1.45, length(wp.xz - waterfall.xz))) : 0.0;
	// The triplanar cliff only shows where it is steep and within 1.5 km; skipping it elsewhere
	// changes cost, not colour (its weight there is exactly 0).
	float cliffK = cliffW * (1.0 - smoothstep(550.0, 1500.0, dist));
	if (cliffK > 0.0 || (cliffW > 0.0 && fadeM > 0.0)) {
		vec3 tw = pow(abs(n_pre), vec3(6.0));
		tw /= max(tw.x + tw.y + tw.z, 1e-4);
		vec4 cX = cliff_plane(vec2(wp.z, wp.y));
		vec4 cZ = cliff_plane(vec2(wp.x, wp.y));
		vec4 cY = cliff_plane(vec2(wp.x, wp.z));
		vec3 cliffC = cX.rgb * tw.x + cZ.rgb * tw.z + cY.rgb * tw.y;
		float shelfStep = cX.a * tw.x + cZ.a * tw.z;
		vec4 vf = texture(noise_tex, vec2(wp.z, wp.y) * 0.26 + 0.37) * tw.x
				+ texture(noise_tex, vec2(wp.x, wp.z) * 0.26 + 0.37) * tw.y
				+ texture(noise_tex, vec2(wp.x, wp.y) * 0.26 + 0.37) * tw.z;
		float topFace = smoothstep(0.52, 0.82, n_pre.y);
		float ledgeMoss = smoothstep(0.28, 0.78, shelfStep) * (0.45 + 0.55 * smoothstep(0.12, 0.46, n_pre.y));
		float shelfMoss = clamp(topFace + ledgeMoss * (0.55 + 0.45 * wfZone), 0.0, 1.0) * smoothstep(0.26, 0.66, vf.g + nd.r * 0.26) * smoothstep(950.0, 500.0, h);
		vec3 mossCol = mix(vec3(0.065, 0.24, 0.055), vec3(0.17, 0.39, 0.075), vf.b);
		cliffC = mix(cliffC, mossCol, shelfMoss * 0.90);
		if (wfZone > 0.01) {
			float wfd = length(wp.xz - waterfall.xz);
			float wfWet = 1.0 - smoothstep(waterfall.w * 0.14, waterfall.w * 0.56, wfd);
			cliffC = mix(cliffC, cliffC * vec3(0.36, 0.42, 0.52), wfWet * 0.76);
			t_wet = max(t_wet, wfWet * cliffW * 0.34);
		}
		rock = mix(rock, cliffC, cliffK);
		cliffNAdd = vec3((vf.r - 0.5) * 0.24, shelfStep * 0.96, (vf.b - 0.5) * 0.24) * cliffW * fadeM;
	}

	rock *= mix(mix(0.66, 1.08, smoothstep(0.28, 0.65, gully)), 1.0, wfZone);
	float altR = smoothstep(980.0, 1480.0, h + (nH.g - 0.5) * 260.0);
	float noiseK = 1.0 - smoothstep(800.0, 2400.0, dist);
	float rockEdge = mix(0.06, 0.025, 1.0 - noiseK);
	float steepThresh = mix(0.68, 0.44, smoothstep(540.0, 920.0, h)) - altR * 0.18;
	steepThresh = mix(steepThresh, 0.20, wfZone);
	float rockW = smoothstep(steepThresh, steepThresh + rockEdge, max(slope, slope_fine * wfZone) + ((nz.b - 0.5) * 0.035 + (gully - 0.5) * 0.03) * noiseK);
	float scree = smoothstep(0.38, 0.54, slope) * (1.0 - rockW) * smoothstep(0.60, 0.82, gully + nz.r * 0.22) * smoothstep(760.0, 1180.0, h);
	col = mix(col, mix(rockB * 0.72, vec3(0.14, 0.24, 0.085), 0.72) * (0.88 + 0.22 * nf.r), scree * 0.14 * (1.0 - smoothstep(450.0, 1500.0, dist)));
	col = mix(col, rock, rockW);

	float snowLine = 1780.0 + (nH.r - 0.5) * 220.0 - n.z * 90.0;
	float slopeCap = smoothstep(0.56, 0.38, slope);
	float snowEdge = (nz.g - 0.5) * 110.0 + (nm.a - 0.5) * 60.0;
	float snowW = smoothstep(snowLine + snowEdge * noiseK, snowLine + snowEdge * noiseK + 22.0, h) * smoothstep(0.0, 0.08, slopeCap - 0.42);
	snowW = max(snowW, smoothstep(snowLine + 320.0, snowLine + 520.0, h) * smoothstep(0.76, 0.58, slope));
	col = mix(col, snow * (0.92 + 0.08 * nd.b), snowW);

	float wl = water_level;
	vec4 shN = texture(noise_tex, xz * 0.009 + 0.42);
	vec4 shN2 = texture(noise_tex, xz * 0.045 + 0.19);
	float beachWidth = mix(0.18, 1.35, smoothstep(0.32, 0.72, shN.r));
	float shore = (1.0 - smoothstep(0.05, beachWidth, abs(h - wl - 0.15) + (shN2.g - 0.5) * 0.35)) * smoothstep(0.28, 0.55, shN.g + 0.15);
	float pebbleMask = smoothstep(0.45, 0.68, shN2.a);
	vec3 beachCol = mix(sand * (0.85 + 0.25 * nf.b), vec3(0.48, 0.45, 0.40) * (0.8 + 0.38 * nf.a), pebbleMask * 0.75);
	col = mix(col, beachCol, shore * (1.0 - rockW) * 0.88);
	float under = smoothstep(wl + 0.12, wl - 0.55, h);
	col = mix(col, mix(sand * 0.78, mud, smoothstep(wl - 0.6, wl - 4.5, h)), under);
	t_wet = max(t_wet, 1.0 - smoothstep(wl - 0.1, wl + 0.55, h));

	// hiking trail
	float trHi1 = n_noise(xz * 2.1 + vec2(1.7, 5.2));
	float trHi2 = n_noise(xz * 7.2 + vec2(6.3, 2.9));
	float trGrit = n_noise(xz * 22.0 + vec2(2.1, 8.4));
	float trMicro = n_noise(xz * 44.0 + vec2(7.7, 1.3));
	float summitNarrow = smoothstep(210.0, 345.0, h) * 0.36;
	float trTuftTongue = smoothstep(0.46, 0.78, trHi1 * 0.62 + trHi2 * 0.38) * (1.0 - smoothstep(0.68, 0.94, trail)) * 0.28;
	float trailEdge2 = trail + (nd.g - 0.5) * 0.16 + (trHi1 - 0.5) * 0.26 + (trHi2 - 0.5) * 0.15 - summitNarrow - trTuftTongue;
	float twTrail = smoothstep(0.48, 0.515, trailEdge2);
	vec4 cb2 = texture(noise_tex, xz * 0.85 + 0.31);
	vec3 tcol = dirt * (0.82 + 0.24 * trHi2) * (0.90 + 0.20 * nz.r);
	float rut = exp(-pow((trail - 0.74) * 8.5, 2.0)) * 0.32 + exp(-pow((trail - 0.91) * 9.5, 2.0)) * 0.22;
	tcol *= 1.0 - rut;
	float pebbles = smoothstep(0.70, 0.81, trGrit * 0.65 + trMicro * 0.35) * smoothstep(0.32, 0.74, trHi2);
	float pebShadow = smoothstep(0.62, 0.74, trGrit) * (1.0 - pebbles);
	tcol *= 1.0 - pebShadow * 0.26;
	tcol = mix(tcol, vec3(0.64, 0.58, 0.49) * (0.86 + 0.28 * trMicro), pebbles * 0.58);
	{
		float fpath = smoothstep(0.28, 0.68, bio.r);
		float fRoot = smoothstep(0.74, 0.86, n_noise(vec2(xz.x * 2.4 + trHi1 * 1.5, xz.y * 8.2)));
		float fLeaf = smoothstep(0.64, 0.80, trGrit * 0.55 + trMicro * 0.45) * smoothstep(0.32, 0.70, trHi1);
		vec3 earth = vec3(0.155, 0.105, 0.062) * (0.80 + 0.32 * trHi2) * (0.88 + 0.24 * trMicro);
		earth = mix(earth, vec3(0.095, 0.065, 0.038), smoothstep(0.45, 0.78, cb2.r) * 0.50);
		earth = mix(earth, vec3(0.22, 0.145, 0.082), fRoot * 0.68);
		earth = mix(earth, mix(vec3(0.34, 0.175, 0.055), vec3(0.46, 0.26, 0.078), trMicro), fLeaf * 0.84);
		earth *= 1.0 - rut * 0.85;
		tcol = mix(tcol, earth, fpath);
		float aCrack = smoothstep(0.0, 0.14, abs(n_noise(xz * 6.5 + vec2(3.1, 8.2)) - 0.5));
		float aRock = smoothstep(0.56, 0.72, trHi2 * 0.55 + trGrit * 0.45);
		float aMoss = smoothstep(0.46, 0.70, trHi1) * (1.0 - smoothstep(0.50, 0.76, trailEdge2));
		vec3 alpinePath = vec3(0.28, 0.24, 0.20) * (0.70 + 0.40 * aCrack) * (0.82 + 0.34 * trMicro);
		alpinePath = mix(alpinePath, vec3(0.50, 0.46, 0.40) * (0.84 + 0.30 * trMicro), aRock * 0.68);
		alpinePath = mix(alpinePath, vec3(0.58, 0.54, 0.47), pebbles * 0.64);
		alpinePath = mix(alpinePath, vec3(0.24, 0.16, 0.09), fRoot * 0.42);
		alpinePath = mix(alpinePath, vec3(0.095, 0.24, 0.055), aMoss * 0.84);
		alpinePath *= 1.0 - rut * 0.90;
		tcol = mix(tcol, alpinePath, smoothstep(195.0, 320.0, h) * 0.92);
	}
	tcol *= mix(0.62, 1.04, smoothstep(0.49, 0.62, trailEdge2));
	float vergeLip = smoothstep(0.32, 0.48, trailEdge2) * (1.0 - twTrail);
	col = mix(col, col * 0.60 + vec3(0.018, 0.022, 0.008), vergeLip * 0.76);
	col = mix(col, tcol, twTrail);

	// stream bed
	{
		vec4 pbLarge = texture(noise_tex, xz * 0.95 + 0.17);
		vec4 pbMed = texture(noise_tex, xz * 2.6 + 0.51);
		vec4 pbFine = texture(noise_tex, xz * 6.4 + 0.83);
		float cobble = smoothstep(0.44, 0.64, pbLarge.a);
		float peb = smoothstep(0.46, 0.66, pbMed.a);
		vec3 cWarm = vec3(0.55, 0.48, 0.38);
		vec3 gravel = mix(vec3(0.28, 0.26, 0.22), mix(vec3(0.38, 0.40, 0.42), cWarm, pbLarge.g), cobble);
		gravel = mix(gravel, mix(cWarm, vec3(0.62, 0.50, 0.34), pbMed.r), peb * 0.65);
		gravel *= 0.82 + 0.34 * pbFine.b;
		float bankMoss = smoothstep(0.58, 0.22, bed) * smoothstep(0.32, 0.68, pbLarge.r);
		gravel = mix(gravel, vec3(0.12, 0.32, 0.08), bankMoss * 0.75);
		gravel = mix(gravel, vec3(0.10, 0.28, 0.34), smoothstep(140.0, 520.0, dist) * 0.75);
		col = mix(col, gravel * 0.85, smoothstep(0.18, 0.48, bed));
		t_wet = max(t_wet, smoothstep(0.25, 0.55, bed) * 0.85);
	}

	col *= 0.93 + 0.14 * nH.a;

	// painted far mountains
	{
		float farZ = smoothstep(1150.0, 2250.0, dist);
		if (farZ > 0.0) {
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
			float snSlope = smoothstep(0.38, 0.34, sB + edgeJ) * smoothstep(sl - 18.0, sl + 18.0, h);
			float snHighCap = smoothstep(0.50, 0.46, sB + edgeJ) * smoothstep(sl + 230.0, sl + 265.0, h);
			float snLedge = strataFlat * smoothstep(0.45, 0.36, sB) * smoothstep(sl + 20.0, sl + 80.0, h) * 0.75;
			float sn = smoothstep(0.35, 0.55, max(max(snSlope, snHighCap), snLedge));
			vec3 snowFarCol = mix(vec3(0.88, 0.93, 1.0), vec3(0.995, 0.998, 1.0), smoothstep(sl + 60.0, sl + 360.0, h));
			zc = mix(zc, snowFarCol, sn);
			t_snow_far = sn * farZ;
			col = mix(col, zc, farZ);
		}
	}

	// normal detail: near bump, mid-range rock bump, cliff shelves
	vec2 gd = vec2(nf.g - texture(noise_tex, xz * 0.63 + vec2(0.002, 0.0)).g,
			nf.g - texture(noise_tex, xz * 0.63 + vec2(0.0, 0.002)).g);
	float bump = mix(0.35, 1.8, max(rockW, bed * 0.6)) * fadeF;
	vec2 gdm = vec2(nm.r - texture(noise_tex, xz * 0.013 + vec2(0.002, 0.0)).r,
			nm.r - texture(noise_tex, xz * 0.013 + vec2(0.0, 0.002)).r);
	n = normalize(n + vec3(gd.x, 0.0, gd.y) * bump + vec3(gdm.x, 0.0, gdm.y) * 1.4 * rockW * fadeM * (1.0 - fb) + cliffNAdd);

	// ---- material colour (Stillwater color_fragment) ----
	vec3 albedo = col;
	float depthW = water_level - wp.y;
	if (depthW > 0.0) {
		vec2 cp = wp.xz * 0.35;
		float c1 = texture(noise_tex, cp * 0.11 + TIME * 0.012).a;
		float c2 = texture(noise_tex, cp * 0.13 - TIME * 0.010 + 0.5).a;
		float caust = pow(clamp(1.0 - abs(c1 - c2) * 3.5, 0.0, 1.0), 5.0);
		albedo *= exp(-depthW * vec3(0.32, 0.09, 0.07));
		albedo += vec3(0.65, 0.98, 1.0) * caust * 0.42 * exp(-depthW * 0.24) * max(sun_dir.y, 0.0);
	}
	albedo *= mix(1.0, 0.56, t_wet);
	if (ao_spot.z > 0.0) {
		float dA = length(wp.xz - ao_spot.xy);
		albedo *= 1.0 - ao_spot.w * (1.0 - smoothstep(ao_spot.z * 0.75, ao_spot.z * 1.35, dA));
	}

	// ---- lighting (patch.js RE_Direct_Toon with toonWrap 0.14, lo 0.24, hi 0.40) ----
	float sun_vis = w_cloud_shadow(wp, cam);
	float w = (dot(n, sun_dir) + 0.14) / 1.14;
	float ramp_near = smoothstep(0.24, 0.40, w);
	float ramp_far = smoothstep(0.06, 0.13, w) * 0.38 + smoothstep(0.36, 0.44, w) * 0.62;
	float ramp = mix(ramp_near, ramp_far, smoothstep(1150.0, 2300.0, dist));
	vec3 direct = ramp * light_col * sun_vis * albedo / PI;
	vec3 ind = mix(hemi_ground, hemi_sky, n.y * 0.5 + 0.5) * albedo;
	ind = max(mix(vec3(w_luma(ind)), ind, 1.28), 0.0) * vec3(0.95, 1.00, 1.15) * 1.07;

	// ---- emissive extras ----
	vec3 emis = vec3(0.0);
	{
		float trM = smoothstep(0.35, 0.60, trail);
		float openPath = 1.0 - smoothstep(0.32, 0.68, bio.r) * 0.85;
		emis += vec3(0.12, 0.08, 0.035) * trM * openPath * smoothstep(0.08, 0.24, sun_dir.y);
	}
	{
		float cotClear = ao_spot.z > 0.1 ? smoothstep(26.0, 48.0, length(wp.xz - ao_spot.xy)) : 1.0;
		float fz = smoothstep(0.46, 0.82, bio.r) * cotClear * (1.0 - fb);
		if (fz > 0.0) {
			float sunH = smoothstep(0.05, 0.22, sun_dir.y);
			vec2 sunProj = wp.xz - sun_dir.xz / max(sun_dir.y, 0.25) * 6.0;
			vec2 dp1 = sunProj * 0.028 + wind_dir * sin(TIME * 0.28) * 0.02;
			vec2 dp2 = mat2(vec2(0.8, -0.6), vec2(0.6, 0.8)) * sunProj * 0.064;
			float n1 = texture(noise_tex, dp1).r;
			float n2 = texture(noise_tex, dp2 + 0.31).g;
			float pool = smoothstep(0.50, 0.70, n1 * 0.60 + n2 * 0.40);
			float midGlade = smoothstep(14.0, 26.0, dist) * (1.0 - smoothstep(38.0, 58.0, dist));
			float gladePool = max(pool * 0.95, midGlade * smoothstep(0.24, 0.58, n1 * 0.65 + n2 * 0.35) * 1.35);
			float trailBoost = 1.0 + 0.38 * smoothstep(0.12, 0.55, trail);
			emis += albedo * light_col * vec3(1.18, 0.98, 0.52) * gladePool * fz * 0.96 * trailBoost * sunH;
		}
	}
	{
		vec3 Vw = normalize(cam - wp);
		float highPeakOnly = smoothstep(1050.0, 1620.0, wp.y) * smoothstep(1400.0, 3400.0, dist);
		if (highPeakOnly > 0.0) {
			float rim = pow(1.0 - max(dot(n, Vw), 0.0), 2.8) * highPeakOnly;
			float sunSide = smoothstep(0.02, 0.58, dot(n, sun_dir));
			emis += light_col * vec3(1.0, 0.95, 0.86) * rim * sunSide * 0.08 * sun_vis * smoothstep(0.0, 0.12, sun_dir.y);
		}
	}

	vec3 lit = direct + ind + emis;
	vec3 atm_mul;
	vec3 atm_add;
	w_atmosphere(wp, cam, atm_mul, atm_add);
	lit = lit * atm_mul + atm_add;
	ALBEDO = w_grade(lit, SCREEN_UV, VIEWPORT_SIZE);
}
