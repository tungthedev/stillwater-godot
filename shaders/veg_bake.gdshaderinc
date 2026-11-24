// Shared addressing for the grass and flower bakes (systems/grass.gd). The bake target is an RGBA8
// SubViewport laid out like Stillwater's tile atlas: one slot per active tile, a slot is
// slot_w blades wide and slot_h rows tall, and each blade owns `fields` texels side by side
// (field f of blade b sits at x = f * slot_w + b % slot_w, y = b / slot_w inside its slot).
// tests/bake_probe.gd checks that canvas FRAGCOORD rows are texelFetch rows and the bytes are exact.
//
// slot_tex (RGBA8, capacity x 2):
//   row 0 = tile indices (tx + 32768, tz + 32768) as 16-bit LE pairs
//   row 1 = (flags, base_q lo, mid, hi), where base_h = base_q / 1024 - 1024;
//   flags bit 0/1 mirror x/z, bit 2 = bake now. Slots without bit 2 discard so prior bakes stay.
// scatter_tex (RGBA8, near x 3): 16-bit LE pairs for local (x, z), rnd (x, y), rnd (z, w).

#define W_NOISE(uv) textureLod(noise_tex, uv, 0.0)

uniform sampler2D slot_tex : filter_nearest;
uniform sampler2D scatter_tex : filter_nearest;
uniform int slot_cols;
uniform int slot_w;
uniform int slot_h;
uniform int fields = 1;
uniform float tile_size;
uniform float water_level = 22.0;
uniform vec4 ao_spot = vec4(615.25, 796.96, 7.5, 0.35);

// Height is stored relative to the slot's base in 16 bits over this span (1 mm steps).
const float H_SPAN = 64.0;

struct VegTexel {
	int field;
	int rank;
	vec2 xz;
	vec2 tile_origin;
	int flips;
	vec4 rnd;
	float base_h;
};

vec2 veg_u16_pair(vec4 texel) {
	vec4 b = floor(texel * 255.0 + 0.5);
	return vec2(b.x + b.y * 256.0, b.z + b.w * 256.0);
}

// False when this texel's slot is not being baked (the caller discards).
bool veg_texel(vec2 frag, out VegTexel t) {
	ivec2 p = ivec2(frag);
	int sw = slot_w * fields;
	int col = p.x / sw;
	int row = p.y / slot_h;
	int slot_idx = row * slot_cols + col;
	vec4 s1 = floor(texelFetch(slot_tex, ivec2(slot_idx, 1), 0) * 255.0 + 0.5);
	int flags = int(s1.x);
	if ((flags & 4) == 0) {
		return false;
	}
	vec2 tile_ij = veg_u16_pair(texelFetch(slot_tex, ivec2(slot_idx, 0), 0)) - 32768.0;
	int lx = p.x - col * sw;
	t.field = lx / slot_w;
	t.rank = (p.y - row * slot_h) * slot_w + (lx - t.field * slot_w);
	vec2 local = veg_u16_pair(texelFetch(scatter_tex, ivec2(t.rank, 0), 0)) / 65535.0 * tile_size;
	t.rnd = vec4(
		veg_u16_pair(texelFetch(scatter_tex, ivec2(t.rank, 1), 0)),
		veg_u16_pair(texelFetch(scatter_tex, ivec2(t.rank, 2), 0))
	) / 65535.0;
	if ((flags & 1) != 0) local.x = tile_size - local.x;
	if ((flags & 2) != 0) local.y = tile_size - local.y;
	t.tile_origin = tile_ij * tile_size;
	t.flips = flags & 3;
	t.xz = t.tile_origin + local;
	t.base_h = (s1.y + s1.z * 256.0 + s1.w * 65536.0) / 1024.0 - 1024.0;
	return true;
}

// Stillwater's gt_packU: round to the nearest of maxQ + 1 levels.
float veg_q(float v, float max_q) {
	return floor(clamp(v, 0.0, 1.0) * max_q + 0.5);
}

vec2 veg_height_bytes(float h, float base_h) {
	float q = veg_q((h - base_h) / H_SPAN, 65535.0);
	float hi = floor(q / 256.0);
	return vec2(q - hi * 256.0, hi);
}
