// Sky dome: the time-of-day analytic sky ramp from environment.gd (or Stillwater's sky-view LUT with
// its saturation and pale-horizon styling when sky_analytic < 1), the sun disc and glow, stars and
// moon at night, cirrus wisps, and an optional sky-shader cumulus layer (enabled via ?clouds=sky for
// A/B against the default cloud billboards). Graded like the terrain (see stillwater.gdshaderinc).
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
uniform float sky_clouds_on = 0.0;
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
	float mu = dot(w_normalize(dir), sun_dir);
	vec3 c = w_sky(vec3(0.0, 1.0, 0.0)) * 0.75 + light_col * (0.28 + pow(max(mu, 0.0), 5.0) * 0.75 * sun_disc_vis);
	return vec4(c, a * mix(1.0, 0.38, night_weight));
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

// Crisp painted starfield + subtle Milky Way band above the horizon (night_weight > 0).
vec3 night_stars(vec3 dir) {
	if (dir.y <= 0.03) return vec3(0.0);
	vec3 d = w_normalize(dir);
	float az = abs(d.x) + abs(d.z) > 1e-6 ? atan(d.z, d.x) : 0.0;
	float el = asin(clamp(d.y, -1.0, 1.0));
	// Two angular star grids so bright hero stars and fine dust read crisply without aliasing.
	vec2 g1 = vec2(az * 28.0, el * 28.0);
	vec2 id1 = floor(g1);
	vec2 f1 = fract(g1) - 0.5;
	float r1 = n_hash12(id1 + vec2(11.3, 7.1));
	vec2 off1 = (vec2(n_hash12(id1 + vec2(3.7, 19.1)), n_hash12(id1 + vec2(27.5, 5.3))) - 0.5) * 0.55;
	float d1 = length(f1 - off1);
	float s1 = smoothstep(0.86, 0.995, r1) * w_rstep(0.14, 0.02, d1);
	float tw1 = 0.72 + 0.28 * sin(TIME * (1.8 + r1 * 2.4) + r1 * 43.0);

	vec2 g2 = vec2(az * 58.0, el * 58.0);
	vec2 id2 = floor(g2);
	vec2 f2 = fract(g2) - 0.5;
	float r2 = n_hash12(id2 + vec2(53.1, 17.7));
	vec2 off2 = (vec2(n_hash12(id2 + vec2(9.2, 41.3)), n_hash12(id2 + vec2(61.4, 2.9))) - 0.5) * 0.50;
	float d2 = length(f2 - off2);
	float s2 = smoothstep(0.90, 0.998, r2) * w_rstep(0.12, 0.02, d2);

	vec3 star_tint = mix(vec3(0.82, 0.90, 1.0), vec3(1.0, 0.93, 0.82), n_hash12(id1 + vec2(1.9, 8.4)));
	float elev_k = smoothstep(0.05, 0.30, d.y);
	// Soft Milky Way glow band tilted across the dome.
	float mw = exp(-abs(dot(d, w_normalize(vec3(0.42, -0.58, 0.70)))) * 6.5) * elev_k;
	vec3 mw_col = vec3(0.055, 0.085, 0.175) * mw;
	return (star_tint * (s1 * tw1 * 2.4 + s2 * 1.15) * elev_k + mw_col) * night_weight;
}

void sky() {
	vec3 dir = w_normalize(EYEDIR);
	vec3 col = w_sky_base(dir);
	if (sun_disc_vis > 0.001) {
		float mu = dot(dir, sun_dir);
		float sun_r = 0.02;
		float sd = acos(clamp(mu, -1.0, 1.0));
		if (sd < sun_r * 2.2) {
			float x = clamp(sd / sun_r, 0.0, 1.0);
			float limb = 1.0 - 0.55 * (1.0 - sqrt(max(1.0 - x * x, 0.0)));
			float disc = w_rstep(1.18, 0.72, sd / sun_r);
			col += sun_col * disc * limb * 24.0 * sun_disc_vis;
		}
		col += (sun_col * pow(max(mu, 0.0), 140.0) * 0.78 + sun_col * pow(max(mu, 0.0), 28.0) * 0.24 * 0.45) * sun_disc_vis;
	}
	if (night_weight > 0.01) {
		col += night_stars(dir);
	}
	if (moon_vis > 0.01) {
		vec3 md = w_normalize(moon_dir);
		float mu_m = dot(dir, md);
		float moon_r = 0.026;
		float md_ang = acos(clamp(mu_m, -1.0, 1.0));
		if (md_ang < moon_r * 2.2) {
			float x = clamp(md_ang / moon_r, 0.0, 1.0);
			float limb = 0.78 + 0.22 * sqrt(max(1.0 - x * x, 0.0));
			float disc = w_rstep(1.12, 0.80, md_ang / moon_r);
			// Subtle painted maria mottling across the luminous silver-cream moon disc.
			float mare = 0.86 + 0.14 * sin(dir.x * 90.0 + dir.y * 65.0) * cos(dir.z * 80.0 - dir.y * 55.0);
			col += vec3(1.85, 1.92, 2.15) * disc * limb * mare * moon_vis;
		}
		float halo1 = pow(max(mu_m, 0.0), 64.0) * 0.42;
		float halo2 = pow(max(mu_m, 0.0), 10.0) * 0.16;
		col += vec3(0.55, 0.72, 1.05) * (halo1 + halo2) * moon_vis;
	}
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
