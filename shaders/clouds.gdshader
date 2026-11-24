// Stillwater's cumulus puffs (src/world/clouds.js) at hour 16: noise-inflated icosphere puffs with
// a flattened condensation base and a cluster dome normal; daytime shading only (the golden-hour,
// dawn, dusk and night weights are 0 at hour 16). See systems/clouds.gd for the instance layout.
shader_type spatial;
render_mode unshaded, fog_disabled, cull_back, depth_draw_opaque, skip_vertex_transform;

#include "res://shaders/stillwater.gdshaderinc"

varying vec3 v_n;
varying vec3 v_w;
varying float v_h;
varying float v_seed;

void vertex() {
	vec4 cl = INSTANCE_CUSTOM;
	float seed = MODEL_MATRIX[0].y;
	float r0 = MODEL_MATRIX[1].y;
	vec3 n = normalize(VERTEX);
	float b = textureLod(noise_tex, n.xz * 0.34 + n.y * 0.22 + seed, 0.0).a;
	float b2 = textureLod(noise_tex, n.xy * 0.70 + seed * 1.7, 0.0).b;
	float r = r0 * (0.92 + 0.16 * b + 0.05 * b2);
	vec3 wp = MODEL_MATRIX[3].xyz + n * r;
	float base = cl.w;
	float soft_base = base + (b - 0.5) * 26.0;
	float under_b = smoothstep(soft_base + r0 * 0.42, soft_base - r0 * 0.08, wp.y);
	if (wp.y < soft_base) {
		wp.y = soft_base - (soft_base - wp.y) * 0.12;
	}
	vec3 cc = vec3(cl.x, base + (cl.y - base) * 0.30, cl.z);
	vec3 cn = normalize((wp - cc) * vec3(1.0, 1.45, 1.0));
	v_n = normalize(mix(mix(n, cn, 0.80), vec3(0.0, -1.0, 0.0), under_b * 0.58));
	v_w = wp;
	v_h = clamp((wp.y - base) / max(cl.y - base + r0 * 0.65, 1.0), 0.0, 1.0);
	v_seed = seed;
	POSITION = PROJECTION_MATRIX * (VIEW_MATRIX * vec4(wp, 1.0));
}

void fragment() {
	vec3 N = normalize(v_n);
	vec3 cam = CAMERA_POSITION_WORLD;
	vec3 V = normalize(cam - v_w);
	vec3 L = sun_dir;
	float ndl = dot(N, L);
	float lit = smoothstep(-0.18, 0.38, ndl) * 0.76 + smoothstep(-0.45, 0.72, ndl) * 0.24;
	lit = clamp(lit * (0.52 + 0.54 * v_h), 0.0, 1.0);
	vec3 zen = w_sky(vec3(0.0, 1.0, 0.0));
	vec3 view_dir = normalize(v_w - cam);
	vec3 sky_here = w_sky(vec3(view_dir.x, max(view_dir.y, 0.02), view_dir.z));
	vec3 hor = w_sky(normalize(vec3(view_dir.x, 0.08, view_dir.z)));
	float sun_i = max(max(light_col.r, light_col.g), light_col.b);
	vec3 sun_c = light_col / max(sun_i, 1e-4);
	vec3 shadow_col = mix(zen, hor, 0.36) * vec3(0.76, 0.87, 1.15) * 1.32 + vec3(0.015, 0.025, 0.055);
	vec3 lit_col = sun_c * min(sun_i, 10.0) * 0.35 + zen * 0.45 + vec3(0.055, 0.052, 0.044);
	vec3 col = mix(shadow_col, lit_col, lit);
	float fw = pow(max(dot(view_dir, L), 0.0), 3.0);
	float rim = pow(1.0 - max(dot(N, V), 0.0), 1.6);
	col += sun_c * min(sun_i, 8.5) * rim * (0.10 + fw * 0.75) * 0.32;
	col += sun_c * min(sun_i, 8.0) * 0.04 * pow(max(dot(N, L), 0.0), 2.0);
	float en = texture(noise_tex, v_w.xz * 0.0008 + v_w.y * 0.0005 + v_seed).a;
	col *= 0.96 + 0.07 * en;
	float dist = length(v_w - cam);
	float haze = 1.0 - exp(-dist * 2.4e-5);
	col = mix(col, hor * 1.04, haze * 0.56);
	col *= mix(0.86, 1.06, v_h);
	float rim_soft = smoothstep(-0.04, 0.14, dot(N, V));
	col = mix(sky_here, col, mix(0.65, 1.0, rim_soft));
	ALBEDO = w_grade(col, SCREEN_UV, VIEWPORT_SIZE);
}
