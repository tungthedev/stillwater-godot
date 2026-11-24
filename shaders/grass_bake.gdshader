// Stillwater's grass bake (src/world/grass.js GRASS_BAKE_FRAG): the static per-blade fields,
// computed once when a tile enters the ring. Stillwater packs them into one RGBA32UI texel;
// RGBA8 is what a Web SubViewport gives, so they take three texels at the same precision except
// height (16 bits over 64 m above the tile's base instead of 20 bits absolute, 1 mm either way):
//   field 0: height lo, height hi, density, forest shade (2 bits) | shore reed << 2
//   field 1: normal x, normal z, static tallness (/ 2.2 m), yaw (/ 2 pi)
//   field 2: base colour r, g, b (sqrt-encoded), dry tip (4 bits) | hollow << 4
// The cottage dooryard mask (w_yard) is left out: the yard lies outside the 30 m grass ring at
// both bench poses.
shader_type canvas_item;
render_mode blend_disabled;

#include "res://shaders/stillwater.gdshaderinc"
#include "res://shaders/veg_bake.gdshaderinc"
#include "res://shaders/world.gdshaderinc"

const float TALL_MAX = 2.2;

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

	float dens = smoothstep(0.30, 0.58, tn.y);
	// Uneven trampled verge creeping onto soft dirt trail margins.
	dens *= 1.0 - smoothstep(0.28, 0.60, trail + (rnd.x - 0.5) * 0.30);
	float reed_zone = (1.0 - smoothstep(0.2, 0.9, abs(h - water_level + 0.1))) * smoothstep(0.52, 0.74, W_NOISE(xz * 0.035 + 0.4).r);
	dens *= max(smoothstep(water_level + 0.15, water_level + 1.0, h), reed_zone);
	dens *= 1.0 - smoothstep(1050.0, 1300.0, h);
	// Keep the cottage lawn lush while suppressing sparse blades under dense forest canopy.
	float cot_meadow = ao_spot.z > 0.1 ? (1.0 - smoothstep(32.0, 52.0, length(xz - ao_spot.xy))) : 0.0;
	float forest_amt = smoothstep(0.28, 0.66, bio.r) * (1.0 - cot_meadow);
	dens *= mix(1.0, 0.04, smoothstep(0.36, 0.74, forest_amt));

	vec4 clump_n = W_NOISE(xz * 0.055 + 0.19);
	vec4 patch_n = W_NOISE(xz * 0.014 + 0.63);
	float clump = smoothstep(0.12, 0.78, clump_n.g * 0.65 + patch_n.r * 0.35);
	dens *= max(smoothstep(0.05, 0.30, clump_n.g + 0.28), cot_meadow * 0.85);

	float path_edge = smoothstep(0.04, 0.22, trail) * (1.0 - smoothstep(0.28, 0.46, trail));
	float plume = step(0.80, rnd.y) * smoothstep(0.42, 0.72, clump_n.a);
	float tall = mix(0.20, 0.60, max(bio.b * 0.55 + clump * 0.55, cot_meadow * 0.78)) * mix(0.62, 1.42, rnd.y);
	tall = mix(tall, 0.14 + 0.14 * rnd.y, forest_amt * 0.72);
	tall += path_edge * (0.18 + 0.24 * rnd.x) + plume * 0.30 * (1.0 - forest_amt * 0.7);
	// Keep summit crest turf low so the lake vista stays clear.
	tall *= mix(1.0, 0.42, smoothstep(388.0, 412.0, h));
	tall *= mix(1.0, 0.55, smoothstep(700.0, 1050.0, h));
	tall = mix(tall, mix(1.15, 2.0, rnd.y), reed_zone);

	float yaw = rnd.z * 6.2831853 + clump_n.r * 2.5;
	vec3 gcol = w_grass_color(xz, h);
	float hollow = smoothstep(0.48, 0.78, patch_n.b);
	float dry_tip = smoothstep(0.46, 0.82, patch_n.g + rnd.y * 0.35 + plume * 0.52);
	float forest_shade = smoothstep(0.4, 0.85, bio.r);
	float reed = reed_zone > 0.35 ? 1.0 : 0.0;

	vec4 bytes;
	if (t.field == 0) {
		bytes = vec4(veg_height_bytes(h, t.base_h), veg_q(dens, 255.0), veg_q(forest_shade, 3.0) + reed * 4.0);
	} else if (t.field == 1) {
		bytes = vec4(veg_q(tn.x * 0.5 + 0.5, 255.0), veg_q(tn.z * 0.5 + 0.5, 255.0), veg_q(tall / TALL_MAX, 255.0), mod(veg_q(fract(yaw / 6.2831853), 255.0), 256.0));
	} else {
		vec3 s = sqrt(clamp(gcol, 0.0, 1.0));
		bytes = vec4(veg_q(s.r, 255.0), veg_q(s.g, 255.0), veg_q(s.b, 255.0), veg_q(dry_tip, 15.0) + veg_q(hollow, 15.0) * 16.0);
	}
	COLOR = bytes / 255.0;
}
