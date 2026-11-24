// Unified painterly grass shader (S3, one tile ring, zero discard).
//
// Short meadows, lawns and path edges fold each near 3-segment blade into a paired chunky V-tuft
// (2 visual blades for 5 tris, smoothly shrinking the secondary blade before the 16 m LOD switch);
// tall golden fields (trailhead, pasture, cottage) unfold into slimmer, taller 3-segment golden
// blades. Edge-on blade thickening prevents grazing slivers, upward-bent normals blend toward the
// ground normal with distance to kill glitter, and 3 of 4 blades drop smoothly over lod_start..lod_end.
// All lighting and aerial perspective run per vertex so the opaque fragment stage does 0 texture fetches.
shader_type spatial;
render_mode unshaded, fog_disabled, cull_disabled, depth_draw_opaque;

#include "res://shaders/stillwater.gdshaderinc"
#include "res://shaders/atmosphere.gdshaderinc"

uniform sampler2D atlas : filter_nearest;
uniform float tile_size = 8.0;
uniform int slot_w = 64;
uniform float far_count = 240.0;
uniform float radius = 30.0;
uniform float lod_start = 10.0;
uniform float lod_end = 16.0;
uniform float far_width_scale = 1.60;
uniform float wind_strength = 0.5;
uniform float dbg_tallness = 0.0;

const float TALL_MAX = 2.2;
const float H_SPAN = 64.0;

varying vec3 v_lit;

vec4 atlas_bytes(ivec2 p) {
	return floor(texelFetch(atlas, p, 0) * 255.0 + 0.5);
}

