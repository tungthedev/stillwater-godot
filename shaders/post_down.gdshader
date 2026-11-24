// Stillwater's bloom downsample (src/post.js DOWN): 13-tap filter; the first level adds the Karis
// average and the soft-knee threshold, and drops NaN / inf taps.
shader_type canvas_item;
render_mode unshaded, blend_disabled;

uniform sampler2D src : filter_linear, repeat_disable;
uniform vec2 texel;
uniform float first = 0.0;
uniform float threshold = 0.95;

vec3 s(vec2 uv, vec2 o) {
	vec3 c = texture(src, uv + o * texel).rgb;
	// NaN or inf, by the float's bits: isnan() / isinf() would make Safari's Metal compile drop fast
	// math for this shader (see w_denan in stillwater.gdshaderinc).
	return any(greaterThanEqual(floatBitsToUint(c) & uvec3(2147483647u), uvec3(2139095040u))) ? vec3(0.0) : c;
}
float lum(vec3 c) { return dot(c, vec3(0.2126, 0.7152, 0.0722)); }
vec3 karis(vec3 c) { return c / (1.0 + lum(c)); }

void fragment() {
	vec2 uv = UV;
	vec3 a = s(uv, vec2(-2, 2)), b = s(uv, vec2(0, 2)), c = s(uv, vec2(2, 2));
	vec3 d = s(uv, vec2(-2, 0)), e = s(uv, vec2(0, 0)), f = s(uv, vec2(2, 0));
	vec3 g = s(uv, vec2(-2, -2)), h = s(uv, vec2(0, -2)), i = s(uv, vec2(2, -2));
	vec3 j = s(uv, vec2(-1, 1)), k = s(uv, vec2(1, 1)), l = s(uv, vec2(-1, -1)), m = s(uv, vec2(1, -1));
	vec3 col;
	if (first > 0.5) {
		vec3 g0 = (a + b + d + e) * 0.25, g1 = (b + c + e + f) * 0.25, g2 = (d + e + g + h) * 0.25, g3 = (e + f + h + i) * 0.25, g4 = (j + k + l + m) * 0.25;
		col = karis(g0) * 0.125 + karis(g1) * 0.125 + karis(g2) * 0.125 + karis(g3) * 0.125 + karis(g4) * 0.5;
		col = col / max(1.0 - lum(col), 1e-3);
		float L = lum(col);
		float knee = threshold * 0.6;
		float soft = clamp(L - threshold + knee, 0.0, 2.0 * knee);
		soft = soft * soft / (4.0 * knee + 1e-4);
		float w = max(soft, L - threshold) / max(L, 1e-4);
		col *= w;
		col = min(col, vec3(45.0));
	} else {
		col = e * 0.125 + (a + c + g + i) * 0.03125 + (b + d + f + h) * 0.0625 + (j + k + l + m) * 0.125;
	}
	COLOR = vec4(col, 1.0);
}
