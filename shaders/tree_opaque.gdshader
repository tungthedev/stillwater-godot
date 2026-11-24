// Opaque tree geometry (trunks, boughs, hero/mid1 inner foliage cores, and mid0 round puffs).
// Drawn BEFORE alpha-tested leaf cards (render_priority = -1, cull_back, no discard) so hardware
// early-Z rejects rear leaf-card fragments behind solid cores, puffs and trunks.
// Vertex shader stays lightweight (no atmosphere/cloud-shadow per vertex across 100k+ core/puff
// vertices); in painterly mode mid-distance puffs get a subtle watertight vertex lumpiness and
// fragment shading uses a noise-shifted sharp 3-tone flat ramp with a darker silhouette rim.
shader_type spatial;
render_mode unshaded, fog_disabled, cull_back, depth_draw_opaque;

#include "res://shaders/stillwater.gdshaderinc"
#include "res://shaders/atmosphere.gdshaderinc"

uniform sampler2D biome_tex : filter_linear, repeat_disable;
uniform sampler2D tree_cells : filter_nearest, repeat_disable;
uniform vec2 tree_cell_origin;
uniform float hide_in_hero = 0.0;
uniform float near_size = 4096.0;
uniform float blend_start = 1828.0;
uniform float blend_end = 2028.0;
uniform float wind_strength = 0.5;

varying vec3 v_wpos;
varying vec3 v_lpos;
varying vec3 v_seed_vis;
varying vec3 v_wn;
varying vec3 v_ln;
varying vec3 v_col;
varying vec3 v_crown;

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
		v_wpos = ip;
		v_lpos = vec3(0.0);
		v_seed_vis = vec3(0.0, 0.0, 1.0);
		v_wn = vec3(0.0, 1.0, 0.0);
		v_ln = vec3(0.0, 1.0, 0.0);
		v_col = vec3(0.0);
		v_crown = vec3(0.0);
	} else {
		vec3 p0 = VERTEX;
		if (painterly > 0.5 && hide_in_hero > 0.5 && CUSTOM1.y >= 0.5 && UV.x <= 0.895) {
			// Cheap per-instance watertight vertex lumpiness breaks remaining sphere silhouettes on
			// mid puffs with zero extra geometry and zero fragment cost.
			float lump = sin(p0.x * 15.0 + p0.z * 11.0 + ip.x * 0.71) * cos(p0.y * 14.0 - p0.z * 9.0 + ip.z * 0.53);
			VERTEX += NORMAL * (lump * 0.022);
		}
		float ph = ip.x * 0.071 + ip.z * 0.053;
		float gust = textureLod(noise_tex, ip.xz * 0.011 - wind_dir * TIME * 0.045, 0.0).r;
		float amp = (0.005 + gust * 0.022) * (0.4 + wind_strength);
		float k = max(p0.y - 0.22, 0.0);
		k *= k;
		VERTEX.x += (sin(TIME * 1.1 + ph) * amp + wind_dir.x * gust * 0.022) * k;
		VERTEX.z += (cos(TIME * 0.9 + ph * 1.3) * amp + wind_dir.y * gust * 0.022) * k;
		VERTEX += NORMAL * sin(TIME * 3.0 + p0.y * 30.0 + p0.x * 20.0 + ph * 5.0) * 0.003 * k;

		mat3 m = mat3(MODEL_MATRIX);
		v_wn = w_normalize(m * NORMAL);
		v_ln = w_normalize(m * (NORMAL / vec3(dot(m[0], m[0]), dot(m[1], m[1]), dot(m[2], m[2]))));
		v_col = CUSTOM0.rgb * INSTANCE_CUSTOM.rgb;
		v_crown = vec3(CUSTOM0.a, CUSTOM1.x, CUSTOM1.y);
		v_lpos = p0;
		// Cloud shadows span hundreds of metres, so evaluating once per tree origin in vertex()
		// stays cache-coherent across all tree vertices and removes 2 noise_tex fetches per pixel.
		float sun_vis = w_cloud_shadow_v(ip + vec3(0.0, 5.0, 0.0), CAMERA_POSITION_WORLD);
		v_seed_vis = vec3(fract(vec2(ip.x * 0.137 + ip.z * 0.091, ip.z * 0.173 - ip.x * 0.067)), sun_vis);
		v_wpos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	}
}

