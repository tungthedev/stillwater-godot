// Trailhead signpost shader (W3): renders the wooden post, weather cap, and all 3 fanned cedar
// lettering boards in 1 opaque draw call (render_priority = -1, zero discard).
// UV.x < 1.2 samples signpost_tex; UV.x >= 1.2 uses vertex-colored weathered cedar wood.
shader_type spatial;
render_mode unshaded, fog_disabled, cull_back, depth_draw_opaque;

#include "res://shaders/stillwater.gdshaderinc"
#include "res://shaders/atmosphere.gdshaderinc"

uniform sampler2D signpost_tex : source_color, filter_linear_mipmap, repeat_disable;

varying vec3 v_wpos;
varying vec3 v_wn;
varying vec2 v_uv;
varying vec3 v_col;
varying vec3 v_atm_mul;
varying vec3 v_atm_add;
varying vec2 v_meta; // x: sun_vis, y: cam dist

void vertex() {
	vec3 wp = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	vec3 cam = CAMERA_POSITION_WORLD;
	mat3 m = mat3(MODEL_MATRIX);
	v_wn = w_normalize(m * NORMAL);
	v_wpos = wp;
	v_uv = UV;
	v_col = CUSTOM0.rgb;
	v_meta = vec2(w_cloud_shadow_v(wp + vec3(0.0, 2.0, 0.0), cam), length(wp - cam));

	vec3 atm_mul;
	vec3 atm_add;
	w_atmosphere(wp, cam, atm_mul, atm_add);
	v_atm_mul = atm_mul;
	v_atm_add = atm_add;
}

void fragment() {
	vec3 n = w_normalize(v_wn);
	vec3 albedo;
	if (v_uv.x < 1.2) {
		albedo = texture(signpost_tex, clamp(v_uv, vec2(0.001), vec2(0.999))).rgb * vec3(0.84, 0.78, 0.70);
	} else {
		float grain = texture(noise_tex, vec2(v_wpos.x + v_wpos.z, v_wpos.y) * vec2(0.45, 3.2)).g;
		albedo = v_col * (0.76 + 0.36 * grain);
	}
	// High soft wrap (matching props.js toonWrap 0.58) keeps all 3 fanned boards crisp and evenly lit.
	float ramp = w_toon_ramp(dot(n, sun_dir), 0.56, 0.10, 0.44, v_meta.y);
	vec3 direct = ramp * light_col * v_meta.x * albedo / PI;
	vec3 ind = w_indirect(n, albedo);
	vec3 lit = w_light_floor(direct + ind, albedo);
	lit = lit * v_atm_mul + v_atm_add;
	ALBEDO = w_grade(lit, SCREEN_UV, VIEWPORT_SIZE);
}
