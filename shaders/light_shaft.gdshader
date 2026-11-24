// Volumetric sunlit canopy light shafts (W4):
// Conical sunbeams aligned to sun_dir in forest glades along the trail (from undergrowth.js
// LightShafts), capped for mobile fill-rate. Additive blend, zero depth write, zero texture
// fetches in fragment, soft Gaussian + top/bottom feathering with zero hard card edges.
shader_type spatial;
render_mode unshaded, fog_disabled, blend_add, depth_draw_never, cull_disabled, skip_vertex_transform;

#include "res://shaders/stillwater.gdshaderinc"
#include "res://shaders/atmosphere.gdshaderinc"

uniform vec4 ao_spot = vec4(615.25, 796.96, 8.5, 0.0);
uniform float shaft_strength = 1.0;

varying vec2 v_q;
varying float v_seed;
varying float v_fade;
varying float v_depth;
varying vec3 v_col;

void vertex() {
	vec3 cam = CAMERA_POSITION_WORLD;
	vec3 base = MODEL_MATRIX[3].xyz + vec3(0.0, -0.5, 0.0);
	float width = INSTANCE_CUSTOM.x;
	float seed = INSTANCE_CUSTOM.y;
	float max_d = max(INSTANCE_CUSTOM.z, 40.0);

	vec3 A = w_normalize(sun_dir);
	vec3 to_cam = w_normalize(cam - base);
	vec3 cr = cross(A, to_cam);
	float sin_ang = length(cr);
	vec3 side = sin_ang > 1e-4 ? (cr / sin_ang) : vec3(1.0, 0.0, 0.0);

	// Flaring conical sunbeam (narrow at canopy top y=1, softly wider onto forest floor y=0).
	float len = 26.0;
	float cone_w = width * 0.76 * (0.42 + (1.0 - VERTEX.y) * 1.50);
	vec3 wp = base + A * (VERTEX.y * len) + side * (VERTEX.x * cone_w);

	vec4 mv = VIEW_MATRIX * vec4(wp, 1.0);
	v_depth = -mv.z;
	POSITION = PROJECTION_MATRIX * mv;

	v_q = vec2(VERTEX.x + 0.5, VERTEX.y);
	v_seed = seed;

	float d = length(cam - base);
	float cot_clear = ao_spot.z > 0.1 ? smoothstep(82.0, 120.0, length(base.xz - ao_spot.xy)) : 1.0;
	float sun_up = clamp(sun_dir.y * 3.0, 0.0, 1.0);
	float grazing = smoothstep(0.06, 0.28, sin_ang);
	v_fade = cot_clear * sun_up * grazing * smoothstep(3.5, 9.5, d) * w_rstep(max_d, max_d * 0.52, d);

	float peak = max(light_col.r, max(light_col.g, light_col.b));
	vec3 norm_l = light_col / max(peak, 1e-4);
	v_col = mix(norm_l, vec3(1.0, 0.91, 0.58), 0.78);
}

void fragment() {
	float dx = (v_q.x - 0.5) * 2.0;
	// Silky Gaussian cross-section + delicate internal sunbeam striations + feathered ends.
	float gauss = exp(-dx * dx * 4.4) * w_rstep(1.0, 0.56, abs(dx));
	float rays = 0.70 + 0.30 * sin(v_q.x * 13.0 + v_seed * 25.0) * sin(v_q.x * 6.0 - v_seed * 12.0);
	float along = smoothstep(0.0, 0.30, v_q.y) * w_rstep(1.0, 0.30, v_q.y);
	float flick = 0.88 + 0.12 * sin(TIME * 0.65 + v_seed * 30.0);
	float near_fade = smoothstep(4.0, 11.5, v_depth);

	float a = gauss * rays * along * flick * v_fade * near_fade * shaft_strength * 0.54;
	vec3 glow = w_denan(v_col * a, vec3(0.0));
	ALBEDO = post_on > 0.5
		? godot_out(clamp(glow * 1.15, vec3(0.0), vec3(4.0)))
		: godot_out(clamp(glow * 0.62, vec3(0.0), vec3(1.0)));
}
