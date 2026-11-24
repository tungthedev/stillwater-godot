// Stillwater's bloom upsample (src/post.js UP): 3 x 3 tent of the smaller level plus this level.
shader_type canvas_item;
render_mode unshaded, blend_disabled;

uniform sampler2D src : filter_linear, repeat_disable;
uniform sampler2D add : filter_linear, repeat_disable;
uniform vec2 texel;
uniform float radius = 1.0;

void fragment() {
	vec2 uv = UV;
	vec2 t = texel * radius;
	vec3 c = texture(src, uv).rgb * 4.0;
	c += (texture(src, uv + vec2(-t.x, 0)).rgb + texture(src, uv + vec2(t.x, 0)).rgb + texture(src, uv + vec2(0, -t.y)).rgb + texture(src, uv + vec2(0, t.y)).rgb) * 2.0;
	c += texture(src, uv + vec2(-t.x, -t.y)).rgb + texture(src, uv + vec2(t.x, -t.y)).rgb + texture(src, uv + vec2(-t.x, t.y)).rgb + texture(src, uv + vec2(t.x, t.y)).rgb;
	c /= 16.0;
	COLOR = vec4(c + texture(add, uv).rgb, 1.0);
}
