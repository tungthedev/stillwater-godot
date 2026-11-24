// Soaring alpine birds & valley raptors (W5):
// Pure vertex-shader elliptical orbital flight, analytical tangent orientation, gentle wing
// banking, and rhythmic soaring/flapping beats (0.000 ms GDScript). High-contrast dark indigo
// upper wings with pale cream undersides read crisply against both bright skies and dark peaks.
shader_type spatial;
render_mode unshaded, fog_disabled, cull_disabled, depth_draw_opaque, skip_vertex_transform;

#include "res://shaders/stillwater.gdshaderinc"
#include "res://shaders/atmosphere.gdshaderinc"

varying vec3 v_wn;
varying vec4 v_col;
varying vec3 v_atm_mul;
varying vec3 v_atm_add;

void vertex() {
	// Instance matrix packs: origin = orbit center, col0.x = rx, col1.y = rz, col2.z = scale,
	// col0.y = y_amp, col1.x = speed, col2.x = tilt_angle.
	// INSTANCE_CUSTOM packs: x = phase, y = flap_freq, z = soar_ratio, w = kind (0 swift, 1 raptor).
	vec3 center = MODEL_MATRIX[3].xyz;
	float rx = MODEL_MATRIX[0].x;
	float y_amp = MODEL_MATRIX[0].y;
	float speed = MODEL_MATRIX[1].x;
	float rz = MODEL_MATRIX[1].y;
	float tilt = MODEL_MATRIX[2].x;
	float sc = MODEL_MATRIX[2].z;

	float phase = INSTANCE_CUSTOM.x;
	float flap_f = INSTANCE_CUSTOM.y;
	float soar_r = INSTANCE_CUSTOM.z;

	float ang = TIME * speed + phase;
	float ca = cos(ang);
	float sa = sin(ang);
	float ct = cos(tilt);
	float st = sin(tilt);

	// Position and analytical velocity tangent along tilted ellipse + gentle vertical thermal wave.
	vec2 loc_p = vec2(ca * rx, sa * rz);
	vec2 loc_v = vec2(-sa * rx * speed, ca * rz * speed);
	vec3 wp_c = center + vec3(loc_p.x * ct - loc_p.y * st, sin(ang * 2.0 + phase) * y_amp, loc_p.x * st + loc_p.y * ct);
	vec3 vel = vec3(loc_v.x * ct - loc_v.y * st, cos(ang * 2.0 + phase) * y_amp * 2.0 * speed, loc_v.x * st + loc_v.y * ct);

	vec3 fwd = w_normalize(vel);
	vec3 side = w_normalize(cross(vec3(0.0, 1.0, 0.0), fwd));
	if (dot(side, side) < 0.01) {
		side = vec3(1.0, 0.0, 0.0);
	}
	vec3 upv = cross(fwd, side);

	// Natural turn banking + rhythmic flap-then-glide cycle.
	float bank = clamp(speed * 1.4, -0.42, 0.42);
	float cb = cos(bank);
	float sb = sin(bank);
	vec3 b_side = side * cb + upv * sb;
	vec3 b_up = upv * cb - side * sb;

	float beat_env = smoothstep(soar_r - 0.15, soar_r + 0.15, sin(TIME * 0.42 + phase * 1.7) * 0.5 + 0.5);
	float flap = sin(TIME * flap_f + phase * 5.0) * mix(0.10, 0.58, beat_env);

	vec3 lv = VERTEX;
	float wing_span = abs(lv.x);
	lv.y += wing_span * flap;
	// Subtle wingtip lag makes flapping look supple instead of stiff triangles.
	lv.y -= wing_span * wing_span * 0.16 * cos(TIME * flap_f + phase * 5.0) * beat_env;

	vec3 wp = wp_c + (b_side * lv.x + b_up * lv.y + fwd * lv.z) * sc;
	vec3 cam = CAMERA_POSITION_WORLD;
	POSITION = PROJECTION_MATRIX * (VIEW_MATRIX * vec4(wp, 1.0));

	v_wn = w_normalize(b_side * NORMAL.x + b_up * NORMAL.y + fwd * NORMAL.z);
	v_col = CUSTOM0;

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
	// Warm pale underside vs deep slate-indigo dorsal plumage for crisp sky/ridge legibility.
	vec3 alb = FRONT_FACING ? v_col.rgb : mix(v_col.rgb, vec3(0.92, 0.88, 0.80), 0.55);
	float ramp = w_toon_ramp(dot(n, sun_dir), 0.45, 0.14, 0.54, 80.0);
	vec3 direct = ramp * light_col * alb / PI;
	vec3 ind = w_indirect(n, alb);
	vec3 lit = w_light_floor(direct + ind, alb);
	lit = lit * v_atm_mul + v_atm_add;
	ALBEDO = w_grade(lit, SCREEN_UV, VIEWPORT_SIZE);
}
