// Stillwater's wildflowers (src/world/grass.js FLOWER_VERTEX and its patched material) on Godot.
//
// Same tile instancing as shaders/grass.gdshader. Each flower is a camera-facing stem quad
// (CUSTOM0.w = 0) and a head quad (CUSTOM0.w = 1) whose petals are cut in the fragment shader;
// species 2 (lupine) is an upright spike. Two atlas texels per flower (shaders/flower_bake.gdshader).
//
// Lighting at hour 16, unshaded here: toon sun ramp with an up normal (Stillwater's flowers use the
// plain object normal), hemisphere fill, aerial perspective, post grade. Its specular is left out
// (roughness 0.58 scales it by 0.02, under one 8-bit step), as is the lantern spill (off by day).
shader_type spatial;
render_mode unshaded, fog_disabled, cull_disabled, depth_draw_opaque;

#include "res://shaders/stillwater.gdshaderinc"
#include "res://shaders/atmosphere.gdshaderinc"

uniform sampler2D atlas : filter_nearest;
uniform vec2 cam_xz;
uniform float tile_size = 12.0;
uniform int slot_w = 32;
uniform float radius = 22.5;
uniform float wind_strength = 0.5;

const float H_SPAN = 64.0;

varying vec3 v_wpos;
varying vec2 v_uv;
varying float v_part;
varying float v_kind;
varying float v_ao;
varying vec3 v_col;

void vertex() {
	int flips = int(INSTANCE_CUSTOM.z + 0.5);
	vec2 local = CUSTOM0.xy;
	if ((flips & 1) != 0) local.x = tile_size - local.x;
	if ((flips & 2) != 0) local.y = tile_size - local.y;
	vec2 xz = MODEL_MATRIX[3].xz + local;
	float dist = length(xz - cam_xz);
	vec4 rnd = CUSTOM1;
	float part = CUSTOM0.w;

	int rank = int(CUSTOM0.z + 0.5);
	ivec2 px = ivec2(INSTANCE_CUSTOM.xy + 0.5) + ivec2(rank % slot_w, rank / slot_w);
	vec4 b0 = floor(texelFetch(atlas, px, 0) * 255.0 + 0.5);
	float h = MODEL_MATRIX[3].y + (b0.x + b0.y * 256.0) / 65535.0 * H_SPAN;
	float dens = b0.z / 255.0;
	float kind = b0.w;
	float keep = (1.0 - smoothstep(radius * 0.62, radius, dist)) * step(rnd.w, dens * 0.94);

	v_uv = UV;
	v_part = part;
	v_kind = kind;
	if (keep <= 0.001) {
		VERTEX = vec3(local.x, h - 1.0, local.y);
		v_ao = 1.0;
		v_col = vec3(0.0);
	} else {
		float size_var = mix(0.55, 1.40, fract(rnd.y * 7.3));
		float base_h = kind < 0.5 ? mix(0.22, 0.44, rnd.y)
				: kind < 1.5 ? mix(0.16, 0.32, rnd.y)
				: kind < 2.5 ? mix(0.28, 0.54, rnd.y)
				: mix(0.20, 0.40, rnd.y);
		// Lift heads just clear of the local grass tops: wind-bent blades top out near 1.2x the baked
		// mean. Lupin spikes stand well above, campion a little, buttercup sits lowest.
		float grass_top = floor(texelFetch(atlas, px + ivec2(slot_w, 0), 0).r * 255.0 + 0.5) / 255.0 * 2.2;
		float kind_lift = kind < 0.5 ? 1.0 : kind < 1.5 ? 0.95 : kind < 2.5 ? 1.2 : 1.08;
		float clear_h = (grass_top * 1.2 + 0.05) * kind_lift * mix(0.92, 1.12, rnd.y);
		float stem_h = max(base_h, clear_h) * keep;
		float head_s = (kind < 0.5 ? 0.095 : kind < 1.5 ? 0.082 : kind < 2.5 ? 0.098 : 0.072)
				* size_var * keep * (1.0 + dist * 0.022);

		float gust = smoothstep(0.3, 0.8, textureLod(noise_tex, xz * 0.010 - wind_dir * TIME * 0.042, 0.0).r);
		vec2 sway = wind_dir * (gust * 0.6 + 0.1) * (0.3 + wind_strength) + vec2(sin(TIME * 2.3 + rnd.z * 9.0), cos(TIME * 1.9 + rnd.x * 7.0)) * 0.05;
		vec3 to_c = normalize(CAMERA_POSITION_WORLD - vec3(xz.x, h + stem_h, xz.y));
		vec3 hr = normalize(cross(vec3(0.0, 1.0, 0.0), to_c));
		vec3 p;
		if (part < 0.5) {
			float y = VERTEX.y;
			float sw = mix(0.022, 0.012, y) * keep;
			p = vec3(local.x, h + y * stem_h - 0.02, local.y) + hr * VERTEX.x * sw;
			p.xz += sway * y * y * stem_h;
		} else {
			if (kind > 1.5 && kind < 2.5) {
				p = vec3(local.x, h + stem_h * 0.88, local.y) + hr * VERTEX.x * head_s * 0.42 + vec3(0.0, 1.0, 0.0) * (VERTEX.z + 0.15) * head_s * 1.55;
			} else {
				float tilt_a = rnd.z * 6.2831;
				vec3 tilt_dir = vec3(cos(tilt_a), 0.0, sin(tilt_a));
				vec3 hn = normalize(vec3(0.0, 0.72 + 0.28 * rnd.y, 0.0) + tilt_dir * (0.36 + 0.34 * fract(rnd.x * 13.7)) + to_c * (0.16 + 0.22 * fract(rnd.z * 5.1)));
				vec3 hr3 = normalize(cross(hn, abs(hn.x) < 0.85 ? vec3(1.0, 0.0, 0.0) : vec3(0.0, 0.0, 1.0)));
				vec3 hu3 = normalize(cross(hn, hr3));
				float rot_h = rnd.x * 6.2831;
				vec3 ax1 = hr3 * cos(rot_h) + hu3 * sin(rot_h);
				vec3 ax2 = -hr3 * sin(rot_h) + hu3 * cos(rot_h);
				p = vec3(local.x, h + stem_h, local.y) + ax1 * VERTEX.x * head_s * 1.12 + ax2 * VERTEX.z * head_s * 1.12;
			}
			p.xz += sway * stem_h;
		}
		VERTEX = p;
		v_ao = mix(0.68, 1.06, smoothstep(0.14, 0.44, base_h)) * (0.86 + 0.24 * fract(rnd.z * 17.3));
		vec3 c0 = vec3(0.97, 0.96, 0.91);
		vec3 c1 = vec3(1.0, 0.78, 0.12);
		vec3 c2 = mix(vec3(0.34, 0.34, 0.92), vec3(0.56, 0.36, 0.92), fract(rnd.z * 11.3));
		vec3 c3 = mix(vec3(0.84, 0.40, 0.60), vec3(0.96, 0.58, 0.74), fract(rnd.y * 5.7));
		v_col = kind < 0.5 ? c0 : kind < 1.5 ? c1 : kind < 2.5 ? c2 : c3;
	}
	v_wpos = vec3(MODEL_MATRIX[3].x, 0.0, MODEL_MATRIX[3].z) + VERTEX;
	VERTEX.y -= MODEL_MATRIX[3].y;
}

