// Alpha-tested tree leaf cards (Surface 1 of hero and near-mid1 meshes).
// Drawn AFTER opaque cores, puffs and trunks (render_priority = 0) so early depth rejects cards
// behind solid cores. Uses spherical crown-dome normals (NORMAL) for soft volumetric shading, and
// the geometric card face normal (CUSTOM1.yzw) + quad centre offset (CUSTOM2.xyz) for Genshin-style
// edge-on card shrinking/fading that removes flat overlapping card edges.
// Crown lighting, cloud shadow and atmosphere are evaluated per vertex so alpha-tested fragments
// stay minimal (one leaf_atlas read + cutout + grade).
shader_type spatial;
render_mode unshaded, fog_disabled, cull_disabled, depth_draw_opaque;

#include "res://shaders/stillwater.gdshaderinc"
#include "res://shaders/atmosphere.gdshaderinc"

uniform sampler2D leaf_atlas : filter_linear_mipmap, repeat_disable;
uniform sampler2D tree_cells : filter_nearest, repeat_disable;
uniform vec2 tree_cell_origin;
uniform float hide_in_hero = 0.0;
uniform float wind_strength = 0.5;

varying vec3 v_lit;
varying vec3 v_atm_mul;
varying vec3 v_atm_add;
varying float v_cam_d;
varying float v_alpha_cut;

