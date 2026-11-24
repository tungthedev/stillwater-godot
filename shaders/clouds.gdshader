// Stillwater's cumulus puffs (src/world/clouds.js) at hour 16: noise-inflated icosphere puffs with
// a flattened condensation base and a cluster dome normal; daytime shading only (the golden-hour,
// dawn, dusk and night weights are 0 at hour 16). See systems/clouds.gd for the instance layout.
shader_type spatial;
render_mode unshaded, fog_disabled, cull_back, depth_draw_opaque, skip_vertex_transform;

#include "res://shaders/stillwater.gdshaderinc"

// Painterly cloud palette, set from environment.gd so a time of day can drive it.
uniform vec3 cloud_lit_col = vec3(2.55, 2.38, 2.15);
uniform vec3 cloud_shadow_col = vec3(0.62, 0.78, 1.32);
uniform vec3 cloud_rim_col = vec3(3.10, 2.65, 1.95);

varying vec3 v_n;
varying vec3 v_w;
varying float v_h;
varying float v_seed;
varying vec2 v_local;
varying vec2 v_uv_n;
varying vec3 v_hor;
varying float v_haze;

void vertex() {
	vec4 cl = INSTANCE_CUSTOM;
	float seed = MODEL_MATRIX[0].y;
	float r0 = MODEL_MATRIX[1].y;
	if (painterly > 0.5) {
		vec3 center = MODEL_MATRIX[3].xyz;
		vec3 cam = CAMERA_POSITION_WORLD;
		vec3 to_cam = normalize(cam - center);
		vec3 right = normalize(cross(vec3(0.0, 1.0, 0.0), to_cam) + vec3(1e-5, 0.0, 0.0));
		vec3 upv = cross(to_cam, right);
		// Tiny per-puff offset along view ray prevents coplanar billboard z-fighting.
		vec3 wp = center + (right * VERTEX.x + upv * VERTEX.y) * (r0 * 1.12) + to_cam * (fract(seed * 3.17) * 4.0);
		float base = cl.w;
		float soft_base = base + sin(seed * 17.3) * 14.0;
		if (wp.y < soft_base) {
			wp.y = soft_base - (soft_base - wp.y) * 0.14;
		}
		vec3 cc = vec3(cl.x, base + (cl.y - base) * 0.30, cl.z);
		vec3 dc = (wp - cc) * vec3(1.0, 1.45, 1.0);
		vec3 cn = length(dc) > 1e-3 ? normalize(dc) : vec3(0.0, 1.0, 0.0);
		float under_b = smoothstep(soft_base + r0 * 0.38, soft_base - r0 * 0.06, wp.y);
		v_n = normalize(mix(cn, vec3(0.0, -1.0, 0.0), under_b * 0.45));
		v_w = wp;
		v_h = clamp((wp.y - base) / max(cl.y - base + r0 * 0.55, 1.0), 0.0, 1.0);
		v_seed = seed;
		v_local = VERTEX.xy;
		v_uv_n = VERTEX.xy * 0.36 + vec2(seed * 0.137, seed * 0.293);
		vec3 vdir = normalize(wp - cam);
		v_hor = w_horizon_color(vdir);
		float dist = length(wp - cam);
		v_haze = (1.0 - exp(-dist * 2.4e-5)) * 0.52;
		POSITION = PROJECTION_MATRIX * (VIEW_MATRIX * vec4(wp, 1.0));
	} else {
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
		v_local = vec2(0.0);
		v_uv_n = vec2(0.0);
		v_hor = vec3(0.0);
		v_haze = 0.0;
		POSITION = PROJECTION_MATRIX * (VIEW_MATRIX * vec4(wp, 1.0));
	}
}

void fragment() {
	if (painterly > 0.5) {
		float en = texture(noise_tex, v_uv_n).a;
		float r = length(v_local) + (en - 0.5) * 0.24;
		if (r > 0.86) {
			discard;
		}
		vec3 N = normalize(v_n);
		vec3 L = sun_dir;
		vec3 view_dir = normalize(v_w - CAMERA_POSITION_WORLD);
		vec3 V = -view_dir;
		float ndl = dot(N, L);
		float dome_lit = smoothstep(-0.30, 0.52, ndl);
		float grad = clamp(mix(v_h, dome_lit * 0.62 + v_h * 0.38, 0.56) + (en - 0.5) * 0.07, 0.0, 1.0);
		grad = smoothstep(0.06, 0.90, grad);
		vec3 col = mix(cloud_shadow_col, cloud_lit_col, grad);
		// Cluster-dome rim (not per-puff disc edge) so overlapping puffs fuse into one painted volume.
		float dome_rim = pow(1.0 - max(dot(N, V), 0.0), 1.7);
		float sun_side = smoothstep(-0.15, 0.62, ndl);
		float fw = pow(max(dot(view_dir, L), 0.0), 3.0);
		float rim_k = dome_rim * (0.24 * sun_side + 0.52 * fw) * (0.28 + 0.72 * v_h);
		col = mix(col, cloud_rim_col, clamp(rim_k, 0.0, 0.65));
		col *= mix(0.92, 1.05, v_h);
		col = mix(col, v_hor, v_haze);
		ALBEDO = w_grade(col, SCREEN_UV, VIEWPORT_SIZE);
	} else {
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
}
