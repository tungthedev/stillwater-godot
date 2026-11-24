// Stillwater's hero and mid trees (src/world/trees.js makeMaterial) on Godot.
//
// One instanced tree mesh per kind and cell. The instance transform is the game's (rotate about
// +Y, scale (s * sx, s, s * sx), stand on the ground); INSTANCE_CUSTOM.rgb is the per-tree tint.
// Mid batches set hide_in_hero: their trees whose 32 m cell draws as hero collapse to a point,
// read from the shared cell-flag texture (red = hero cell active), so every tree draws once.
//
// Lighting is Stillwater's (unshaded here): leaf alpha cut with the mip-aware coverage boost,
// procedural bark, the painterly crown tone from the crown attributes, toon sun ramp (wrap 0.48,
// lo 0.14, hi 0.56), hemisphere fill, the leaf emissive extras, aerial perspective and the post
// grade. Not ported: shadow-map sun visibility (the low tier's trees cast none and terrain casts
// none here), the night / dawn / golden-hour terms (all 0 at hour 16), the cottage light spill.
shader_type spatial;
render_mode unshaded, fog_disabled, cull_disabled, depth_draw_opaque;

#include "res://shaders/stillwater.gdshaderinc"
#include "res://shaders/atmosphere.gdshaderinc"

uniform sampler2D leaf_atlas : filter_linear_mipmap, repeat_disable;
uniform sampler2D biome_tex : filter_linear, repeat_disable;
uniform sampler2D tree_cells : filter_nearest, repeat_disable;
uniform vec2 tree_cell_origin;
uniform float hide_in_hero = 0.0;
uniform float near_size = 4096.0;
uniform float blend_start = 1828.0;
uniform float blend_end = 2028.0;
uniform float wind_strength = 0.5;

varying vec3 v_wpos;
varying vec3 v_wn;
varying vec3 v_ln;
varying vec3 v_col;
varying vec3 v_crown;

vec3 srgb_to_linear(vec3 c) {
	return mix(c / 12.92, pow((c + 0.055) / 1.055, vec3(2.4)), step(0.04045, c));
}

// common.js w_biome: the near biome map, faded to a fixed mix across the near/far blend band.
vec4 w_biome(vec2 xz) {
	vec4 b = vec4(texture(biome_tex, xz / near_size + 0.5).rgb, 0.0);
	float t = smoothstep(blend_start, blend_end, max(abs(xz.x), abs(xz.y)));
	return mix(b, vec4(0.55, 0.0, 0.3, 0.0), t);
}

