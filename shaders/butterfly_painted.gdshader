// Colorful meadow & flower-glade butterflies (W5):
// 48 tiny opaque double-sided flapping butterflies wrapping in a 24 m box around the camera
// purely in vertex (0.000 ms GDScript). Ground-referenced via near_tex, biome-gated to meadows
// and wildflower patches, hidden over water and at dusk/night. Zero discard, 288 tris total.
shader_type spatial;
render_mode unshaded, fog_disabled, cull_disabled, depth_draw_opaque, skip_vertex_transform;

#include "res://shaders/stillwater.gdshaderinc"
#include "res://shaders/atmosphere.gdshaderinc"

uniform sampler2D near_tex : filter_linear, repeat_disable;
uniform sampler2D biome_tex : filter_linear, repeat_disable;
uniform float near_size = 4096.0;
uniform float near_min = 0.0;
uniform float near_step = 0.01;
uniform float box_size = 18.0;

varying vec3 v_col;
varying vec3 v_wn;
varying vec3 v_atm_mul;
varying vec3 v_atm_add;

float bf_height_near(vec2 xz) {
	float res = float(textureSize(near_tex, 0).x);
	vec2 f = clamp((xz / near_size + 0.5) * res - 0.5, vec2(0.0), vec2(res - 1.001));
	ivec2 i = ivec2(floor(f));
	vec2 t = floor(texelFetch(near_tex, i, 0).rg * 255.0 + 0.5);
	return near_min + near_step * (t.x + t.y * 256.0);
}

vec3 bf_palette(float s) {
	float k = fract(s * 7.31);
	if (k < 0.25) return vec3(0.98, 0.80, 0.16); // brimstone saffron
	if (k < 0.50) return vec3(0.96, 0.44, 0.14); // monarch orange
	if (k < 0.75) return vec3(0.32, 0.72, 0.98); // chalkhill sky-blue
	return vec3(0.98, 0.94, 0.84);               // cabbage cream-white
}

void vertex() {
	vec3 cam = CAMERA_POSITION_WORLD;
	vec4 seed = INSTANCE_CUSTOM;

	// Wandering figure-8 flutter path wrapped cleanly in a 24 m box around camera.
	float t = TIME * (0.65 + seed.w * 0.45) + seed.z * 31.0;
	vec3 wander = vec3(
		sin(t * 1.1 + seed.x * 19.0) * 2.4 + cos(t * 0.43 + seed.y * 13.0) * 1.6,
		0.0,
		cos(t * 0.9 + seed.y * 23.0) * 2.4 + sin(t * 0.51 + seed.x * 17.0) * 1.6
	);
	vec3 base = seed.xyz * box_size;
	vec3 rel = mod(base + wander - cam + box_size * 0.5, box_size) - box_size * 0.5;
	vec3 p = cam + rel;

	float g = bf_height_near(p.xz);
	p.y = g + 0.42 + fract(seed.y * 5.3) * 1.65 + sin(t * 2.3 + seed.w * 11.0) * 0.28;

	vec3 bio = textureLod(biome_tex, clamp(p.xz / near_size + 0.5, vec2(0.001), vec2(0.999)), 0.0).rgb;
	// Prefer sunlit meadows & wildflower patches; collapse to zero over water, snow, or deep dark canopy.
	float meadow_ok = smoothstep(0.10, 0.35, bio.g + bio.b) * w_rstep(0.75, 0.38, bio.r);
	float above_water = smoothstep(water_level + 0.4, water_level + 1.4, g);
	float below_snow = w_rstep(340.0, 260.0, g);
	float edge_k = w_rstep(box_size * 0.48, box_size * 0.34, length(rel.xz));
	float near_k = smoothstep(2.2, 4.0, length(p - cam));
	float vis_scale = meadow_ok * above_water * below_snow * edge_k * near_k * sun_disc_vis;

	// Heading tangent from analytical derivative of wander.
	vec3 vel = vec3(
		cos(t * 1.1 + seed.x * 19.0) * 2.64 - sin(t * 0.43 + seed.y * 13.0) * 0.688,
		0.0,
		-sin(t * 0.9 + seed.y * 23.0) * 2.16 + cos(t * 0.51 + seed.x * 17.0) * 0.816
	);
	vec3 fwd = w_normalize(vel + vec3(1e-4, 0.0, 0.0));
	vec3 side = vec3(-fwd.z, 0.0, fwd.x);
	vec3 upv = vec3(0.0, 1.0, 0.0);

	// Crisp rapid double-wing flutter around body axis (x = +-wing span).
	float flap = sin(TIME * (11.5 + seed.w * 4.5) + seed.z * 43.0) * 1.05;
	float cf = cos(flap);
	float sf = sin(flap);
	vec3 lv = VERTEX;
	float wing_sign = lv.x >= 0.0 ? 1.0 : -1.0;
	float ax = abs(lv.x);
	vec3 bent = vec3(wing_sign * ax * cf, lv.y + ax * sf, lv.z);

	float sc = (0.072 + seed.w * 0.028) * vis_scale;
	vec3 wp = p + (side * bent.x + upv * bent.y + fwd * bent.z) * sc;
	POSITION = PROJECTION_MATRIX * (VIEW_MATRIX * vec4(wp, 1.0));

	v_wn = w_normalize(upv * cf - side * (wing_sign * sf));
	vec3 pal = bf_palette(seed.w);
	// Darken body/wing-tip accent using vertex color stored in CUSTOM0.
	v_col = pal * CUSTOM0.rgb;

	vec3 am;
	vec3 aa;
	w_atmosphere(wp, cam, am, aa);
	v_atm_mul = am;
	v_atm_add = aa;
}

void fragment() {
	vec3 n = w_normalize(v_wn);
	if (!FRONT_FACING) {
		n = -n;
	}
	float ramp = w_toon_ramp(dot(n, sun_dir), 0.65, 0.08, 0.55, 20.0);
	vec3 direct = ramp * light_col * v_col / PI;
	vec3 ind = w_indirect(n, v_col);
	// Subtle translucent backlit wing glow so butterflies sparkle brightly over grass.
	vec3 lit = w_light_floor(direct + ind, v_col) + v_col * (light_col * 0.14);
	lit = lit * v_atm_mul + v_atm_add;
	ALBEDO = w_grade(lit, SCREEN_UV, VIEWPORT_SIZE);
}
