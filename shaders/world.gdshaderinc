// Stillwater's world fields (src/glsl/common.js): rendered height with the near/far blend, normal,
// trail mask and biome, from the compact pack (world/compact_world.gd). Shared by the terrain and
// the grass / flower bakes so both read the ground the same way.

uniform sampler2D near_tex : filter_linear, repeat_disable;
uniform sampler2D far_tex : filter_nearest, repeat_disable;
uniform sampler2D biome_tex : filter_linear, repeat_disable;
uniform float near_size = 4096.0;
uniform float near_min;
uniform float near_step;
uniform float far_size = 32768.0;
uniform float far_min;
uniform float far_step;

// ---------------- heights ----------------
float near_code(ivec2 i) {
	vec2 t = floor(texelFetch(near_tex, i, 0).rg * 255.0 + 0.5);
	return t.x + t.y * 256.0;
}

float far_code(ivec2 i) {
	vec3 t = floor(texelFetch(far_tex, i, 0).rgb * 255.0 + 0.5);
	return t.x + t.y * 256.0 + t.z * 65536.0;
}

// HeightField._sample: texel centres, edge clamp at res - 1.001.
float w_height_near(vec2 xz) {
	float res = float(textureSize(near_tex, 0).x);
	vec2 f = clamp((xz / near_size + 0.5) * res - 0.5, vec2(0.0), vec2(res - 1.001));
	vec2 fl = floor(f);
	ivec2 i = ivec2(fl);
	vec2 t = f - fl;
	float a = near_code(i);
	float b = near_code(i + ivec2(1, 0));
	float c = near_code(i + ivec2(0, 1));
	float d = near_code(i + ivec2(1, 1));
	return near_min + near_step * mix(mix(a, b, t.x), mix(c, d, t.x), t.y);
}

float w_height_far(vec2 xz) {
	float res = float(textureSize(far_tex, 0).x);
	vec2 f = clamp((xz / far_size + 0.5) * res - 0.5, vec2(0.0), vec2(res - 1.001));
	vec2 fl = floor(f);
	ivec2 i = ivec2(fl);
	vec2 t = f - fl;
	float a = far_code(i);
	float b = far_code(i + ivec2(1, 0));
	float c = far_code(i + ivec2(0, 1));
	float d = far_code(i + ivec2(1, 1));
	return far_min + far_step * mix(mix(a, b, t.x), mix(c, d, t.x), t.y);
}

float w_near_blend(vec2 xz) {
	float e = max(abs(xz.x), abs(xz.y));
	return smoothstep(near_size * 0.5 - 220.0, near_size * 0.5 - 20.0, e);
}

float w_height(vec2 xz) {
	float t = w_near_blend(xz);
	if (t <= 0.0) return w_height_near(xz);
	if (t >= 1.0) return w_height_far(xz);
	return mix(w_height_near(xz), w_height_far(xz), t);
}

vec3 w_normal(vec2 xz, float e) {
	float hx0 = w_height(xz - vec2(e, 0.0));
	float hx1 = w_height(xz + vec2(e, 0.0));
	float hz0 = w_height(xz - vec2(0.0, e));
	float hz1 = w_height(xz + vec2(0.0, e));
	return normalize(vec3(hx0 - hx1, 2.0 * e, hz0 - hz1));
}

// Fast vertex height + surface normal from the same 4 bilinear height taps (0 extra fetches).
float w_height_near_n(vec2 xz, out vec3 n) {
	float res = float(textureSize(near_tex, 0).x);
	vec2 f = clamp((xz / near_size + 0.5) * res - 0.5, vec2(0.0), vec2(res - 1.001));
	vec2 fl = floor(f);
	ivec2 i = ivec2(fl);
	vec2 t = f - fl;
	float a = near_code(i);
	float b = near_code(i + ivec2(1, 0));
	float c = near_code(i + ivec2(0, 1));
	float d = near_code(i + ivec2(1, 1));
	float cell = near_size / res;
	float dhdx = mix(b - a, d - c, t.y) * near_step / cell;
	float dhdz = mix(c - a, d - b, t.x) * near_step / cell;
	vec3 nv = vec3(-dhdx, 1.0, -dhdz);
	n = nv * inversesqrt(max(dot(nv, nv), 1e-20));
	return near_min + near_step * mix(mix(a, b, t.x), mix(c, d, t.x), t.y);
}

