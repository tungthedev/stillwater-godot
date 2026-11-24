// Stillwater's wildflower bake (src/world/grass.js FLOWER_BAKE_FRAG): two RGBA8 texels per flower,
//   field 0: height lo, height hi, density, species (0 daisy, 1 buttercup, 2 lupine spike, 3 pink)
//   field 1: local grass top (/ 2.2 m), 0, 0, 0
// Stillwater's flower texel keeps a reserved style bit that its shaders never read; it is dropped.
// The cottage dooryard mask (w_yard) is left out as in grass_bake.gdshader.
shader_type canvas_item;
render_mode blend_disabled;

#include "res://shaders/stillwater.gdshaderinc"
#include "res://shaders/veg_bake.gdshaderinc"
#include "res://shaders/world.gdshaderinc"

void fragment() {
	VegTexel t;
	if (!veg_texel(FRAGCOORD.xy, t)) {
		discard;
	}
	vec2 xz = t.xz;
	vec4 rnd = t.rnd;

	float h = w_height(xz);
	vec3 tn = w_normal(xz, 1.0);
	vec4 bio = w_biome(xz);
	float trail = abs(w_trail_raw(xz));

	vec4 drift = W_NOISE(xz * 0.011 + 0.29);
	float clump = W_NOISE(xz * 0.058 + rnd.z * 0.05).g;
	float bouquet = W_NOISE(xz * 0.22 + 0.41).r;
	float cl_mask = smoothstep(0.46, 0.76, clump * 0.68 + bouquet * 0.32);
	float cot_fl = ao_spot.z > 0.1 ? (1.0 - smoothstep(26.0, 44.0, length(xz - ao_spot.xy))) * smoothstep(0.48, 0.76, clump) * 0.58 : 0.0;
	float pasture_daisy = bio.b * (1.0 - smoothstep(0.15, 0.45, bio.r)) * smoothstep(0.54, 0.80, clump) * 0.48;
	float alpine_bloom = smoothstep(320.0, 405.0, h) * (1.0 - smoothstep(0.20, 0.55, bio.r)) * smoothstep(0.46, 0.76, clump) * 0.65;
	float dens = max(max(bio.g * cl_mask * (0.85 + 0.35 * drift.r), cot_fl), max(pasture_daisy, alpine_bloom));
	dens *= smoothstep(0.48, 0.74, tn.y) * (1.0 - smoothstep(0.06, 0.34, trail));
	dens *= smoothstep(water_level + 0.4, water_level + 1.5, h);

	float sp = clamp(drift.b * 1.45 - 0.22 + (drift.g - 0.5) * 0.35, 0.0, 0.999);
	float kind = rnd.x < 0.88 ? floor(sp * 4.0) : floor(fract(rnd.x * 9.3) * 4.0);
	if (t.field == 1) {
		// Typical drawn grass-blade height at this root, so heads can clear the sward: the per-spot
		// terms of the grass bake with per-blade randoms at their mean; reeds and plumes left out.
		float g_cot = ao_spot.z > 0.1 ? (1.0 - smoothstep(32.0, 52.0, length(xz - ao_spot.xy))) : 0.0;
		float g_forest = smoothstep(0.28, 0.66, bio.r) * (1.0 - g_cot);
		vec4 g_clump_n = W_NOISE(xz * 0.055 + 0.19);
		vec4 g_patch_n = W_NOISE(xz * 0.014 + 0.63);
		float g_clump = smoothstep(0.12, 0.78, g_clump_n.g * 0.65 + g_patch_n.r * 0.35);
		float g_dens = smoothstep(0.30, 0.58, tn.y);
		g_dens *= 1.0 - smoothstep(0.28, 0.60, trail);
		g_dens *= smoothstep(water_level + 0.15, water_level + 1.0, h);
		g_dens *= mix(1.0, 0.04, smoothstep(0.36, 0.74, g_forest));
		g_dens *= max(smoothstep(0.05, 0.30, g_clump_n.g + 0.28), g_cot * 0.85);
		float g_path_edge = smoothstep(0.04, 0.22, trail) * (1.0 - smoothstep(0.28, 0.46, trail));
		float g_tall = mix(0.20, 0.60, max(bio.b * 0.55 + g_clump * 0.55, g_cot * 0.78)) * 1.02;
		g_tall = mix(g_tall, 0.21, g_forest * 0.72);
		g_tall += g_path_edge * 0.30;
		g_tall *= mix(1.0, 0.42, smoothstep(388.0, 412.0, h));
		g_tall *= mix(1.0, 0.55, smoothstep(700.0, 1050.0, h));
		float grass_top = clamp(g_tall * g_dens, 0.0, 0.8);
		COLOR = vec4(veg_q(grass_top / 2.2, 255.0), 0.0, 0.0, 0.0) / 255.0;
	} else {
		COLOR = vec4(veg_height_bytes(h, t.base_h), veg_q(dens, 255.0), clamp(kind, 0.0, 3.0)) / 255.0;
	}
}