void fragment() {
	vec3 dcol;
	if (v_part < 0.5) {
		dcol = vec3(0.12, 0.32, 0.06) * mix(0.65, 1.05, v_uv.y);
	} else if (v_kind > 1.5 && v_kind < 2.5) {
		vec2 q = v_uv * 2.0 - 1.0;
		float env = sin(clamp((q.y + 1.0) * 0.5, 0.0, 1.0) * 3.14159);
		float tier = abs(sin((q.y + 1.0) * 9.5));
		float w_lim = (0.36 + 0.52 * pow(env, 0.7)) * (0.55 + 0.45 * tier);
		if (abs(q.x) > w_lim || abs(q.y) > 0.94) discard;
		vec3 tip_col = mix(v_col * 0.80, vec3(0.86, 0.82, 1.0), smoothstep(-0.2, 0.85, q.y) * 0.42);
		dcol = tip_col * (0.74 + 0.28 * tier) * v_ao;
	} else {
		vec2 q = v_uv * 2.0 - 1.0;
		float r = length(q);
		float a = atan(q.y, q.x);
		float petals = v_kind < 0.5 ? 10.0 : 5.0;
		float shape = (v_kind < 0.5 ? 0.54 : 0.56) + (v_kind < 0.5 ? 0.46 : 0.44) * abs(cos(a * petals * 0.5));
		if (r > shape) discard;
		vec3 col = mix(v_col * 0.72, v_col * 1.12, smoothstep(0.18, 0.88, r));
		float center = smoothstep(0.28, 0.14, r);
		col = mix(col, v_kind < 0.5 ? vec3(1.0, 0.76, 0.10) : v_kind < 1.5 ? vec3(0.84, 0.46, 0.04) : vec3(0.95, 0.78, 0.22), center);
		dcol = col * v_ao;
	}

	vec3 cam = CAMERA_POSITION_WORLD;
	vec3 n = vec3(0.0, 1.0, 0.0);
	float sun_vis = w_cloud_shadow(v_wpos, cam);
	float ramp = w_toon_ramp(dot(n, sun_dir), 0.35, 0.18, 0.62, length(v_wpos - cam));
	vec3 lit = w_light_floor(ramp * light_col * sun_vis * dcol / PI + w_indirect(n, dcol), dcol);
	vec3 atm_mul;
	vec3 atm_add;
	w_atmosphere(v_wpos, cam, atm_mul, atm_add);
	ALBEDO = w_grade(lit * atm_mul + atm_add, SCREEN_UV, VIEWPORT_SIZE);
}
