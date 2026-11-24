// Shared painterly grass and ground palette (round 2/3 recipe).
// Included by ground_bake_common.gdshaderinc and grass_bake_painted.gdshader so near ground
// and grass clumps pick from the exact same 4-tone short-meadow ramp and sunny green-to-gold
// tall-field ramp. Requires W_NOISE(uv), ao_spot (vec4), and w_grass_color(xz, h) defined first.

const vec3 P_T0 = vec3(0.015, 0.082, 0.044);
const vec3 P_T1 = vec3(0.028, 0.152, 0.048);
const vec3 P_T2 = vec3(0.058, 0.240, 0.052);
const vec3 P_T3 = vec3(0.135, 0.340, 0.064);

// Near painted tone coordinate for grass clumps: macro meadow value plus stretched 6-12 m brush
// strokes and a 30 m swell.
float w_paint_value_c(vec3 c, vec2 xz) {
	float v = smoothstep(0.10, 0.36, dot(c, vec3(0.30, 0.59, 0.11)));
	vec2 bq = mat2(vec2(0.86, 0.51), vec2(-0.51, 0.86)) * xz;
	float s1 = W_NOISE(vec2(bq.x * 0.020, bq.y * 0.052) + 0.27).r;
	float s2 = W_NOISE(xz * 0.0095 + 0.71).r;
	return v * 0.45 + (s1 - 0.5) * 3.0 + (s2 - 0.5) * 2.2 + 0.08;
}

// Ground-bake tone coordinate: aligned with the same brushstroke phase so clump bases blend into
// the ground, with a restrained negative-lobe swing and sunny floor so bare 25-54 m hillsides
// never drop into elongated dark P_T0 smears before the valley-bake hand-off.
float w_paint_value_ground_c(vec3 c, vec2 xz) {
	float v = smoothstep(0.10, 0.36, dot(c, vec3(0.30, 0.59, 0.11)));
	vec2 bq = mat2(vec2(0.86, 0.51), vec2(-0.51, 0.86)) * xz;
	float s1 = W_NOISE(vec2(bq.x * 0.020, bq.y * 0.052) + 0.27).r;
	float s2 = W_NOISE(xz * 0.0095 + 0.71).r;
	return clamp(v * 0.48 + (s1 - 0.5) * 1.45 + (s2 - 0.5) * 1.10 + 0.26, 0.26, 0.96);
}

// Calm far tone coordinate: macro drift only, no brush strokes, so distant slopes stay blotch-free.
float w_paint_value_far_c(vec3 c) {
	return 0.34 + 0.40 * smoothstep(0.10, 0.36, dot(c, vec3(0.30, 0.59, 0.11)));
}

// Tall golden field weight (x) and goldenness (y) from tall-meadow biome channel + broad patch noise.
// Forest margins stay short; the cottage lawn stays tall golden meadow.
vec2 w_paint_field(vec2 xz, vec4 bio) {
	vec4 patch_n = W_NOISE(xz * 0.014 + 0.63);
	float wob = W_NOISE(xz * 0.09 + 0.33).g - 0.5;
	float cot = ao_spot.z > 0.1 ? (1.0 - smoothstep(34.0, 48.0, length(xz - ao_spot.xy))) : 0.0;
	float s = bio.b * 0.62 + patch_n.r * 0.38 + wob * 0.05;
	float f = smoothstep(0.25, 0.37, s) * (1.0 - smoothstep(0.30, 0.60, bio.r));
	f = max(f, cot * 0.92);
	float gold = smoothstep(0.36, 0.66, patch_n.g + 0.12);
	return vec2(f, gold);
}

// 4-tone short-meadow ramp (P_T0..P_T3) with soft transition edge width `e` (e <= 0.45).
vec3 w_paint_tone(float x, float e) {
	float y = clamp(x, 0.0, 0.999) * 3.0;
	float i = floor(y);
	float s = smoothstep(0.5 - e, 0.5 + e, fract(y));
	vec3 a = i < 0.5 ? P_T0 : (i < 1.5 ? P_T1 : P_T2);
	vec3 b = i < 0.5 ? P_T1 : (i < 1.5 ? P_T2 : P_T3);
	return mix(a, b, s);
}

// 3-tone tall golden field blade ramp: fresh green base -> sunlit chartreuse -> hay-gold.
vec3 w_field_tone(float x, float gold, float e) {
	vec3 f0 = vec3(0.058, 0.205, 0.044);
	vec3 f1 = mix(vec3(0.130, 0.295, 0.052), vec3(0.215, 0.315, 0.056), gold);
	vec3 f2 = mix(vec3(0.245, 0.365, 0.070), vec3(0.410, 0.405, 0.088), gold);
	float y = clamp(x, 0.0, 0.999) * 2.0;
	float i = floor(y);
	float s = smoothstep(0.5 - e, 0.5 + e, fract(y));
	return i < 0.5 ? mix(f0, f1, s) : mix(f1, f2, s);
}

// Sunny green-to-gold ground ramp under tall fields so the floor reads lush and warm, not muddy olive.
vec3 w_field_ground_tone(vec3 g_base, float x, float gold, float e) {
	vec3 fg0 = vec3(0.058, 0.228, 0.048);
	vec3 fg1 = mix(vec3(0.118, 0.318, 0.056), vec3(0.180, 0.348, 0.064), gold);
	vec3 fg2 = mix(vec3(0.205, 0.382, 0.072), vec3(0.305, 0.405, 0.082), gold);
	float y = clamp(x, 0.0, 0.999) * 2.0;
	float i = floor(y);
	float s = smoothstep(0.5 - e, 0.5 + e, fract(y));
	vec3 fg = i < 0.5 ? mix(fg0, fg1, s) : mix(fg1, fg2, s);
	return mix(fg, g_base * vec3(0.96, 1.04, 0.92), 0.42);
}

// Biome palette hook: blends short 4-tone painted meadow and tall golden fields, with per-biome
// hooks (forest moss, wildflower swath, alpine sage). Ground bakes skip the forest_edge darken
// because ground_bake_common applies its own forest canopy blend and shade pass right after.
vec3 w_paint_biome_tone(vec3 g_base, float h, vec4 bio, float pv, float field_k, float gold, float edge, bool is_ground) {
	vec3 short_tone = w_paint_tone(pv, edge);
	vec3 field_tone = is_ground
			? w_field_ground_tone(g_base, pv + 0.12, gold, edge + 0.02)
			: w_field_tone(pv + 0.15, gold, edge + 0.02);
	vec3 tone = mix(short_tone, field_tone, field_k);
	float forest_edge = smoothstep(0.20, 0.65, bio.r);
	if (!is_ground) {
		tone = mix(tone, tone * vec3(0.78, 0.94, 0.88), forest_edge * 0.42);
	}
	float bloom_meadow = smoothstep(0.25, 0.72, bio.g) * (1.0 - forest_edge);
	tone = mix(tone, tone * vec3(1.06, 1.04, 0.94), bloom_meadow * 0.22);
	float alpine = smoothstep(620.0, 1020.0, h);
	tone = mix(tone, mix(vec3(0.14, 0.22, 0.12), vec3(0.34, 0.38, 0.18), clamp(pv, 0.0, 1.0)), alpine * 0.65);
	return tone;
}