void vertex() {
	vec3 ip = MODEL_MATRIX[3].xyz;
	if (hide_in_hero > 0.5 && texelFetch(tree_cells, ivec2(floor(ip.xz / 32.0) - tree_cell_origin), 0).r > 0.5) {
		VERTEX = vec3(0.0);
	} else {
		vec3 p0 = VERTEX;
		float ph = ip.x * 0.071 + ip.z * 0.053;
		float gust = textureLod(noise_tex, ip.xz * 0.011 - wind_dir * TIME * 0.045, 0.0).r;
		float amp = (0.005 + gust * 0.022) * (0.4 + wind_strength);
		float k = max(p0.y - 0.22, 0.0);
		k *= k;
		VERTEX.x += (sin(TIME * 1.1 + ph) * amp + wind_dir.x * gust * 0.022) * k;
		VERTEX.z += (cos(TIME * 0.9 + ph * 1.3) * amp + wind_dir.y * gust * 0.022) * k;
		VERTEX += NORMAL * sin(TIME * 3.0 + p0.y * 30.0 + p0.x * 20.0 + ph * 5.0) * 0.003 * k;
	}
	mat3 m = mat3(MODEL_MATRIX);
	// The crown tone uses the plain instance-rotated normal (vWorldN); lighting uses three's
	// instanced normal, divided by the squared axis scales.
	v_wn = normalize(m * NORMAL);
	v_ln = normalize(m * (NORMAL / vec3(dot(m[0], m[0]), dot(m[1], m[1]), dot(m[2], m[2]))));
	v_col = CUSTOM0.rgb * INSTANCE_CUSTOM.rgb;
	v_crown = vec3(CUSTOM0.a, CUSTOM1.x, CUSTOM1.y);
	v_wpos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	vec4 tx = texture(leaf_atlas, UV);
	vec3 dcol = srgb_to_linear(tx.rgb) * v_col;
	float a = tx.a;
	bool bark = UV.x > 0.895 || v_crown.z < 0.5;
	if (bark) {
		a = 1.0;
	} else {
		// Mip-aware coverage boost for the 1024 px leaf cluster atlas.
		vec2 tsz = UV * 1024.0;
		vec2 ddx = dFdx(tsz);
		vec2 ddy = dFdy(tsz);
		float mip = max(0.0, 0.5 * log2(max(dot(ddx, ddx), dot(ddy, ddy))));
		a *= 1.0 + mip * 0.30;
	}
	if (a < 0.44) {
		discard;
	}
	vec3 cam = CAMERA_POSITION_WORLD;
	float camD = length(v_wpos - cam);
	// Only foliage touching the lens is clipped.
	if (camD < (UV.x < 0.89 ? 2.1 : 1.0)) {
		discard;
	}

	if (bark) {
		float angB = atan(v_wn.z, v_wn.x);
		float bRidge = n_noise(vec2(angB * 5.5 + v_wpos.y * 0.32, v_wpos.y * 1.15));
		float bDeep = n_noise(vec2(angB * 13.0 + bRidge * 2.2, v_wpos.y * 2.8));
		float bFine = n_noise(vec2(angB * 24.0 + v_wpos.y * 1.4, v_wpos.y * 6.5));
		float furrow = smoothstep(0.28, 0.68, bRidge * 0.48 + bDeep * 0.36 + bFine * 0.16);
		bool isBirch = dcol.r > 0.25 && dcol.b > 0.20;
		if (isBirch) {
			float lenticel = smoothstep(0.76, 0.84, texture(noise_tex, vec2(v_wpos.x * 2.2 + v_wpos.z * 2.2, v_wpos.y * 2.8)).r);
			dcol = mix(vec3(0.76, 0.73, 0.66), vec3(0.20, 0.17, 0.15), lenticel * 0.85) * (0.85 + 0.2 * bFine);
		} else {
			vec3 bCol = mix(vec3(0.045, 0.028, 0.018), vec3(0.18, 0.115, 0.068), smoothstep(0.15, 0.55, furrow));
			bCol = mix(bCol, vec3(0.32, 0.22, 0.14), smoothstep(0.55, 0.88, furrow) * 0.72);
			float lichen = smoothstep(0.74, 0.84, n_noise(vec2(angB * 4.0 + 3.1, v_wpos.y * 1.6))) * smoothstep(0.42, 0.70, bDeep);
			bCol = mix(bCol, vec3(0.36, 0.42, 0.34), lichen * 0.42);
			dcol = bCol * (0.68 + 0.42 * v_crown.x);
			float hMoss = 1.0 - smoothstep(0.05, 0.34, v_crown.y + (bRidge - 0.5) * 0.14);
			float nMoss = smoothstep(0.36, 0.66, bDeep * 0.55 + texture(noise_tex, v_wpos.xz * 0.55 + v_wpos.y * 0.25).g * 0.45);
			float mossW = hMoss * nMoss * (0.45 + 0.55 * smoothstep(0.2, 0.6, w_biome(v_wpos.xz).r));
			dcol = mix(dcol, vec3(0.075, 0.24, 0.048) * (0.78 + 0.44 * bFine), mossW * 0.82);
		}
	} else {
		// Painterly crown: cool shadow side, warm lit side, dark pockets between clumps.
		vec3 Nw = normalize(v_wn);
		float sunSide = clamp(dot(Nw, sun_dir) * 0.5 + 0.5, 0.0, 1.0);
		float coreAO = clamp(v_crown.x, 0.26, 1.08);
		float topG = clamp(v_crown.y, 0.0, 1.0);
		float sprigN = n_noise(v_wpos.xz * 0.85 + v_wpos.y * 0.65);
		float litMask = smoothstep(0.20, 0.78, sunSide * 0.62 + topG * 0.28 + (sprigN - 0.5) * 0.26);
		float isWarmLeaf = smoothstep(0.82, 1.08, dcol.r / max(dcol.g, 0.01));
		vec3 coolGreen = dcol * vec3(0.46, 0.82, 1.24);
		vec3 warmSienna = dcol * vec3(0.84, 0.54, 0.34);
		vec3 shadowTone = mix(coolGreen, warmSienna, isWarmLeaf);
		vec3 warmShift = dcol * vec3(1.18, 1.22, 0.72);
		vec3 volCol = mix(shadowTone, warmShift, litMask);
		volCol *= mix(0.22, 1.18, smoothstep(0.20, 0.94, coreAO) * (0.62 + 0.38 * topG));
		float pvar = texture(noise_tex, v_wpos.xz * 0.16 + v_wpos.y * 0.12).g;
		volCol *= 0.82 + 0.34 * (pvar * 0.6 + sprigN * 0.4);
		dcol = volCol;
	}

	float sun_vis = w_cloud_shadow(v_wpos, cam);
	vec3 n = normalize(v_ln);
	float ramp = w_toon_ramp(dot(n, sun_dir), 0.48, 0.14, 0.56, camD);
	vec3 direct = ramp * light_col * sun_vis * dcol / PI;
	vec3 ind = w_indirect(n, dcol);

	vec3 emis = vec3(0.0);
	{
		vec3 Vw = normalize(v_wpos - cam);
		vec3 nW = normalize(v_wn);
		float lit = sun_vis * smoothstep(-0.02, 0.08, sun_dir.y);
		float isLeaf = step(0.5, v_crown.z);
		float back = pow(max(dot(Vw, sun_dir), 0.0), 3.6);
		float rim = pow(1.0 - abs(dot(nW, -Vw)), 2.2);
		float sunEdge = smoothstep(-0.18, 0.52, dot(nW, sun_dir));
		vec3 transTint = vec3(0.95, 1.02, 0.68);
		float edgeMask = 0.35 + 0.65 * v_crown.x;
		emis += dcol * light_col * transTint * back * 0.20 * edgeMask * lit * isLeaf;
		emis += dcol * 1.18 * light_col * rim * 0.09 * (0.35 + 0.65 * sunEdge) * lit * isLeaf;
		emis += dcol * vec3(0.84, 1.0, 0.74) * 0.036 * length(light_col) * isLeaf * (0.4 + 0.6 * v_crown.x);
	}

	vec3 lit = direct + ind + emis;
	vec3 atm_mul;
	vec3 atm_add;
	w_atmosphere(v_wpos, cam, atm_mul, atm_add);
	ALBEDO = w_grade(lit * atm_mul + atm_add, SCREEN_UV, VIEWPORT_SIZE);
}
