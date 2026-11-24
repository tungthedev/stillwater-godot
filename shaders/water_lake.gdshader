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

	// Two rotated, incommensurate mipmapped noise taps: n1 drives broad swells and far-lake
	// variety; n2 is anisotropically stretched across the wind so close-up ripples read as crisp
	// horizontal painted wave strokes rather than round blobs.
	float t = TIME;
	vec2 wd = wind_dir;
	const mat2 R_RIP = mat2(vec2(0.80, -0.60), vec2(0.60, 0.80));
	vec4 n1 = texture(noise_tex, p * 0.016 + wd * t * 0.007);
	vec2 p_rip = (R_RIP * p) * vec2(0.062, 0.165) + (n1.rg - 0.5) * 0.12;
	vec4 n2 = texture(noise_tex, p_rip - vec2(0.0, t * 0.028) + vec2(0.37, 0.61));

	// Simplified animated ripples: lively fine wavelets near the shore, calm at far lake distances.
	float near_k = mix(1.0, 0.30, smoothstep(65.0, 620.0, dist));
	float near_detail = w_rstep(125.0, 12.0, dist);
	vec2 slp = ((n1.gb - 0.5) * 0.18 + (n2.gb - 0.5) * (0.20 + 0.18 * near_detail)) * near_k;
	vec3 N = w_normalize(vec3(-slp.x, 1.0, -slp.y));

	// Depth-graded painterly water body: luminous turquoise shallows -> alpine teal -> deep sapphire.
	// Slight low-frequency depth wobble keeps depth bands looking hand-painted instead of clinical.
	float depth_paint = max(depth + (n1.r - 0.5) * 0.24, 0.0);
	float shallow_k = exp(-depth_paint * 0.65);
	float mid_k = exp(-depth_paint * 0.19);
	vec3 col_shallow = vec3(0.062, 0.435, 0.435);
	vec3 col_mid     = vec3(0.022, 0.230, 0.385);
	vec3 col_deep    = vec3(0.010, 0.095, 0.255);
	vec3 body_tint = mix(col_deep, col_mid, smoothstep(0.08, 0.88, mid_k));
	body_tint = mix(body_tint, col_shallow, smoothstep(0.12, 0.86, shallow_k));

	// Crisp two-tone painted ripple troughs visible right up to the shoreline.
	float shallow_vis = smoothstep(0.03, 0.18, depth);
	float trough_src = n2.g * 0.60 + n1.b * 0.40;
	float trough_fw = clamp(fwidth(trough_src) * 1.1, 0.015, 0.12);
	float trough = w_rstep(0.45 + trough_fw, max(0.45 - trough_fw, 0.01), trough_src) * shallow_vis * w_rstep(260.0, 30.0, dist);
	body_tint *= mix(1.0, 0.82, trough);

	// Soft painterly lighting aligned with S1 (cool ambient + direct sun + explicit light floor).
	float sun_up = clamp(sun_dir.y * 3.0, 0.0, 1.0);
	vec3 amb = w_sky(vec3(0.0, 1.0, 0.0));
	vec3 amb_fill = mix(hemi_sky, amb, 0.45) * shadow_ambient_tint * ambient_boost;
	vec3 body = body_tint * (amb_fill * 1.50 + light_col * (0.09 + 0.14 * shallow_k) * sun_up * v_cloud_sh);
	body = w_light_floor(body, body_tint);

	// Crisp elongated painted ripple crests across near shallows and mid-lake (never puffy white dots).
	float crest_src = n2.b * 0.56 + n1.b * 0.26 + n2.a * 0.18;
	float crest_fw = clamp(fwidth(crest_src) * 1.1, 0.012, 0.10);
	float crest = smoothstep(0.61 - crest_fw, 0.61 + crest_fw, crest_src) * shallow_vis * w_rstep(480.0, 90.0, dist);
	float fine_stroke_src = n2.b * 0.65 + n2.g * 0.35;
	float fine_fw = clamp(fwidth(fine_stroke_src) * 1.1, 0.012, 0.10);
	float fine_stroke = smoothstep(0.68 - fine_fw, 0.68 + fine_fw, fine_stroke_src) * shallow_vis * near_detail;
	body = mix(body, body * 1.24 + amb_fill * vec3(0.05, 0.15, 0.19), clamp(crest * 0.38 + fine_stroke * 0.34, 0.0, 0.62));

	// Cheap sky-tinted Fresnel reflection (no planar reflection, no SSR), capped so deep alpine
	// sapphire stays rich even at low shoreline viewing angles.
	float cos_t = max(dot(N, V), 0.0);
	float fres = clamp(0.04 + 0.56 * pow(max(1.0 - cos_t, 0.0), 4.0), 0.0, 0.60);
	float shore_soft = smoothstep(0.04, 0.42, depth);
	fres *= mix(0.20, 1.0, shore_soft);
	vec3 R = reflect(-V, N);
	vec3 sky_refl = w_horizon_color(w_normalize(vec3(R.x, max(R.y, 0.04), R.z)));
	sky_refl = mix(sky_refl, sky_refl * vec3(0.80, 0.94, 1.08), 0.40);
	vec3 col = mix(body, sky_refl * 0.85, fres * 0.62);

	// Soft, clamped sun sheen + crisp anisotropic ripple glints (no harsh blowouts or bloom squares).
	vec3 H = w_normalize(sun_dir + V);
	float nh = max(dot(N, H), 0.0);
	float broad_sheen = pow(nh, 28.0) * 0.48;
	float crisp_glint = pow(nh, 160.0) * 2.4 * smoothstep(0.42, 0.68, n2.b);
	float near_sparkle = fine_stroke * (0.28 + 0.72 * pow(nh, 14.0)) * 0.48;
	float sheen = min(broad_sheen + crisp_glint + near_sparkle, 2.0) * sun_up * v_cloud_sh * mix(0.35, 1.0, shore_soft);
	col += light_col * vec3(1.0, 0.95, 0.84) * sheen * 0.24;

	// Crisp painted shoreline foam: stays narrow (~0.65 m) and razor-edged up close via screen-space
	// fwidth, widening gently with distance so the far-lake rim reads cleanly from across the valley.
	float band_d = mix(0.115, 0.24, smoothstep(18.0, 220.0, dist));
	float wob = ((n1.a - 0.5) * 0.42 + (n2.g - 0.5) * 0.44 + (n2.b - 0.5) * 0.24) * band_d;
	float d_wob = depth + wob;
	float fw = clamp(fwidth(d_wob) * 1.15, 0.0005, 0.05);
	float rim_hi = band_d + fw;
	float rim_lo = max(band_d - fw, 0.0002);
	float shore_band = w_rstep(rim_hi, rim_lo, d_wob);

	// Sparse broken painted foam wisps right beside the shore rim (never a detached solid band).
	float wisp_target = 0.20 + (n1.a - 0.5) * 0.06 + (n2.g - 0.5) * 0.04 + sin(t * 1.35 + n1.r * 5.0) * 0.02;
	float wisp_d = depth - wisp_target;
	float wisp_fw = clamp(fwidth(wisp_d) * 1.20, 0.0005, 0.02);
	float wisp_break = smoothstep(0.66, 0.78, n2.a * 0.55 + n2.b * 0.45);
	float lap_line = w_rstep(0.011 + wisp_fw, max(0.011 - wisp_fw, 0.0002), abs(wisp_d)) * wisp_break * w_rstep(95.0, 22.0, dist);

	float foam = clamp(max(shore_band * 0.95, lap_line * 0.72), 0.0, 0.95);
	vec3 foam_col = (amb_fill * 0.72 + light_col * 0.62 * sun_up * v_cloud_sh) * vec3(0.98, 0.99, 1.0);
	col = mix(col, foam_col, foam);

	col = col * v_atm_mul + v_atm_add;
	ALBEDO = w_grade(col, SCREEN_UV, VIEWPORT_SIZE);
}
