shader_type spatial;
render_mode cull_disabled;

uniform vec3 base_col : source_color = vec3(0.16, 0.30, 0.07);
uniform vec3 tip_col : source_color = vec3(0.58, 0.68, 0.26);
varying float tipness;

void vertex() {
	tipness = clamp(VERTEX.y / 0.7, 0.0, 1.0);
	vec3 wp = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	float sway = sin(TIME * 1.7 + wp.x * 0.35 + wp.z * 0.22) * 0.12 * tipness * tipness;
	VERTEX.x += sway;
	VERTEX.z += sway * 0.5;
	NORMAL = vec3(0.0, 1.0, 0.0);
}

void fragment() {
	ALBEDO = mix(base_col, tip_col, tipness);
	ROUGHNESS = 0.9;
}