void fragment() {
	vec3 cam = CAMERA_POSITION_WORLD;
	float camD = length(v_wpos - cam);
	bool bark = UV.x > 0.895 || v_crown.z < 0.5;
	vec3 dcol;
	vec3 base_albedo;

	if (bark) {
		// Cheap painterly bark: one tileable noise_tex sample wrapped seamlessly around the trunk
		// via cylindrical angle (8 cycles / 2*pi wraps cleanly) and stretched vertically.
		// atan(0, 0) is undefined (a flat trunk cap facing straight up).
		float angB = abs(v_wn.x) + abs(v_wn.z) > 1e-7 ? atan(v_wn.z, v_wn.x) : 0.0;
		vec2 buv = vec2(angB * (8.0 / TAU) + v_wpos.y * 0.05, v_wpos.y * 0.25);
		vec4 bn = texture(noise_tex, buv);
		bool isBirch = v_col.r > 0.42 && v_col.b > 0.36;
		if (isBirch) {
			float lenticel = smoothstep(0.72, 0.82, texture(noise_tex, vec2(angB * (3.0 / TAU), v_wpos.y * 0.65)).r);
			dcol = mix(vec3(0.76, 0.73, 0.66), vec3(0.20, 0.17, 0.15), lenticel * 0.82) * (0.86 + 0.18 * bn.b);
		} else {
			float furrow = smoothstep(0.30, 0.68, bn.r * 0.46 + bn.g * 0.36 + bn.b * 0.18);
			vec3 bCol = mix(vec3(0.045, 0.028, 0.018), vec3(0.18, 0.115, 0.068), smoothstep(0.14, 0.54, furrow));
			bCol = mix(bCol, vec3(0.32, 0.22, 0.14), smoothstep(0.54, 0.88, furrow) * 0.72);
			float lichen = smoothstep(0.72, 0.84, bn.a) * smoothstep(0.42, 0.70, bn.g);
			bCol = mix(bCol, vec3(0.36, 0.42, 0.34), lichen * 0.40);
			dcol = bCol * (0.68 + 0.42 * v_crown.x);
			float hMoss = 1.0 - smoothstep(0.05, 0.34, v_crown.y + (bn.r - 0.5) * 0.14);
			if (hMoss > 0.01) {
				float nMoss = smoothstep(0.36, 0.66, bn.g * 0.60 + bn.r * 0.40);
				float mossW = hMoss * nMoss * (0.45 + 0.55 * smoothstep(0.2, 0.6, w_biome(v_wpos.xz).r));
				dcol = mix(dcol, vec3(0.075, 0.24, 0.048) * (0.78 + 0.44 * bn.b), mossW * 0.82);
			}
		}
		base_albedo = dcol;
	}
	float sun_vis = v_seed_vis.z;
	vec3 lit;
	if (bark || painterly < 0.5) {
		if (!bark) {
			// Classic Stillwater foliage shading (?style=classic).
			base_albedo = v_col;
			vec3 Nw = w_normalize(v_wn);
			float sunSide = clamp(dot(Nw, sun_dir) * 0.5 + 0.5, 0.0, 1.0);
			float coreAO = clamp(v_crown.x, 0.26, 1.08);
			float topG = clamp(v_crown.y, 0.0, 1.0);
			vec4 nv1 = texture(noise_tex, vec2(v_lpos.x * 2.2 - v_lpos.z * 1.5, v_lpos.y * 2.4 + v_lpos.z * 1.1) + v_seed_vis.xy);
			float litMask = smoothstep(0.20, 0.78, sunSide * 0.62 + topG * 0.28 + (nv1.b - 0.5) * 0.22);
			float isWarmLeaf = smoothstep(0.82, 1.08, base_albedo.r / max(base_albedo.g, 0.01));
			vec3 coolGreen = base_albedo * vec3(0.46, 0.82, 1.24);
			vec3 warmSienna = base_albedo * vec3(0.84, 0.54, 0.34);
			vec3 shadowTone = mix(coolGreen, warmSienna, isWarmLeaf);
			vec3 warmShift = base_albedo * vec3(1.18, 1.22, 0.72);
			vec3 volCol = mix(shadowTone, warmShift, litMask);
			volCol *= mix(0.22, 1.18, smoothstep(0.20, 0.94, coreAO) * (0.62 + 0.38 * topG));
			dcol = volCol * (0.82 + 0.34 * (nv1.g * 0.6 + nv1.b * 0.4)) * vec3(0.68, 0.74, 0.60);
			base_albedo *= vec3(0.68, 0.74, 0.60);
		}
		vec3 n = w_normalize(v_ln);
		float ramp = w_toon_ramp(dot(n, sun_dir), 0.48, 0.14, 0.56, camD);
		vec3 direct = ramp * light_col * sun_vis * dcol / PI;
		vec3 ind = w_indirect(n, dcol);
		vec3 emis = vec3(0.0);
		if (!bark) {
			vec3 Vw = w_normalize(v_wpos - cam);
			vec3 nW = w_normalize(v_wn);
			float lit_s = sun_vis * smoothstep(-0.02, 0.08, sun_dir.y);
			float back = pow(max(dot(Vw, sun_dir), 0.0), 3.6);
			float rim = pow(max(1.0 - abs(dot(nW, -Vw)), 0.0), 2.2);
			float sunEdge = smoothstep(-0.18, 0.52, dot(nW, sun_dir));
			float edgeMask = 0.35 + 0.65 * v_crown.x;
			emis += dcol * light_col * vec3(0.95, 1.02, 0.68) * back * 0.20 * edgeMask * lit_s;
			emis += dcol * 1.18 * light_col * rim * 0.09 * (0.35 + 0.65 * sunEdge) * lit_s;
			emis += dcol * vec3(0.84, 1.0, 0.74) * 0.036 * length(light_col) * (0.4 + 0.6 * v_crown.x);
		}
		lit = w_light_floor(direct + ind + emis, base_albedo);
	} else {
		// Painterly opaque foliage (mid0 puffs and hero/mid1 inner cores): zero discard, zero extra
		// geometry. Two-scale object-space leaf-clump noise (~4-7 clumps per puff; noise_tex ch b/a
		// carry ~7 cycles/tile with mean ~0.56, stddev ~0.12) perturbs the normal and shifts a sharp
		// cluster terminator across a 3-tone flat gouache ramp, with a darker non-shiny rim.
		base_albedo = v_col;
		float topG = clamp(v_crown.y, 0.0, 1.0);
		vec4 nv1 = texture(noise_tex, vec2(v_lpos.x * 2.8 - v_lpos.z * 2.0, v_lpos.y * 3.1 + v_lpos.z * 1.6) + v_seed_vis.xy);
		vec4 nv2 = texture(noise_tex, vec2(v_lpos.x * 5.6 + v_lpos.z * 3.8, v_lpos.y * 6.0 - v_lpos.z * 3.0) + v_seed_vis.xy * 1.7);
		float clump_s = clamp(((nv1.a * 0.58 + nv1.b * 0.42) - 0.56) * 4.2, -1.0, 1.0);
		float sprig_s = clamp(((nv2.a * 0.58 + nv2.b * 0.42) - 0.56) * 4.2, -1.0, 1.0);

		// Zero-mean bumpy normal per clump so each cluster catches its own lit side, then shift
		// the wrapped light terminator sharply by clump + sprig noise.
		vec3 n = w_normalize(v_ln);
		vec3 n_bump = w_normalize(n + (nv1.rgb - vec3(0.58, 0.55, 0.52)) * 1.15);
		float ndl_w = clamp((dot(n_bump, sun_dir) + 0.65) / 1.65, 0.0, 1.0);
		float L_val = ndl_w * 0.64 + topG * 0.22 + clump_s * 0.28 + sprig_s * 0.14;
		float band_mid = smoothstep(0.26, 0.34, L_val);
		float band_lit = smoothstep(0.56, 0.64, L_val);

		// 3-tone flat ramp (cool blue-green shadow / mid foliage / warm yellow-green highlight),
		// calibrated to hero leaf-card hue and value with no smooth multiplicative AO gradient.
		float isWarmLeaf = smoothstep(0.82, 1.08, base_albedo.r / max(base_albedo.g, 0.01));
		vec3 shadowTone = mix(base_albedo * vec3(0.48, 0.74, 0.98), base_albedo * vec3(0.70, 0.46, 0.30), isWarmLeaf);
		vec3 midTone = base_albedo * vec3(0.70, 0.78, 0.58);
		vec3 litTone = base_albedo * vec3(1.00, 1.08, 0.56);
		dcol = mix(mix(shadowTone, midTone, band_mid), litTone, band_lit);
		base_albedo *= vec3(0.68, 0.74, 0.60);

		float ramp = mix(mix(0.22, 0.58, band_mid), 1.0, band_lit);
		vec3 direct = ramp * light_col * sun_vis * dcol / PI;
		// Quantise indirect hemisphere fill to the same flat bands so smooth n.y does not wash them out.
		float ind_y = mix(mix(0.05, 0.45, band_mid), 0.75, band_lit);
		vec3 ind = w_indirect(vec3(0.0, ind_y, 0.0), dcol);

		// Darker foliage silhouette rim (~0.84x at grazing edge, replacing glossy Fresnel); keep
		// subtle back-light only on the lit side.
		vec3 Vw = w_normalize(v_wpos - cam);
		vec3 nW = w_normalize(v_wn);
		float ndv = abs(dot(nW, -Vw));
		float rim_dark = mix(1.0, 0.84, w_rstep(0.42, 0.10, ndv) * (0.65 + 0.35 * (0.5 - clump_s * 0.5)));
		float lit_s = sun_vis * smoothstep(-0.02, 0.08, sun_dir.y);
		float b0 = max(dot(Vw, sun_dir), 0.0);
		float back = b0 * b0;
		back *= back;
		vec3 emis = dcol * light_col * vec3(0.95, 1.02, 0.68) * back * 0.14 * band_mid * lit_s;

		lit = w_light_floor((direct + ind) * rim_dark + emis, base_albedo);
	}
	vec3 atm_mul;
	vec3 atm_add;
	w_atmosphere(v_wpos, cam, atm_mul, atm_add);
	ALBEDO = w_grade(lit * atm_mul + atm_add, SCREEN_UV, VIEWPORT_SIZE);
}
