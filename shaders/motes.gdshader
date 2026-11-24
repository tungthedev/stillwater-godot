// Sunlit drifting pollen & forest-glade dust motes (W4):
// 160 tiny camera-facing additive quads wrapping periodically in a 24 m box around
// CAMERA_POSITION_WORLD purely in vertex (0.000 ms GDScript). Ground-referenced via near_tex
// texelFetch, hidden over water, clamped screen radius for minimal mobile fill-rate.
shader_type spatial;
render_mode unshaded, fog_disabled, blend_add, depth_draw_never, cull_disabled, skip_vertex_transform;

#include "res://shaders/stillwater.gdshaderinc"
#include "res://shaders/atmosphere.gdshaderinc"

uniform sampler2D near_tex : filter_linear, repeat_disable;
uniform sampler2D biome_tex : filter_linear, repeat_disable;
uniform float near_size = 4096.0;
uniform float near_min = 0.0;
uniform float near_step = 0.01;
uniform float box_size = 24.0;
uniform float mote_strength = 1.0;

varying vec2 v_q;
varying float v_alpha;
varying vec3 v_col;

float mote_height_near(vec2 xz) {
	float res = float(textureSize(near_tex, 0).x);
	vec2 f = clamp((xz / near_size + 0.5) * res - 0.5, vec2(0.0), vec2(res - 1.001));
	ivec2 i = ivec2(floor(f));
	vec2 t = floor(texelFetch(near_tex, i, 0).rg * 255.0 + 0.5);
	return near_min + near_step * (t.x + t.y * 256.0);
}

void vertex() {
	vec3 cam = CAMERA_POSITION_WORLD;
	vec4 seed = INSTANCE_CUSTOM;

	vec3 base = seed.xyz * box_size;
	vec3 drift = vec3(wind_dir.x, 0.0, wind_dir.y) * TIME * 0.55;
	drift += vec3(
		sin(TIME * 0.31 + seed.w * 30.0),
		sin(TIME * 0.23 + seed.w * 17.0) * 0.55,
		cos(TIME * 0.27 + seed.w * 23.0)
	) * 1.05;

	vec3 rel = mod(base + drift - cam + box_size * 0.5, box_size) - box_size * 0.5;
	vec3 p = cam + rel;
	float g = mote_height_near(p.xz);
	p.y = g + 0.35 + fract(seed.y * 3.7) * 3.8 + sin(TIME * 0.30 + seed.w * 11.0) * 0.35;

	vec3 to_mote = p - cam;
	float dist = length(to_mote);
	vec3 dir = w_normalize(to_mote);
	vec3 to_cam = -dir;
	vec3 right = w_normalize(cross(vec3(0.0, 1.0, 0.0), to_cam));
	if (dot(right, right) < 0.01) {
		right = vec3(1.0, 0.0, 0.0);
	}
	vec3 upv = cross(to_cam, right);

	// Tiny crisp speck radius capped so fill-rate stays negligible on tile GPUs.
	float rad = clamp(0.018 + seed.w * 0.016, 0.014, 0.036);
	vec3 wp = p + (right * VERTEX.x + upv * VERTEX.y) * rad;
	POSITION = PROJECTION_MATRIX * (VIEW_MATRIX * vec4(wp, 1.0));
	v_q = VERTEX.xy;

	// Sunlit forward-scatter boost + subtle glade sparkle; hidden over water & past 12 m.
	float edge = w_rstep(box_size * 0.48, box_size * 0.30, length(rel));
	float dist_k = smoothstep(1.0, 2.6, dist) * w_rstep(12.5, 7.2, dist);
	float above_water = smoothstep(water_level + 0.3, water_level + 1.2, g);
	float sun_up = smoothstep(0.02, 0.14, sun_dir.y) * sun_disc_vis;
	float mu = max(dot(dir, sun_dir), 0.0);
	float mu2 = mu * mu;
	float fwd = mu2 * mu2;
	float forest = textureLod(biome_tex, clamp(p.xz / near_size + 0.5, vec2(0.001), vec2(0.999)), 0.0).r;
	float twinkle = 0.65 + 0.35 * sin(TIME * 2.1 + seed.w * 41.0);
	float lit = w_cloud_shadow_v(p + vec3(0.0, 2.0, 0.0), cam);

	v_alpha = (0.18 + 0.22 * forest + 0.72 * fwd) * lit * edge * dist_k * above_water * sun_up * twinkle * mote_strength;
	v_col = mix(light_col * 0.28, vec3(1.0, 0.94, 0.68) * 1.45, 0.45);
}

void fragment() {
	float r2 = dot(v_q, v_q);
	if (r2 > 1.0) {
		discard;
	}
	float a = exp(-r2 * 3.8) * w_rstep(1.0, 0.25, r2) * v_alpha;
	vec3 glow = w_denan(v_col * a, vec3(0.0));
	ALBEDO = post_on > 0.5
		? godot_out(clamp(glow, vec3(0.0), vec3(4.0)))
		: godot_out(clamp(glow * 0.65, vec3(0.0), vec3(1.0)));
}
