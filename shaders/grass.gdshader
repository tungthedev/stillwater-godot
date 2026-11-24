// Stillwater's meadow grass blades (src/world/grass.js GRASS_VERTEX and its patched
// MeshStandardMaterial) on Godot.
//
// One static mesh holds a whole tile's blades (VERTEX = blade-local x in [-0.5, 0.5] and height
// fraction y; CUSTOM0 = tile-local root x, z and rank; CUSTOM1 = the rank's four randoms). Each
// MultiMesh instance is one tile: its transform moves the mesh to (tile origin x, base height,
// tile origin z) and INSTANCE_CUSTOM = (atlas slot x, y, mirror bits). The shader works in world
// heights and subtracts the base at the end. The blade's static fields come
// from the tile atlas (shaders/grass_bake.gdshader); wind, bend, LOD fade and colour are live.
//
// Lighting is Stillwater's at hour 16 (unshaded here): toon sun ramp with the material defaults
// (wrap 0.35, lo 0.18, hi 0.62; roughness 0.75 gives no specular), hemisphere fill, the back-light
// sheen and forest emissive, per-pixel aerial perspective, the post grade. Not ported: the
// shadow map and terrain self-shadow (sun visibility is the cloud shadow only, as for the terrain),
// and the golden-hour / dawn / dusk / night / lantern terms, all 0 at hour 16.
shader_type spatial;
render_mode unshaded, fog_disabled, cull_disabled, depth_draw_opaque;

#include "res://shaders/stillwater.gdshaderinc"
#include "res://shaders/atmosphere.gdshaderinc"

uniform sampler2D atlas : filter_nearest;
uniform vec2 cam_xz;
uniform vec2 player_xz = vec2(100000.0);
uniform float tile_size = 8.0;
uniform int slot_w = 64;
uniform float far_count = 1024.0;
uniform float radius = 30.0;
uniform float lod_start = 10.0;
uniform float lod_end = 16.0;
uniform float far_width_scale = 1.32;
uniform float wind_strength = 0.5;
uniform float dbg_tallness = 0.0;

const float TALL_MAX = 2.2;
const float H_SPAN = 64.0;

varying vec3 v_wpos;
varying float v_y;
varying float v_wave;
varying float v_forest;
varying vec3 v_col;
varying vec3 v_n;
varying float v_tall_dbg;

vec4 atlas_bytes(ivec2 p) {
	return floor(texelFetch(atlas, p, 0) * 255.0 + 0.5);
}

