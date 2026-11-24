// Matte painted cottage, village & props shader (W3):
// Vertex-colored matte painted albedo with subtle brushstroke variation, baked per-part contact AO
// in COLOR.a, cool blue-violet shadows via w_indirect, warm sun wrap, and horizon-matched fog.
// UV.x >= 0.5 selects window/lantern glass (cozy slate-blue with warm undertone by day, glowing
// honey-amber when night_glow > 0 in W5). Opaque, zero discard, render_priority = -1.
shader_type spatial;
render_mode unshaded, fog_disabled, cull_back, depth_draw_opaque;

#include "res://shaders/stillwater.gdshaderinc"
#include "res://shaders/atmosphere.gdshaderinc"

uniform float night_glow = 0.0;

varying vec3 v_wpos;
varying vec3 v_wn;
varying vec4 v_col; // rgb: linear albedo, a: contact/eave AO
varying vec3 v_atm_mul;
varying vec3 v_atm_add;
varying vec3 v_meta; // x: mat_kind (0 prop, 1 glass), y: sun_vis, z: cam dist

void vertex() {
	vec3 wp = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	vec3 cam = CAMERA_POSITION_WORLD;
	mat3 m = mat3(MODEL_MATRIX);
	vec3 inv_sq = vec3(
		1.0 / max(dot(m[0], m[0]), 1e-12),
		1.0 / max(dot(m[1], m[1]), 1e-12),
		1.0 / max(dot(m[2], m[2]), 1e-12)
	);
	v_wn = w_normalize(m * (NORMAL * inv_sq));
	v_wpos = wp;
	// Read vertex color + AO from CUSTOM0 (float RGBA) so both MeshInstance3D and SwapMultiMesh
	// (MultiMeshInstance3D in GLES3 Compatibility, where COLOR is bound to instance color) match.
	v_col = CUSTOM0;
	float sun_vis = w_cloud_shadow_v(wp + vec3(0.0, 2.0, 0.0), cam);
	v_meta = vec3(UV.x, sun_vis, length(wp - cam));

	vec3 atm_mul;
	vec3 atm_add;
	w_atmosphere(wp, cam, atm_mul, atm_add);
	v_atm_mul = atm_mul;
	v_atm_add = atm_add;
}

void fragment() {
	vec3 n = w_normalize(v_wn);
	vec3 lit;

	if (v_meta.x > 1.25) {
		// Campfire embers & hearth coals: charred glowing bed by day, bright flickering firelight at dusk/night.
		float pulse = 0.86 + 0.14 * sin(TIME * 6.5 + v_wpos.x * 5.0 + v_wpos.z * 4.3);
		vec3 coal = vec3(0.18, 0.08, 0.05);
		vec3 ember = vec3(1.45, 0.56, 0.14) * pulse * (0.45 + night_glow * 2.15);
		float ramp = w_toon_ramp(dot(n, sun_dir), 0.35, 0.16, 0.50, v_meta.z);
		vec3 direct = ramp * light_col * v_meta.y * coal / PI;
		vec3 ind = w_indirect(n, coal);
		lit = w_light_floor(direct + ind, coal) + ember;
	} else if (v_meta.x > 0.5) {
		// Window & lantern glass: cozy sky-tinted slate pane by day, honey-amber candlelight at dusk/night.
		vec3 day_glass = vec3(0.22, 0.34, 0.50);
		vec3 night_glass = vec3(0.98, 0.78, 0.44);
		vec3 gcol = mix(day_glass, night_glass, night_glow);
		float ramp = w_toon_ramp(dot(n, sun_dir), 0.35, 0.16, 0.50, v_meta.z);
		vec3 direct = ramp * light_col * v_meta.y * gcol / PI;
		vec3 ind = w_indirect(n, gcol);
		float flick = 0.94 + 0.06 * sin(TIME * 3.8 + v_wpos.x * 2.1 + v_wpos.z * 1.7);
		vec3 emis = vec3(1.15, 0.68, 0.22) * flick * (0.04 + night_glow * 1.75);
		lit = w_light_floor(direct + ind, gcol) + emis;
	} else {
		// Matte painted surface with 1 cheap world-space brushstroke variation fetch.
		float brush = texture(noise_tex, v_wpos.xz * 0.21 + vec2(v_wpos.y * 0.15, -v_wpos.y * 0.09)).g;
		vec3 albedo = v_col.rgb * (0.91 + 0.18 * brush) * v_col.a;
		float ramp = w_toon_ramp(dot(n, sun_dir), 0.32, 0.18, 0.48, v_meta.z);
		vec3 direct = ramp * light_col * v_meta.y * albedo / PI;
		vec3 ind = w_indirect(n, albedo);
		lit = w_light_floor(direct + ind, albedo);
	}

	lit = lit * v_atm_mul + v_atm_add;
	ALBEDO = w_grade(lit, SCREEN_UV, VIEWPORT_SIZE);
}
