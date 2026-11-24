// Shared addressing for the grass and flower bakes (systems/grass.gd). The bake target is an RGBA8
// SubViewport laid out like Stillwater's tile atlas: one slot per active tile, a slot is
// slot_w blades wide and slot_h rows tall, and each blade owns `fields` texels side by side
// (field f of blade b sits at x = f * slot_w + b % slot_w, y = b / slot_w inside its slot).
// tests/bake_probe.gd checks that canvas FRAGCOORD rows are texelFetch rows and the bytes are exact.
//
// slot_tex row 0 holds one texel per slot: (tile origin x, z, flags, base height); flags bit 0/1
// mirror x/z, bit 2 = bake now. Slots without bit 2 are discarded so their texels stay as baked.
// scatter_tex is the layout's fixed scatter: row 0 = local x, z; row 1 = four randoms, per rank.

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
	vec4 rnd;
	float base_h;
};

// False when this texel's slot is not being baked (the caller discards).
bool veg_texel(vec2 frag, out VegTexel t) {
	ivec2 p = ivec2(frag);
	int sw = slot_w * fields;
	int col = p.x / sw;
	int row = p.y / slot_h;
	vec4 st = texelFetch(slot_tex, ivec2(row * slot_cols + col, 0), 0);
	int flags = int(st.z + 0.5);
	if ((flags & 4) == 0) {
		return false;
	}
	int lx = p.x - col * sw;
	t.field = lx / slot_w;
	t.rank = (p.y - row * slot_h) * slot_w + (lx - t.field * slot_w);
	vec4 sc = texelFetch(scatter_tex, ivec2(t.rank, 0), 0);
	t.rnd = texelFetch(scatter_tex, ivec2(t.rank, 1), 0);
	vec2 local = sc.xy;
	if ((flags & 1) != 0) local.x = tile_size - local.x;
	if ((flags & 2) != 0) local.y = tile_size - local.y;
	t.xz = st.xy + local;
	t.base_h = st.w;
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
