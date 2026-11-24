// Stillwater's sky dome (src/world/sky.js) at hour 16: the sky-view LUT read back from the game,
// its saturation and pale-horizon styling, the sun disc and glow, cirrus wisps, and the painted
// cumulus layer (replacing the 556 discard billboards unless ?clouds=billboard is set). Stars,
// moon and the golden-hour / dusk terms have zero weight at hour 16. Graded like the terrain (see
// stillwater.gdshaderinc).
shader_type sky;

#include "res://shaders/stillwater.gdshaderinc"

// SCREEN_UV is not usable in sky shaders on this renderer, so the vignette's screen position is
// found by projecting EYEDIR with the camera basis (set by systems/environment.gd when post is off).
uniform vec2 view_size;
uniform vec3 cam_right;
uniform vec3 cam_up;
uniform vec3 cam_fwd;
uniform float tan_half_fov;
uniform vec2 cloud_offset;
uniform vec2 wind_dir;
uniform float cloud_cover = 0.329;
uniform float cirrus_on = 1.0;
uniform float sky_clouds_on = 1.0;
uniform vec3 cloud_lit_col = vec3(2.55, 2.38, 2.15);
uniform vec3 cloud_shadow_col = vec3(0.62, 0.78, 1.32);
uniform vec3 cloud_rim_col = vec3(3.10, 2.65, 1.95);

// sky.js cirrus(): a wind-aligned noise layer at 12 km, daytime colour only.
vec4 cirrus(vec3 dir, vec3 cam) {
	if (dir.y <= 0.06) return vec4(0.0);
	float t = (12000.0 - cam.y) / max(dir.y, 0.07);
	vec2 xz = cam.xz + dir.xz * t + cloud_offset * 1.6;
	vec2 wdir = normalize(wind_dir + 1e-4);
	vec2 wperp = vec2(-wdir.y, wdir.x);
	vec2 uv = vec2(dot(xz, wdir) * 0.000016, dot(xz, wperp) * 0.000046);
	vec4 n1 = texture(noise_tex, uv);
	vec2 warp = vec2(n1.r - 0.5, n1.g - 0.5) * 0.38;
	float wisp = texture(noise_tex, uv * vec2(1.1, 1.9) + warp).g * 0.58
			+ texture(noise_tex, uv * vec2(2.6, 4.4) + warp * 1.4 + 0.31).b * 0.42;
	float macro = smoothstep(0.38, 0.72, n1.r);
	float a = smoothstep(0.50, 0.76, wisp) * macro * 0.22 * smoothstep(0.06, 0.26, dir.y) * (1.0 - smoothstep(0.76, 0.98, dir.y) * 0.42);
	if (a < 0.004) return vec4(0.0);
	float mu = dot(normalize(dir), sun_dir);
	vec3 c = w_sky(vec3(0.0, 1.0, 0.0)) * 0.75 + light_col * (0.28 + pow(max(mu, 0.0), 5.0) * 0.75);
	return vec4(c, a);
}

