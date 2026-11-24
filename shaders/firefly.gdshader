// Twilight & night meadow fireflies (W5):
// 72 tiny additive chartreuse-gold glowing specks drifting lazily above meadows, streams, and
// glades in a 28 m box around the camera purely in vertex (0.000 ms GDScript). Hidden completely
// by day (0 draws at noon!). Zero depth writes, capped radius for tiny mobile fill-rate.
shader_type spatial;
render_mode unshaded, fog_disabled, blend_add, depth_draw_never, cull_disabled, skip_vertex_transform;

#include "res://shaders/stillwater.gdshaderinc"
#include "res://shaders/atmosphere.gdshaderinc"

uniform sampler2D near_tex : filter_linear, repeat_disable;
uniform float near_size = 4096.0;
uniform float near_min = 0.0;
uniform float near_step = 0.01;
uniform float box_size = 28.0;
uniform float firefly_strength = 0.0;

varying vec2 v_q;
varying float v_alpha;
varying vec3 v_col;

float ff_height_near(vec2 xz) {
	float res = float(textureSize(near_tex, 0).x);
	vec2 f = clamp((xz / near_size + 0.5) * res - 0.5, vec2(0.0), vec2(res - 1.001));
	ivec2 i = ivec2(floor(f));
	vec2 t = floor(texelFetch(near_tex, i, 0).rg * 255.0 + 0.5);
	return near_min + near_step * (t.x + t.y * 256.0);
}

void vertex() {
	vec3 cam = CAMERA_POSITION_WORLD;
	vec4 seed = INSTANCE_CUSTOM;

	float t = TIME * 0.42 + seed.w * 29.0;
	vec3 drift = vec3(
		sin(t * 0.85 + seed.x * 17.0) * 1.8,
		0.0,
		cos(t * 0.72 + seed.z * 21.0) * 1.8
	);
	vec3 rel = mod(seed.xyz * box_size + drift - cam + box_size * 0.5, box_size) - box_size * 0.5;
	vec3 p = cam + rel;

	float g = ff_height_near(p.xz);
	p.y = g + 0.40 + fract(seed.y * 4.3) * 2.4 + sin(t * 1.6 + seed.w * 13.0) * 0.35;

	vec3 to_ff = p - cam;
	float dist = length(to_ff);
	vec3 to_cam = -w_normalize(to_ff);
	vec3 right = w_normalize(cross(vec3(0.0, 1.0, 0.0), to_cam));
	if (dot(right, right) < 0.01) {
		right = vec3(1.0, 0.0, 0.0);
	}
	vec3 upv = cross(to_cam, right);

	// Rhythmic biological firefly blink (slow warm-lime pulse with dark pauses).
	float blink_raw = sin(TIME * (1.2 + seed.w * 1.3) + seed.x * 37.0 + seed.z * 19.0);
	float blink = smoothstep(0.12, 0.88, blink_raw);
	float edge = w_rstep(box_size * 0.48, box_size * 0.30, length(rel));
	float dist_k = smoothstep(2.4, 4.5, dist) * w_rstep(18.0, 10.0, dist);
	float above_water = smoothstep(water_level + 0.15, water_level + 1.0, g);
	float below_alpine = w_rstep(320.0, 240.0, g);

	float rad = mix(0.022, 0.052, blink) * (0.85 + seed.w * 0.35);
	vec3 wp = p + (right * VERTEX.x + upv * VERTEX.y) * rad;
	POSITION = PROJECTION_MATRIX * (VIEW_MATRIX * vec4(wp, 1.0));

	v_q = VERTEX.xy;
	v_alpha = blink * edge * dist_k * above_water * below_alpine * firefly_strength;
	v_col = mix(vec3(0.85, 1.0, 0.28), vec3(1.0, 0.86, 0.32), fract(seed.w * 3.7)) * 2.4;
}

void fragment() {
	float r2 = dot(v_q, v_q);
	if (r2 > 1.0) {
		discard;
	}
	float core = exp(-r2 * 5.2);
	float halo = exp(-r2 * 1.8) * 0.38;
	float a = (core + halo) * w_rstep(1.0, 0.22, r2) * v_alpha;
	vec3 glow = w_denan(v_col * a, vec3(0.0));
	ALBEDO = post_on > 0.5
		? godot_out(clamp(glow, vec3(0.0), vec3(8.0)))
		: godot_out(clamp(glow * 0.72, vec3(0.0), vec3(1.0)));
}
