// Painterly opaque lake water (W2): depth-graded turquoise shallows -> deep alpine sapphire from
// the near heightmap (zero screen-depth reads), crisp painted shoreline foam band, animated ripples,
// cheap sky-tinted Fresnel reflection (no planar pass, no SSR), soft clamped sun sheen, and S1 fog.
// No discard and no alpha blending, so it stays at render_priority = -1 for Apple TBDR HSR.
shader_type spatial;
render_mode unshaded, fog_disabled, cull_back, depth_draw_opaque;

#include "res://shaders/stillwater.gdshaderinc"
#include "res://shaders/atmosphere.gdshaderinc"
#include "res://shaders/world.gdshaderinc"

varying vec3 v_wpos;
varying vec3 v_atm_mul;
varying vec3 v_atm_add;
varying float v_cloud_sh;

void vertex() {
	vec3 wp = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	v_wpos = wp;
	vec3 am;
	vec3 aa;
	w_atmosphere(wp, CAMERA_POSITION_WORLD, am, aa);
	v_atm_mul = am;
	v_atm_add = aa;
	v_cloud_sh = w_cloud_shadow_v(wp, CAMERA_POSITION_WORLD);
}

void fragment() {
	vec3 wp = v_wpos;
	vec2 p = wp.xz;
	float ground = w_height_near(p);
	float depth = max(water_level - ground, 0.0);

	vec3 cam = CAMERA_POSITION_WORLD;
	vec3 to_cam = cam - wp;
	float dist = length(to_cam);
	vec3 V = w_normalize(to_cam);

	// Two rotated, incommensurate noise taps break up tiling across the 600 m lake while driving
	// ripples, painted wave crests, and shoreline foam wobble.
	float t = TIME;
	vec2 wd = wind_dir;
	const mat2 R_RIP = mat2(vec2(0.80, -0.60), vec2(0.60, 0.80));
	vec4 n1 = texture(noise_tex, p * 0.015 + wd * t * 0.008);
	vec2 p_warp = R_RIP * p * 0.049 + (n1.rg - 0.5) * 0.14;
	vec4 n2 = texture(noise_tex, p_warp - wd.yx * t * 0.016 + vec2(0.37, 0.61));

	// Simplified animated ripples attenuated with distance so far lake stays calm on phone screens.
	float near_k = mix(1.0, 0.30, smoothstep(65.0, 620.0, dist));
	vec2 slp = ((n1.gb - 0.5) * 0.20 + (n2.gb - 0.5) * 0.16) * near_k;
	vec3 N = w_normalize(vec3(-slp.x, 1.0, -slp.y));

	// Depth-graded painterly water body: luminous turquoise shallows -> alpine teal -> deep sapphire.
	// Slight low-frequency depth wobble keeps depth bands looking hand-painted instead of clinical.
	float depth_paint = max(depth + (n1.r - 0.5) * 0.26, 0.0);
	float shallow_k = exp(-depth_paint * 0.65);
	float mid_k = exp(-depth_paint * 0.19);
	vec3 col_shallow = vec3(0.062, 0.435, 0.435);
	vec3 col_mid     = vec3(0.022, 0.230, 0.385);
	vec3 col_deep    = vec3(0.010, 0.095, 0.255);
	vec3 body_tint = mix(col_deep, col_mid, smoothstep(0.08, 0.88, mid_k));
	body_tint = mix(body_tint, col_shallow, smoothstep(0.12, 0.86, shallow_k));

	// Soft painterly lighting aligned with S1 (cool ambient + direct sun + explicit light floor).
	float sun_up = clamp(sun_dir.y * 3.0, 0.0, 1.0);
	vec3 amb = w_sky(vec3(0.0, 1.0, 0.0));
	vec3 amb_fill = mix(hemi_sky, amb, 0.45) * shadow_ambient_tint * ambient_boost;
	vec3 body = body_tint * (amb_fill * 1.50 + light_col * (0.09 + 0.14 * shallow_k) * sun_up * v_cloud_sh);
	body = w_light_floor(body, body_tint);

	// Subtle painted ripple crest highlights across the water surface.
	float crest_src = n1.r * 0.52 + n2.b * 0.48;
	float crest = smoothstep(0.60, 0.75, crest_src) * smoothstep(0.22, 1.25, depth) * w_rstep(480.0, 120.0, dist);
	body = mix(body, body * 1.18 + amb_fill * vec3(0.04, 0.12, 0.16), crest * 0.38);

	// Cheap sky-tinted Fresnel reflection (no planar reflection, no SSR), capped so deep alpine
	// sapphire stays rich even at low shoreline viewing angles.
	float cos_t = max(dot(N, V), 0.0);
	float fres = clamp(0.04 + 0.56 * pow(max(1.0 - cos_t, 0.0), 4.0), 0.0, 0.60);
	float shore_soft = smoothstep(0.06, 1.55, depth);
	fres *= mix(0.14, 1.0, shore_soft);
	vec3 R = reflect(-V, N);
	vec3 sky_refl = w_horizon_color(w_normalize(vec3(R.x, max(R.y, 0.04), R.z)));
	sky_refl = mix(sky_refl, sky_refl * vec3(0.80, 0.94, 1.08), 0.40);
	vec3 col = mix(body, sky_refl * 0.85, fres * 0.62);

	// Soft, clamped sun sheen (no harsh specular blowouts or bloom squares).
	vec3 H = w_normalize(sun_dir + V);
	float nh = max(dot(N, H), 0.0);
	float broad_sheen = pow(nh, 28.0) * 0.48;
	float crisp_glint = pow(nh, 180.0) * 2.2 * smoothstep(0.42, 0.68, n2.r);
	float sheen = min(broad_sheen + crisp_glint, 2.0) * sun_up * v_cloud_sh * mix(0.25, 1.0, shore_soft);
	col += light_col * vec3(1.0, 0.95, 0.84) * sheen * 0.22;

	// Crisp painted shoreline foam: hard-edged, slightly wobbly shore band + broken lapping contour.
	float wob = (n1.a - 0.5) * 0.20 + (n2.g - 0.5) * 0.09;
	float d_wob = depth + wob;
	float fw = clamp(fwidth(d_wob) * 1.15, 0.008, 0.10);
	float rim_hi = 0.25 + fw;
	float rim_lo = max(0.25 - fw, 0.001);
	float shore_band = w_rstep(rim_hi, rim_lo, d_wob);

	float lap_phase = sin(depth * 7.8 - t * 1.40 + n1.r * 3.6);
	float lap_w = clamp(fwidth(lap_phase) * 0.9, 0.04, 0.22);
	float lap_line = smoothstep(0.66 - lap_w, 0.66 + lap_w, lap_phase + (n2.a - 0.5) * 0.30);
	float lap_env = smoothstep(0.18, 0.36, depth) * w_rstep(1.10, 0.42, depth) * w_rstep(420.0, 140.0, dist);

	float foam = clamp(max(shore_band * 0.95, lap_line * lap_env * 0.82), 0.0, 0.95);
	vec3 foam_col = (amb_fill * 0.95 + light_col * 0.26 * sun_up * v_cloud_sh) * vec3(0.95, 0.98, 1.0);
	col = mix(col, foam_col, foam);

	col = col * v_atm_mul + v_atm_add;
	ALBEDO = w_grade(col, SCREEN_UV, VIEWPORT_SIZE);
}