void vertex() {
	int flips = int(INSTANCE_CUSTOM.z + 0.5);
	vec2 local = CUSTOM0.xy;
	if ((flips & 1) != 0) local.x = tile_size - local.x;
	if ((flips & 2) != 0) local.y = tile_size - local.y;
	vec2 xz = MODEL_MATRIX[3].xz + local;
	vec3 cam = CAMERA_POSITION_WORLD;
	vec2 cam_xz = cam.xz;
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

	float keep = 1.0 - smoothstep(radius * 0.62, radius, dist);
	// Mid-distance 3-of-4 blade drop before switching to the far 2-segment mesh.
	float is_extra = step(far_count - 0.5, float(rank));
	float lod_t = smoothstep(lod_start, lod_end, dist);
	float lod_fade = 1.0 - is_extra * lod_t;
	float scale = dens * keep * lod_fade;

	if (scale <= 0.001) {
		VERTEX = vec3(local.x, h - 1.0 - MODEL_MATRIX[3].y, local.y);
		v_lit = vec3(0.0);
	} else {
		vec4 b1 = atlas_bytes(px + ivec2(slot_w, 0));
		float nx = b1.x / 255.0 * 2.0 - 1.0;
		float nz = b1.y / 255.0 * 2.0 - 1.0;
		vec3 tn = vec3(nx, sqrt(max(0.0, 1.0 - nx * nx - nz * nz)), nz);
		float tall_static = b1.z / 255.0 * TALL_MAX;
		float yaw = b1.w / 255.0 * 6.2831853;

		vec4 b2 = atlas_bytes(px + ivec2(slot_w * 2, 0));
		vec3 s_col = b2.rgb / 255.0;
		vec3 tone = s_col * s_col;
		int a2 = int(b2.w);
		float field_k = float(a2 & 15) / 15.0;
		float gold = float(a2 >> 4) / 15.0;

		// True 3D near-camera fade prevents blades poking straight through the lens without leaving
		// a sparse ring around the feet.
		float d3 = length(vec3(xz.x, h, xz.y) - cam);
		float near_k = smoothstep(0.35, 1.20, d3);
		float far_wide = mix(1.0, far_width_scale, (1.0 - is_extra) * lod_t);
		float height = tall_static * scale * mix(0.78, 1.0, near_k);
		// Tie width to scale so thinning blades shrink cleanly instead of flattening into paper strips;
		// tall golden field blades stay slimmer than chunky short-meadow tufts.
		float width = 0.168 * mix(1.0, 0.46, field_k) * mix(0.76, 1.28, rnd.x)
				* (1.0 + dist * 0.028) * far_wide * mix(0.65, 1.0, near_k)
				* smoothstep(0.0, 0.24, scale);

		vec2 fwd = vec2(cos(yaw), sin(yaw));
		vec2 sd = vec2(-fwd.y, fwd.x);

		// Edge-on blade thickening: rotate width axis toward camera-right and widen grazing blades
		// so fewer blades stay visually full with zero razor-thin aliasing slivers.
		vec2 to_cam = cam_xz - xz;
		vec2 view_xz = to_cam * inversesqrt(max(dot(to_cam, to_cam), 1e-8));
		float face_dot = abs(dot(fwd, view_xz));
		float edge_on = 1.0 - smoothstep(0.0, 0.55, face_dot);
		vec2 cam_side = vec2(-view_xz.y, view_xz.x);
		cam_side *= (dot(cam_side, sd) < 0.0 ? -1.0 : 1.0);
		vec2 eff_sd = sd + cam_side * edge_on * 0.72;
		eff_sd *= inversesqrt(max(dot(eff_sd, eff_sd), 1e-8));
		width *= 1.0 + edge_on * mix(0.32, 0.18, field_k);

		float gust = textureLod(noise_tex, xz * 0.0082 - wind_dir * TIME * 0.042, 0.0).r;
		float gust2 = textureLod(noise_tex, xz * 0.024 - wind_dir * TIME * 0.075 + 0.4, 0.0).g;
		float wave = smoothstep(0.26, 0.76, gust * 0.72 + gust2 * 0.28);
		float flutter = sin(TIME * (2.0 + rnd.y * 1.6) + rnd.x * 6.28 + dot(xz, wind_dir) * 0.55) * 0.14;
		float bend = (0.28 + rnd.y * 0.38) + (wave * 0.70 + flutter) * (0.25 + wind_strength * 0.75);

		vec2 to_p = xz - cam_xz;
		float pd = length(to_p);
		float push = 1.0 - smoothstep(0.2, 1.1, pd);
		vec2 bend_dir = fwd * mix(0.88, 0.36, field_k) + wind_dir * (0.20 + wave * 1.10 + field_k * 0.30) + (to_p / max(pd, 0.01)) * push * 3.0;
		bend_dir *= inversesqrt(max(dot(bend_dir, bend_dir), 1e-12));
		// Tall golden field blades sweep gracefully with the wind without creasing like folded paper.
		bend *= mix(1.0, 0.72, field_k);
		bend += push * 1.2;

		float raw_y = VERTEX.y;
		float y_eff;
		vec3 p;
		// Short meadow / lawn / path-edge tufts fold the near 3-segment strip into a paired V-tuft:
		// v0..v1 collapse to the tip of blade A splayed softly from blade B (v2..v6). Blade A fades out
		// over lod_start..lod_end so the tile hands off seamlessly to the far 2-segment mesh.
		bool folded = (CUSTOM0.w > 0.5) && (field_k < 0.42) && (tall_static < 0.52) && (reed < 0.5);
		if (folded) {
			if (raw_y < 0.10) {
				y_eff = 1.0;
				float ha = height * (0.76 + 0.24 * fract(rnd.x * 5.31)) * (1.0 - lod_t);
				float ba = bend * 0.48;
				vec2 dir_a = -fwd * 0.45 + sd * (rnd.x - 0.5) * 0.65 + wind_dir * (0.35 + wave * 0.85) + (to_p / max(pd, 0.01)) * push * 2.5;
				dir_a *= inversesqrt(max(dot(dir_a, dir_a), 1e-12));
				p.xz = local + dir_a * ba * ha * 0.78;
				p.y = h + ha * (1.0 - min(ba, 1.0) * 0.28) - 0.03;
			} else {
				y_eff = raw_y < 0.50 ? 0.0 : (raw_y < 0.90 ? 0.5 : 1.0);
				float c = y_eff * y_eff * bend;
				p.xz = local + eff_sd * VERTEX.x * width * 0.88 * (1.0 - y_eff) + bend_dir * c * height * 0.80;
				p.y = h + y_eff * height * (1.0 - min(c, 1.0) * 0.35) - 0.03;
			}
		} else {
			y_eff = raw_y;
			float c = y_eff * y_eff * bend;
			// Chunky wedge tapering to a pointed tip; sunk 3 cm into ground so slopes show no gaps.
			p.xz = local + eff_sd * VERTEX.x * width * (1.0 - y_eff) + bend_dir * c * height * 0.80;
			p.y = h + y_eff * height * (1.0 - min(c, 1.0) * 0.35) - 0.03;
		}

		vec3 wpos = vec3(MODEL_MATRIX[3].x, 0.0, MODEL_MATRIX[3].z) + p;
		VERTEX = vec3(p.x, p.y - MODEL_MATRIX[3].y, p.z);

		if (dbg_tallness > 0.5) {
			float g = clamp(tall_static / TALL_MAX, 0.0, 1.0);
			v_lit = post_on > 0.5 ? vec3(g * 4.0) : vec3(g);
		} else {
			// Ground-matched base -> sunlit tip gradient; base rises smoothly toward ground tone at mid
			// distance so the 1-of-4 surviving far blades melt into the painted ground.
			float far_ground_k = smoothstep(10.0, 22.0, dist);
			float base_mul = mix(mix(0.74, 0.80, field_k), 0.90, far_ground_k);
			vec3 base_col = tone * base_mul;
			vec3 tip_col = tone * mix(1.42, 1.36, field_k) + mix(vec3(0.006, 0.020, 0.012), vec3(0.115, 0.088, 0.005), field_k);
			// Sunlit gust waves lift golden field tips just like the moving light in the meadow.
			tip_col *= 1.0 + 0.16 * wave * field_k;
			float low_sun = 1.0 - smoothstep(0.06, 0.30, sun_dir.y);
			float warm_tip_k = smoothstep(0.35, 0.85, fract(rnd.w * 3.71) + 0.30 * field_k);
			tip_col = mix(tip_col, mix(tip_col * vec3(1.16, 0.98, 0.74), vec3(0.713, 0.598, 0.184), warm_tip_k * 0.55), low_sun * 0.65);
			tip_col = mix(tip_col, tip_col * vec3(1.06, 1.02, 0.86), gold * field_k * 0.35);

			vec3 col = mix(base_col, tip_col, smoothstep(0.0, 1.0, y_eff));
			col *= 1.0 + 0.05 * wave * y_eff;
			col = mix(col, mix(vec3(0.11, 0.22, 0.07), vec3(0.46, 0.44, 0.17), y_eff), reed);
			col *= mix(1.0, 0.74, forest_shade);

			// Upward-bent normals blended toward the terrain ground normal with distance (eliminates far glitter).
			vec3 n_near = w_normalize(tn + vec3(bend_dir.x * 0.16 * y_eff, 0.45, bend_dir.y * 0.16 * y_eff));
			vec3 n_far = w_normalize(tn + vec3(0.0, 0.30, 0.0));
			vec3 n = w_normalize(mix(n_near, n_far, smoothstep(6.0, 22.0, dist)));

			// Vertex-evaluated soft painterly lighting: flatter toon ramp (wrap 0.6, lo 0.05, hi 0.75),
			// no per-blade shine, subtle backlit tip warmth and forest bounce.
			float sun_vis = w_cloud_shadow_v(wpos, cam);
			float w_r = (dot(n, sun_dir) + 0.60) / 1.60;
			float ramp = smoothstep(0.05, 0.75, w_r);
			vec3 direct = ramp * light_col * sun_vis * col / PI;
			vec3 ind = w_indirect(n, col);

			vec3 Vw = w_normalize(wpos - cam);
			float back = pow(max(dot(Vw, sun_dir), 0.0), 3.6);
			float lit_k = sun_vis * smoothstep(-0.02, 0.08, sun_dir.y);
			vec3 sheen_tint = mix(vec3(1.0, 1.0, 0.90), vec3(1.08, 0.80, 0.48), low_sun);
			vec3 emis = col * light_col * sheen_tint * (back * 0.32 + 0.025 + wave * 0.045) * y_eff * lit_k;
			emis += col * vec3(0.9, 1.0, 0.6) * forest_shade * 0.04 * length(light_col);

			vec3 lit = w_light_floor(direct + ind + emis, col);
			vec3 atm_mul;
			vec3 atm_add;
			w_atmosphere(wpos, cam, atm_mul, atm_add);
			v_lit = lit * atm_mul + atm_add;
		}
	}
}

void fragment() {
	ALBEDO = w_grade(v_lit, SCREEN_UV, VIEWPORT_SIZE);
}
