// Stillwater's light environment at hour 16 shared by terrain and trees: hemisphere fill, cloud
// shadow, analytic aerial perspective (src/glsl/common.js w_cloudShadow, w_atmosphere) and the
// indirect tint of src/patch.js. Needs stillwater.gdshaderinc first.

uniform float water_level = 22.0;
uniform vec3 hemi_sky = vec3(0.41, 0.58, 0.94);
uniform vec3 hemi_ground = vec3(0.34, 0.35, 0.56);
// Painterly ambient and light floor; set from environment.gd so a time of day can drive them.
uniform vec3 shadow_ambient_tint = vec3(0.92, 0.92, 1.20);
uniform float ambient_boost = 1.12;
uniform vec3 light_floor_col = vec3(0.42, 0.50, 0.72);
uniform float light_floor = 0.45;
uniform vec3 fog_beta = vec3(2.4e-5, 4.6e-5, 1.18e-4);
uniform float fog_falloff = 0.00086957;
uniform float mist = 0.028;
uniform float cloud_cover = 0.329;
uniform vec2 cloud_offset = vec2(-223.16, -143.45);
uniform vec2 wind_dir = vec2(0.8253, 0.5646);

// Light floor: lit surfaces never drop below a cool share of their albedo, so foliage and ground
// keep their colour in deep shade and at low sun.
vec3 w_light_floor(vec3 lit, vec3 albedo) {
	if (painterly < 0.5 || DBG(DBG_NO_FLOOR)) {
		return lit;
	}
	vec3 floor_alb = mix(albedo, vec3(w_luma(albedo)), 0.30);
	return max(lit, floor_alb * light_floor_col * light_floor);
}

// Indirect hemisphere fill with cool blue-violet shadows and explicit light floor in painterly mode.
vec3 w_indirect(vec3 n, vec3 albedo) {
	if (painterly > 0.5 && !DBG(DBG_CLASSIC_IND)) {
		float sky_k = smoothstep(-0.35, 0.85, n.y);
		vec3 hemi = mix(hemi_ground, hemi_sky, sky_k);
		vec3 soft_alb = mix(albedo, vec3(w_luma(albedo)), 0.18 * (1.0 - sky_k));
		vec3 ind = hemi * soft_alb;
		ind = max(mix(vec3(w_luma(ind)), ind, 1.18), 0.0) * shadow_ambient_tint * ambient_boost;
		return w_light_floor(ind, albedo);
	}
	vec3 ind = mix(hemi_ground, hemi_sky, n.y * 0.5 + 0.5) * albedo;
	return max(mix(vec3(w_luma(ind)), ind, 1.28), 0.0) * vec3(0.95, 1.00, 1.15) * 1.07;
}

// patch.js RE_Direct_Toon diffuse ramp for a material's (wrap, lo, hi); dist is camera distance.
float w_toon_ramp(float ndl, float wrap, float lo, float hi, float dist) {
	if (painterly > 0.5 && !DBG(DBG_CLASSIC_RAMP)) {
		float wp = wrap + 0.14;
		float w = (ndl + wp) / (1.0 + wp);
		float ramp_near = smoothstep(max(0.0, lo - 0.05), min(1.0, hi + 0.10), w);
		float ramp_far = smoothstep(0.04, 0.18, w) * 0.40 + smoothstep(0.34, 0.50, w) * 0.60;
		return mix(ramp_near, ramp_far, smoothstep(1150.0, 2300.0, dist));
	}
	float w = (ndl + wrap) / (1.0 + wrap);
	float ramp_near = smoothstep(lo, hi, w);
	float ramp_far = smoothstep(0.06, 0.13, w) * 0.38 + smoothstep(0.36, 0.44, w) * 0.62;
	return mix(ramp_near, ramp_far, smoothstep(1150.0, 2300.0, dist));
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

// Vertex-shader variant of w_cloud_shadow using explicit LOD 0 (WebGL2 forbids implicit texture() in vertex).
float w_cloud_shadow_v(vec3 wp, vec3 cam) {
	vec3 L = sun_dir;
	vec2 xz = wp.xz + L.xz / max(L.y, 0.12) * (2600.0 - wp.y);
	vec2 p = (xz + cloud_offset) * 0.000048;
	vec4 a = textureLod(noise_tex, p, 0.0);
	vec4 b = textureLod(noise_tex, p * 2.2 + a.xy * 0.12 + 0.37, 0.0);
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

	if (painterly > 0.5) {
		// Sky-matched horizon fog: uses the exact shared w_horizon_color(dir) as sky.gdshader
		// so distant slopes and the map edge melt into the sky without a seam.
		vec3 hor_col = w_horizon_color(dir);
		vec3 airy_col = hor_col * vec3(0.95, 0.96, 1.06);
		vec3 mist_col = mix(hor_col, hor_col * vec3(0.94, 0.97, 1.08), 0.45);

		atm_mul = ext * extm;
		atm_add = (hor_col * (1.0 - ext)) * extm + mist_col * (1.0 - extm);

		if (dist > 1450.0) {
			float high_look = smoothstep(200.0, 380.0, cam.y) * w_rstep(0.05, -0.18, dir.y);
			float low_basin = exp(-max(wp.y - water_level - 18.0, 0.0) / 260.0);
			float peak_crisp = 1.0 - 0.38 * smoothstep(520.0, 1450.0, wp.y);
			float a1 = clamp(smoothstep(1450.0, 3800.0, dist) * (0.10 + 0.30 * low_basin) * peak_crisp * (1.0 - 0.56 * high_look), 0.0, 0.40);
			atm_mul *= 1.0 - a1;
			atm_add = atm_add * (1.0 - a1) + airy_col * a1;
			float a2 = clamp(smoothstep(3600.0, 8200.0, dist) * (0.18 + 0.18 * low_basin) * peak_crisp, 0.0, 0.42);
			vec3 far_col = mix(airy_col, hor_col, smoothstep(4500.0, 10500.0, dist));
			atm_mul *= 1.0 - a2;
			atm_add = atm_add * (1.0 - a2) + far_col * a2;
			// Smoothly dissolve the far horizon and far-map rim completely into the exact sky colour.
			float map_edge = max(abs(wp.x), abs(wp.z));
			float hor_fade = max(smoothstep(8500.0, 15200.0, dist), smoothstep(13600.0, 16000.0, map_edge));
			hor_fade = clamp(hor_fade * hor_fade * (3.0 - 2.0 * hor_fade), 0.0, 1.0);
			atm_mul *= 1.0 - hor_fade;
			atm_add = mix(atm_add, hor_col, hor_fade);
		}
		atm_mul = clamp(w_denan(atm_mul, vec3(1.0)), vec3(0.0), vec3(1.0));
		atm_add = clamp(w_denan(atm_add, vec3(0.0)), vec3(0.0), vec3(40.0));
		return;
	}

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
		float high_look = smoothstep(200.0, 380.0, cam.y) * w_rstep(0.05, -0.18, dir.y);
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

