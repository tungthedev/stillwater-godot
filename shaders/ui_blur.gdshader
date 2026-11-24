shader_type canvas_item;

// The pause sheet's backdrop: the screen behind it, blurred (CSS backdrop-filter: blur(6px)) and
// darkened (rgba(5, 6, 8, 0.35)). Reads a mip of the screen copy, so it costs one copy and one
// lookup per pixel, only while paused.
uniform sampler2D screen_tex : hint_screen_texture, filter_linear_mipmap;
uniform float lod = 2.5;
uniform vec4 tint : source_color = vec4(0.02, 0.024, 0.031, 0.35);

void fragment() {
	vec3 c = textureLod(screen_tex, SCREEN_UV, lod).rgb;
	COLOR = vec4(mix(c, tint.rgb, tint.a), 1.0);
}