// Painted cumulus layer in the sky shader: 2 noise_tex fetches on the shared w_cloud_shadow field
// projected onto a curved 2600 m dome, sculpted with Worley puffs and a crisp 3-band gouache ramp.
// Drawn on sky pixels only (opaque, zero discard) so Apple TBDR HSR stays unbroken.
vec4 cumulus(vec3 dir) {
	if (dir.y <= 0.015) return vec4(0.0);
	// Curved dome (R = 65 km, H = 2600 m): matches w_cloud_shadow's 2600 m plane overhead while
	// staying finite (~18.5 km) near the horizon without stretching.
	const float R = 65000.0;
	const float H = 2600.0;
	float ry = R * dir.y;
	float t = sqrt(ry * ry + 2.0 * R * H + H * H) - ry;
	vec2 xz = dir.xz * t;
	vec2 p = (xz + cloud_offset) * 0.000048;

	// Two fetches: primary cloud field (w_cloud_shadow macro weights sculpted by Worley lobes in
	// ch a), plus a sun-and-zenith shifted fetch for crisp directional self-shadowing.
	vec4 a = texture(noise_tex, p);
	vec2 sun_xz = sun_dir.xz * inversesqrt(max(dot(sun_dir.xz, sun_dir.xz), 1e-8));
	vec2 rad_xz = dir.xz * inversesqrt(max(dot(dir.xz, dir.xz), 1e-8));
	vec2 shift = (sun_xz * 0.022 - rad_xz * 0.014) * mix(1.0, 0.45, smoothstep(0.08, 0.55, dir.y));
	vec4 s = texture(noise_tex, p + shift);

	float macro = a.r * 0.70 + a.g * 0.20 + a.b * 0.10;
	float field = macro * 0.58 + a.a * 0.42;

	float thresh = 1.0 - cloud_cover - 0.068;
	// Crisp gouache silhouette edge, softening slightly right at the horizon to avoid shimmer.
	float edge_w = mix(0.018, 0.007, smoothstep(0.04, 0.22, dir.y));
	float cov = smoothstep(thresh, thresh + edge_w, field);
	float hor_fade = smoothstep(0.015, 0.09, dir.y);
	float alpha = cov * hor_fade;
	if (alpha < 0.004) return vec4(0.0);

	float s_macro = s.r * 0.70 + s.g * 0.20 + s.b * 0.10;
	float s_field = s_macro * 0.58 + s.a * 0.42;
	float thick = smoothstep(thresh, thresh + 0.16, field);
	float sun_slope = (field - s_field) * 9.0;
	float shade_val = clamp(0.42 + sun_slope * 0.58 + (thick - 0.35) * 0.42 + (a.a - 0.56) * 0.55, 0.0, 1.0);

	// 3-band painted cumulus ramp matching the painterly billboards (lavender base / mid / cream crown).
	float b_mid = smoothstep(0.26, 0.42, shade_val);
	float b_lit = smoothstep(0.52, 0.68, shade_val);
	vec3 lit_c = painterly > 0.5 ? cloud_lit_col : vec3(2.45, 2.38, 2.25);
	vec3 shd_c = painterly > 0.5 ? cloud_shadow_col : vec3(0.68, 0.80, 1.18);
	vec3 rim_c = painterly > 0.5 ? cloud_rim_col : vec3(2.85, 2.55, 2.05);
	vec3 mid_c = mix(shd_c, lit_c, 0.58);
	vec3 col = mix(mix(shd_c, mid_c, b_mid), lit_c, b_lit);

	// Warm sunlit rim on thin sun-facing edges and forward scatter near the sun.
	float edge_band = 1.0 - smoothstep(0.02, 0.42, thick);
	float fw = pow(max(dot(dir, sun_dir), 0.0), 3.0);
	float rim_k = edge_band * (0.30 * b_lit + 0.55 * fw) + (1.0 - edge_band) * fw * 0.16 * b_lit;
	col = mix(col, rim_c, clamp(rim_k, 0.0, 0.65));
	col *= mix(0.94, 1.05, thick);

	// Gentle horizon haze at low elevation; keep overhead clouds crisp and luminous.
	float haze = (1.0 - exp(-t * 2.4e-5)) * mix(0.50, 0.16, smoothstep(0.05, 0.28, dir.y));
	col = mix(col, w_horizon_color(dir), haze);
	return vec4(col, alpha);
}

void sky() {
	vec3 dir = EYEDIR;
	vec3 col = w_sky_base(dir);
	float mu = dot(dir, sun_dir);
	float sun_r = 0.02;
	float sd = acos(clamp(mu, -1.0, 1.0));
	if (sd < sun_r * 2.2) {
		float x = clamp(sd / sun_r, 0.0, 1.0);
		float limb = 1.0 - 0.55 * (1.0 - sqrt(1.0 - x * x));
		float disc = w_rstep(1.18, 0.72, sd / sun_r);
		col += sun_col * disc * limb * 24.0;
	}
	col += sun_col * pow(max(mu, 0.0), 140.0) * 0.78 + sun_col * pow(max(mu, 0.0), 28.0) * 0.24 * 0.45;
	if (cirrus_on > 0.5) {
		vec4 ci = cirrus(dir, POSITION);
		col = mix(col, ci.rgb, ci.a);
	}
	if (sky_clouds_on > 0.5) {
		vec4 cu = cumulus(dir);
		col = mix(col, cu.rgb, cu.a);
	}
	col = clamp(w_denan(col, vec3(0.0)), vec3(0.0), vec3(200.0));
	float fz = max(dot(dir, cam_fwd), 1e-3);
	float aspect = view_size.x / max(view_size.y, 1.0);
	vec2 ndc = vec2(dot(dir, cam_right) / (fz * tan_half_fov * aspect), dot(dir, cam_up) / (fz * tan_half_fov));
	COLOR = w_grade(col, ndc * 0.5 + 0.5, view_size);
}
