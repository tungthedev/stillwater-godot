// Painted grass static per-blade atlas bake (systems/grass.gd).
// Packs three RGBA8 texels per blade, matching the classic slot layout:
//   field 0: height lo, height hi, density, forest shade (2 bits) | shore reed << 2
//   field 1: ground normal x, normal z, static tallness (/ 2.2 m), fan yaw (/ 2 pi)
//   field 2: clump painted tone r, g, b (sqrt-encoded), field_k (4 bits) | gold << 4
// All blades in a clump sample the shared painted palette at the clump root (rank % clump_count)
// so every blade in a tuft shares one ground-matched tone.
shader_type canvas_item;
render_mode blend_disabled;

#include "res://shaders/stillwater.gdshaderinc"
#include "res://shaders/veg_bake.gdshaderinc"
#include "res://shaders/world.gdshaderinc"
#include "res://shaders/paint_palette.gdshaderinc"

uniform int clump_count = 192;

const float TALL_MAX = 2.2;

void fragment() {
	VegTexel t;
	if (!veg_texel(FRAGCOORD.xy, t)) {
		discard;
	}
	vec2 xz = t.xz;
	vec4 rnd = t.rnd;

	// Blade 0 of this clump (rank % clump_count) sits at the clump root; use its world XZ
	// for shared clump colour, biome and field weight so the whole tuft reads as one brushstroke.
	int clump_rank = t.rank % max(clump_count, 1);
	vec2 clump_local = veg_u16_pair(texelFetch(scatter_tex, ivec2(clump_rank, 0), 0)) / 65535.0 * tile_size;
	if ((t.flips & 1) != 0) clump_local.x = tile_size - clump_local.x;
	if ((t.flips & 2) != 0) clump_local.y = tile_size - clump_local.y;
	vec2 clump_xz = t.tile_origin + clump_local;

	float h = w_height(xz);
	vec3 tn = w_normal(xz, 1.0);
	vec4 bio = w_biome(clump_xz);
	float trail = abs(w_trail_raw(xz));

	float dens = smoothstep(0.30, 0.58, tn.y);
	// Organic trampled path margin without stray blades in the center of the dirt trail.
	dens *= 1.0 - smoothstep(0.32, 0.58, trail + (rnd.x - 0.5) * 0.26);
	float reed_zone = (1.0 - smoothstep(0.2, 0.9, abs(h - water_level + 0.1))) * smoothstep(0.52, 0.74, W_NOISE(xz * 0.035 + 0.4).r);
	dens *= max(smoothstep(water_level + 0.15, water_level + 1.0, h), reed_zone);
	dens *= 1.0 - smoothstep(1050.0, 1300.0, h);
	float cot_meadow = ao_spot.z > 0.1 ? (1.0 - smoothstep(32.0, 52.0, length(clump_xz - ao_spot.xy))) : 0.0;
	float forest_amt = smoothstep(0.28, 0.66, bio.r) * (1.0 - cot_meadow);
	// Sunlit trail clearings through forest edges keep a visible painted grass fringe along both
	// banks while deep forest floor stays sparse.
	float verge_fringe = smoothstep(0.02, 0.18, trail) * (1.0 - smoothstep(0.38, 0.58, trail));
	float forest_cut = mix(1.0, 0.04, smoothstep(0.36, 0.74, forest_amt));
	dens *= max(forest_cut, verge_fringe * mix(1.0, 0.78, forest_amt));

	vec4 clump_n = W_NOISE(clump_xz * 0.055 + 0.19);
	dens *= max(max(smoothstep(0.02, 0.26, clump_n.g + 0.28), cot_meadow * 0.85), verge_fringe * 0.65);

	vec2 fld = w_paint_field(clump_xz, bio);
	// Keep clumps along golden-field path margins in the same sunny green-to-gold palette as the
	// surrounding field; only trim height gently near the dirt edge so they never turn into dark patches.
	float field_col_k = smoothstep(0.22, 0.72, fld.x + (clump_n.g - 0.5) * 0.26);
	float field_k = field_col_k * (1.0 - smoothstep(0.28, 0.48, trail) * 0.40);

	float path_edge = smoothstep(0.06, 0.24, trail) * (1.0 - smoothstep(0.38, 0.58, trail));
	float clump_h_var = mix(0.84, 1.16, fract(rnd.w * 5.31));
	float tall = mix(0.28, 0.48, max(bio.b * 0.45 + clump_n.b * 0.55, cot_meadow * 0.72)) * mix(0.76, 1.26, rnd.y) * clump_h_var;
	tall = mix(tall, mix(0.56, 0.96, rnd.y) * clump_h_var, field_k);
	tall *= mix(1.0, 0.68, smoothstep(0.20, 0.44, trail) * field_col_k);
	tall = mix(tall, 0.18 + 0.14 * rnd.y, forest_amt * 0.72 * (1.0 - verge_fringe * 0.75));
	tall += path_edge * (0.12 + 0.12 * rnd.x);
	// Keep summit crest turf low so the lake vista stays clear.
	tall *= mix(1.0, 0.42, smoothstep(388.0, 412.0, h));
	tall *= mix(1.0, 0.55, smoothstep(700.0, 1050.0, h));
	tall = mix(tall, mix(1.15, 2.0, rnd.y), reed_zone);

	// Outward clump fan angle (rnd.z), softened by wind swirl in tall golden fields.
	float yaw = rnd.z * 6.2831853 + clump_n.r * 1.4 * field_k;

	vec3 g_base = w_grass_color(clump_xz, h);
	float pv = w_paint_value_c(g_base, clump_xz) + (fract(rnd.w * 3.17) - 0.5) * 0.10;
	// Lift tone floor inside golden fields and along sunlit forest path verges so clumps stay
	// harmonious with the field and never read as dark dirt patches.
	float pv_eff = mix(pv, max(pv, 0.40), field_col_k);
	pv_eff = mix(pv_eff, max(pv_eff, 0.34), verge_fringe * forest_amt);
	vec3 tone = w_paint_biome_tone(g_base, h, bio, pv_eff, field_col_k, fld.y, 0.10, false);
	// Per-clump value lift keeps the near meadow reading as distinct painted tufts.
	tone *= 0.90 + 0.20 * fract(rnd.w * 7.13);

	float forest_shade = smoothstep(0.4, 0.85, bio.r) * (1.0 - verge_fringe * 0.55);
	float reed = reed_zone > 0.35 ? 1.0 : 0.0;

	vec4 bytes;
	if (t.field == 0) {
		bytes = vec4(veg_height_bytes(h, t.base_h), veg_q(dens, 255.0), veg_q(forest_shade, 3.0) + reed * 4.0);
	} else if (t.field == 1) {
		bytes = vec4(veg_q(tn.x * 0.5 + 0.5, 255.0), veg_q(tn.z * 0.5 + 0.5, 255.0), veg_q(tall / TALL_MAX, 255.0), mod(veg_q(fract(yaw / 6.2831853), 255.0), 256.0));
	} else {
		vec3 s = sqrt(clamp(tone, 0.0, 1.0));
		bytes = vec4(veg_q(s.r, 255.0), veg_q(s.g, 255.0), veg_q(s.b, 255.0), veg_q(field_k, 15.0) + veg_q(fld.y, 15.0) * 16.0);
	}
	COLOR = bytes / 255.0;
}