// Far height + smooth mountain normal using 4 single-texel wide-baseline taps (4 extra fetches vs 16).
float w_height_far_n(vec2 xz, float e, out vec3 n) {
	int ires = textureSize(far_tex, 0).x;
	float res = float(ires);
	vec2 f = clamp((xz / far_size + 0.5) * res - 0.5, vec2(0.0), vec2(res - 1.001));
	vec2 fl = floor(f);
	ivec2 i = ivec2(fl);
	vec2 t = f - fl;
	float a = far_code(i);
	float b = far_code(i + ivec2(1, 0));
	float c = far_code(i + ivec2(0, 1));
	float d = far_code(i + ivec2(1, 1));
	float cell = far_size / res;
	int step_i = max(1, int(floor(e / cell + 0.5)));
	ivec2 ic = clamp(ivec2(floor(f + 0.5)), ivec2(0), ivec2(ires - 1));
	float hx0 = far_code(ivec2(max(ic.x - step_i, 0), ic.y));
	float hx1 = far_code(ivec2(min(ic.x + step_i, ires - 1), ic.y));
	float hz0 = far_code(ivec2(ic.x, max(ic.y - step_i, 0)));
	float hz1 = far_code(ivec2(ic.x, min(ic.y + step_i, ires - 1)));
	float span = 2.0 * float(step_i) * cell;
	vec3 nv = vec3((hx0 - hx1) * far_step, span, (hz0 - hz1) * far_step);
	n = nv * inversesqrt(max(dot(nv, nv), 1e-20));
	return far_min + far_step * mix(mix(a, b, t.x), mix(c, d, t.x), t.y);
}

float w_height_n(vec2 xz, float e, out vec3 n) {
	float b = w_near_blend(xz);
	if (b <= 0.0) return w_height_near_n(xz, n);
	if (b >= 1.0) return w_height_far_n(xz, e, n);
	vec3 nn;
	vec3 nf;
	float hn = w_height_near_n(xz, nn);
	float hf = w_height_far_n(xz, e, nf);
	vec3 nm = mix(nn, nf, b);
	n = nm * inversesqrt(max(dot(nm, nm), 1e-20));
	return mix(hn, hf, b);
}

float w_trail_raw(vec2 xz) {
	vec2 uv = xz / near_size + 0.5;
	if (any(lessThan(uv, vec2(0.0))) || any(greaterThan(uv, vec2(1.0)))) return 0.0;
	return (texture(near_tex, uv).b * 255.0 - 128.0) / 127.0;
}

vec4 w_biome(vec2 xz) {
	vec4 b = vec4(texture(biome_tex, xz / near_size + 0.5).rgb, 1.0);
	return mix(b, vec4(0.55, 0.0, 0.3, 0.0), w_near_blend(xz));
}

// Meadow colour from the ground patch map (common.js w_grassColor). Stillwater's terrain samples it
// in a fragment shader (mips by derivative) and its grass bake in a vertex shader (mip 0); a
// fragment-shader bake defines W_NOISE as a level-0 read before including this file.
#ifndef W_NOISE
#define W_NOISE(uv) texture(noise_tex, uv)
#endif

vec3 w_grass_color(vec2 xz, float h) {
	vec4 a = W_NOISE(xz * 0.0014 + 0.11);
	vec4 b = W_NOISE(xz * 0.0075 + 0.37);
	vec4 big = W_NOISE(xz * 0.00052 + 0.6);
	vec4 mac = W_NOISE(xz * 0.00026 + 0.83);
	vec4 patch_m = W_NOISE(xz * 0.0034 + 0.19);
	float t = a.r * 0.54 + b.g * 0.46;
	vec3 c = mix(vec3(0.042, 0.195, 0.052), vec3(0.135, 0.375, 0.072), smoothstep(0.20, 0.56, t));
	c = mix(c, vec3(0.36, 0.46, 0.11), smoothstep(0.50, 0.80, t) * 0.82);
	c = mix(c, vec3(0.036, 0.215, 0.095), smoothstep(0.42, 0.74, big.g) * 0.68);
	c = mix(c, vec3(0.44, 0.45, 0.13), smoothstep(0.46, 0.76, big.b) * 0.62);
	c = mix(c, vec3(0.49, 0.41, 0.15), smoothstep(0.50, 0.76, mac.r) * 0.58);
	c = mix(c, vec3(0.052, 0.24, 0.105), smoothstep(0.48, 0.76, patch_m.b) * 0.52);
	c = mix(c, vec3(0.28, 0.42, 0.12), smoothstep(0.58, 0.82, patch_m.r) * 0.42);
	c = mix(c, vec3(0.42, 0.46, 0.18), smoothstep(640.0, 1020.0, h + (a.b - 0.5) * 180.0));
	return c;
}