void vertex() {
	vec3 ip = MODEL_MATRIX[3].xyz;
	if (hide_in_hero > 0.5 && texelFetch(tree_cells, ivec2(floor(ip.xz / 32.0) - tree_cell_origin), 0).r > 0.5) {
		VERTEX = vec3(0.0);
		v_lit = vec3(0.0);
		v_atm_mul = vec3(1.0);
		v_atm_add = vec3(0.0);
		v_cam_d = 0.0;
		v_alpha_cut = 1.0;
	} else {
		mat3 m = mat3(MODEL_MATRIX);
		vec3 inv_s2 = vec3(dot(m[0], m[0]), dot(m[1], m[1]), dot(m[2], m[2]));
		vec3 card_off = CUSTOM2.xyz;
		vec3 card_center = VERTEX - card_off;
		vec3 w_face_n = w_normalize(m * (CUSTOM1.yzw / inv_s2));
		vec3 w_center = (MODEL_MATRIX * vec4(card_center, 1.0)).xyz;
		vec3 cam = CAMERA_POSITION_WORLD;
		vec3 to_cam = w_normalize(cam - w_center);
		float ndv = abs(dot(w_face_n, to_cam));
		// Genshin edge-on card fade: collapse grazing leaf cards completely to zero area so
		// edge-on slivers never float in open sky or waste fragment overdraw. Visible cards stay
		// >= 72% scale so no card ever shrinks into a detached thin line. Conifers (CUSTOM2.w > 0.5)
		// carry horizontal drooping boughs so they use a narrower collapse band.
		float is_conifer = CUSTOM2.w;
		float lo = mix(0.32, 0.12, is_conifer);
		float hi = mix(0.48, 0.24, is_conifer);
		float shrink = 1.0;
		if (painterly > 0.5) {
			shrink = ndv < lo ? 0.0 : mix(mix(0.72, 0.76, is_conifer), 1.0, smoothstep(lo, hi, ndv));
		}
		vec3 p0 = card_center + card_off * shrink;
		VERTEX = p0;
		float ph = ip.x * 0.071 + ip.z * 0.053;
		float gust = textureLod(noise_tex, ip.xz * 0.011 - wind_dir * TIME * 0.045, 0.0).r;
		float amp = (0.005 + gust * 0.022) * (0.4 + wind_strength);
		float k = max(p0.y - 0.22, 0.0);
		k *= k;
		VERTEX.x += (sin(TIME * 1.1 + ph) * amp + wind_dir.x * gust * 0.022) * k;
		VERTEX.z += (cos(TIME * 0.9 + ph * 1.3) * amp + wind_dir.y * gust * 0.022) * k;
		VERTEX += NORMAL * sin(TIME * 3.0 + p0.y * 30.0 + p0.x * 20.0 + ph * 5.0) * 0.003 * k * shrink;

		vec3 wpos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
		float camD = length(wpos - cam);
		v_cam_d = camD;
		float cut_hi = mix(0.50, 0.46, is_conifer);
		v_alpha_cut = painterly > 0.5 ? mix(cut_hi, 0.44, smoothstep(lo, hi, ndv)) : 0.44;
		w_atmosphere(wpos, cam, v_atm_mul, v_atm_add);

		// Spherical crown-dome volumetric lighting evaluated per vertex.
		vec3 wn = w_normalize(m * NORMAL);
		vec3 ln = w_normalize(m * (NORMAL / inv_s2));
		vec3 base_alb = CUSTOM0.rgb * INSTANCE_CUSTOM.rgb;
		float coreAO = clamp(CUSTOM0.a, 0.26, 1.08);
		float topG = clamp(CUSTOM1.x, 0.0, 1.0);
		vec4 nv = textureLod(noise_tex, wpos.xz * 0.16 + wpos.y * 0.12, 0.0);
		float sunSide = clamp(dot(wn, sun_dir) * 0.5 + 0.5, 0.0, 1.0);
		float litMask = smoothstep(0.20, 0.78, sunSide * 0.62 + topG * 0.28 + (nv.b - 0.5) * 0.22);
		float isWarmLeaf = smoothstep(0.82, 1.08, base_alb.r / max(base_alb.g, 0.01));
		vec3 coolGreen = base_alb * (painterly > 0.5 ? vec3(0.54, 0.88, 1.22) : vec3(0.46, 0.82, 1.24));
		vec3 warmSienna = base_alb * vec3(0.84, 0.54, 0.34);
		vec3 shadowTone = mix(coolGreen, warmSienna, isWarmLeaf);
		vec3 warmShift = base_alb * vec3(1.18, 1.22, 0.72);
		vec3 volCol = mix(shadowTone, warmShift, litMask);
		float ao_lo = painterly > 0.5 ? 0.52 : 0.22;
		float top_k = painterly > 0.5 ? (0.68 + 0.32 * topG) : (0.62 + 0.38 * topG);
		volCol *= mix(ao_lo, 1.18, smoothstep(0.20, 0.94, coreAO) * top_k);
		volCol *= painterly > 0.5 ? (0.88 + 0.24 * (nv.g * 0.6 + nv.b * 0.4)) : (0.82 + 0.34 * (nv.g * 0.6 + nv.b * 0.4));

		float sun_vis = w_cloud_shadow_v(wpos, cam);
		float ramp = w_toon_ramp(dot(ln, sun_dir), 0.48, 0.14, 0.56, camD);
		vec3 direct = ramp * light_col * sun_vis * volCol / PI;
		vec3 ind = w_indirect(ln, volCol);
		vec3 Vw = w_normalize(wpos - cam);
		float lit_s = sun_vis * smoothstep(-0.02, 0.08, sun_dir.y);
		float back = pow(max(dot(Vw, sun_dir), 0.0), 3.6);
		float rim = pow(max(1.0 - abs(dot(wn, -Vw)), 0.0), 2.2);
		float sunEdge = smoothstep(-0.18, 0.52, dot(wn, sun_dir));
		vec3 transTint = vec3(0.95, 1.02, 0.68);
		float edgeMask = 0.35 + 0.65 * coreAO;
		float back_k = painterly > 0.5 ? 0.16 : 0.20;
		float rim_k = painterly > 0.5 ? 0.045 : 0.09;
		float bounce_k = painterly > 0.5 ? 0.042 : 0.036;
		vec3 emis = volCol * light_col * transTint * back * back_k * edgeMask * lit_s
			+ volCol * 1.18 * light_col * rim * rim_k * (0.35 + 0.65 * sunEdge) * lit_s
			+ volCol * vec3(0.84, 1.0, 0.74) * bounce_k * length(light_col) * (0.4 + 0.6 * coreAO);
		v_lit = w_light_floor(direct + ind + emis, base_alb);
	}
}

void fragment() {
	if (v_cam_d < 2.1) {
		discard;
	}
	vec4 tx = texture(leaf_atlas, UV);
	// Mip-aware coverage boost for the 1024 px leaf cluster atlas.
	vec2 tsz = UV * 1024.0;
	vec2 ddx = dFdx(tsz);
	vec2 ddy = dFdy(tsz);
	float mip = max(0.0, 0.5 * log2(max(max(dot(ddx, ddx), dot(ddy, ddy)), 1e-12)));
	if (tx.a * (1.0 + mip * 0.30) < v_alpha_cut) {
		discard;
	}
	vec3 lit = v_lit * (tx.rgb * tx.rgb);
	ALBEDO = w_grade(lit * v_atm_mul + v_atm_add, SCREEN_UV, VIEWPORT_SIZE);
}