void vertex() {
	int flips = int(INSTANCE_CUSTOM.z + 0.5);
	vec2 local = CUSTOM0.xy;
	if ((flips & 1) != 0) local.x = tile_size - local.x;
	if ((flips & 2) != 0) local.y = tile_size - local.y;
	vec2 xz = MODEL_MATRIX[3].xz + local;
	float dist = length(xz - cam_xz);
	vec4 rnd = CUSTOM1;

	int rank = int(CUSTOM0.z + 0.5);
	ivec2 px = ivec2(INSTANCE_CUSTOM.xy + 0.5) + ivec2(rank % slot_w, rank / slot_w);
	vec4 b0 = atlas_bytes(px);
	float h = MODEL_MATRIX[3].y + (b0.x + b0.y * 256.0) / 65535.0 * H_SPAN;
	float dens = b0.z / 255.0;
	int a0 = int(b0.w);
	float forest_shade = float(a0 & 3) / 3.0;
	float reed = float((a0 >> 2) & 1);

	float keep = 1.0 - smoothstep(radius * 0.68, radius, dist);
	// Near-only blades fade to 0 before the tile switches to the far 3-triangle mesh.
	float is_extra = step(far_count - 0.5, float(rank));
	float lod_fade = 1.0 - is_extra * smoothstep(lod_start, lod_end, dist);
	float scale = dens * keep * lod_fade;

	if (scale <= 0.001) {
		VERTEX = vec3(local.x, h - 1.0, local.y);
		v_y = 0.0;
		v_wave = 0.0;
		v_forest = 0.0;
		v_col = vec3(0.0);
		v_n = vec3(0.0, 1.0, 0.0);
		v_tall_dbg = 0.0;
	} else {
		vec4 b1 = atlas_bytes(px + ivec2(slot_w, 0));
		float nx = b1.x / 255.0 * 2.0 - 1.0;
		float nz = b1.y / 255.0 * 2.0 - 1.0;
		vec3 tn = vec3(nx, sqrt(max(0.0, 1.0 - nx * nx - nz * nz)), nz);
		float tall_static = b1.z / 255.0 * TALL_MAX;
		float yaw = b1.w / 255.0 * 6.2831853;
		v_tall_dbg = clamp(tall_static / TALL_MAX, 0.0, 1.0);

		float is_short_under = step(rnd.x, 0.38) * (1.0 - smoothstep(22.0, 38.0, dist));
		float tall = mix(tall_static, 0.14 + 0.15 * rnd.y, is_short_under * 0.80 * (1.0 - reed));
		float height = tall * scale;
		float far_wide = mix(1.0, far_width_scale, (1.0 - is_extra) * smoothstep(lod_start, lod_end, dist));
		float width = mix(0.050, 0.088, is_short_under) * mix(0.68, 1.42, rnd.x) * (1.0 + dist * 0.028) * far_wide;

		float y = VERTEX.y;
		vec2 fwd = vec2(cos(yaw), sin(yaw));
		vec2 sd = vec2(-fwd.y, fwd.x);
		float gust = textureLod(noise_tex, xz * 0.0082 - wind_dir * TIME * 0.042, 0.0).r;
		float gust2 = textureLod(noise_tex, xz * 0.024 - wind_dir * TIME * 0.075 + 0.4, 0.0).g;
		float wave = smoothstep(0.26, 0.76, gust * 0.72 + gust2 * 0.28);
		float flutter = sin(TIME * (2.0 + rnd.y * 1.6) + rnd.x * 6.28 + dot(xz, wind_dir) * 0.55) * 0.16;
		float bend = (0.10 + rnd.y * 0.34) + (wave * 0.82 + flutter) * (0.28 + wind_strength * 0.82);

		vec2 to_p = xz - player_xz;
		float pd = length(to_p);
		float push = 1.0 - smoothstep(0.2, 1.1, pd);
		vec2 bend_dir = normalize(fwd * 0.48 + wind_dir * (0.25 + wave * 1.45) + (to_p / max(pd, 0.01)) * push * 3.0);
		bend += push * 1.2;
		float c = y * y * bend;
		vec3 p;
		p.xz = local + sd * VERTEX.x * width * (1.0 - y * 0.9) + bend_dir * c * height * 0.8;
		p.y = h + y * height * (1.0 - min(c, 1.0) * 0.35) - 0.02;
		VERTEX = p;
		v_y = y;
		v_wave = wave;
		v_forest = forest_shade;

		vec4 b2 = atlas_bytes(px + ivec2(slot_w * 2, 0));
		vec3 s = b2.rgb / 255.0;
		vec3 gcol = s * s;
		int a2 = int(b2.w);
		float dry_tip = float(a2 & 15) / 15.0;
		float hollow = float(a2 >> 4) / 15.0 * (1.0 - wave * 0.55);
		gcol = mix(gcol, vec3(0.036, 0.20, 0.095), hollow * 0.62);
		vec3 tip_base = gcol * mix(0.96, 1.36, rnd.y);
		vec3 tip_warm = mix(tip_base, vec3(0.62, 0.52, 0.16), dry_tip * 0.56);
		tip_warm = mix(tip_warm * vec3(0.84, 0.92, 0.96), tip_warm * vec3(1.28, 1.22, 0.82) + vec3(0.04, 0.04, 0.0), wave);
		vec3 base_col = gcol * 0.68 * (0.86 + 0.24 * wave);
		vec3 col = mix(base_col, tip_warm, smoothstep(0.0, 1.0, y));
		col *= 0.88 + 0.24 * rnd.x;
		col = mix(col, mix(vec3(0.11, 0.22, 0.07), vec3(0.46, 0.44, 0.17), y), reed);
		col *= mix(1.0, 0.74, forest_shade);
		v_col = col;
		v_n = normalize(tn + vec3(0.0, 0.42, 0.0));
	}
	v_wpos = vec3(MODEL_MATRIX[3].x, 0.0, MODEL_MATRIX[3].z) + VERTEX;
	VERTEX.y -= MODEL_MATRIX[3].y;
}

void fragment() {
	if (dbg_tallness > 0.5) {
		// ?grassdbg=1: shade blades black (0) to white (TALL_MAX) by decoded tallness; ground stays normal.
		vec3 g = vec3(v_tall_dbg);
		ALBEDO = post_on > 0.5 ? godot_out(g * 4.0) : godot_out(g);
	} else {
		vec3 cam = CAMERA_POSITION_WORLD;
		float cam_d = length(v_wpos - cam);
		vec3 dcol = v_col * mix(0.84, 1.0, smoothstep(0.0, 0.45, v_y));
		vec3 n = normalize(v_n);
		float sun_vis = w_cloud_shadow(v_wpos, cam);
		float ramp = w_toon_ramp(dot(n, sun_dir), 0.35, 0.18, 0.62, cam_d);
		vec3 direct = ramp * light_col * sun_vis * dcol / PI;
		vec3 ind = w_indirect(n, dcol);

		vec3 emis = vec3(0.0);
		{
			vec3 Vw = normalize(v_wpos - cam);
			float back = pow(max(dot(Vw, sun_dir), 0.0), 3.6);
			float lit_k = sun_vis * smoothstep(-0.02, 0.08, sun_dir.y);
			float back_k = painterly > 0.5 ? 0.45 : 0.75;
			emis += v_col * light_col * vec3(1.0, 1.0, 0.90) * (back * back_k + 0.03 + v_wave * 0.05) * v_y * lit_k;
			emis += v_col * vec3(0.9, 1.0, 0.6) * v_forest * 0.04 * length(light_col);
		}

		vec3 lit = w_light_floor(direct + ind + emis, dcol);
		vec3 atm_mul;
		vec3 atm_add;
		w_atmosphere(v_wpos, cam, atm_mul, atm_add);
		ALBEDO = w_grade(lit * atm_mul + atm_add, SCREEN_UV, VIEWPORT_SIZE);
	}
}
