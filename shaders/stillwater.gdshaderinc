// Shared pieces of Stillwater's look (src/glsl/common.js, src/post.js), fixed at hour 16.
// Terrain and sky do their own lighting and grading because Godot's tonemappers cannot reproduce
// Stillwater's stylTone curve. The environment runs a linear tonemapper with exposure 1, and the
// Compatibility renderer writes these unshaded/sky outputs to the screen unconverted, so they end
// with Stillwater's own sRGB encode.
//
// Terms that Stillwater weights by golden hour, dawn, dusk, night or alpenglow are left out:
// at hour 16 every one of those weights is exactly 0.

uniform sampler2D sky_lut : filter_linear, repeat_disable;
// Trilinear, not anisotropic: Stillwater's reference frames show the mip-blurred pattern at distance.
uniform sampler2D noise_tex : filter_linear_mipmap, repeat_enable;
uniform vec3 sun_dir = vec3(-0.8282, 0.5425, 0.1409);
uniform vec3 sun_col = vec3(0.9004, 0.6768, 0.4306);
uniform vec3 light_col = vec3(6.682, 5.161, 3.476);
uniform float exposure = 0.6;
// Stillwater's grade at hour 16 (env.js grade, post.js vignette). Constants rather than uniforms:
// Godot leaves sky-shader uniform defaults unset (zero) in this renderer.
const vec3 shadow_tint = vec3(0.90, 0.95, 1.14);
const vec3 grade_lift = vec3(0.004, 0.006, 0.012);
const float grade_sat = 1.1;
const float grade_contrast = 0.11;
const float vignette = 0.28;

float n_hash12(vec2 p) {
	vec3 p3 = fract(vec3(p.xyx) * 0.1031);
	p3 += dot(p3, p3.yzx + 33.33);
	return fract((p3.x + p3.y) * p3.z);
}

float n_noise(vec2 x) {
	vec2 i = floor(x);
	vec2 f = fract(x);
	vec2 u = f * f * (3.0 - 2.0 * f);
	return mix(mix(n_hash12(i), n_hash12(i + vec2(1.0, 0.0)), u.x), mix(n_hash12(i + vec2(0.0, 1.0)), n_hash12(i + vec2(1.0, 1.0)), u.x), u.y);
}

vec2 w_lut_uv(vec3 dir) {
	float az = atan(dir.z, dir.x);
	float el = asin(clamp(dir.y, -1.0, 1.0));
	float u = clamp(fract(az / 6.2831853 + 0.5), 0.003, 0.997);
	float v = clamp(0.5 + 0.5 * sign(el) * sqrt(abs(el) / 1.5707963), 0.005, 0.995);
	return vec2(u, v);
}

vec3 w_sky(vec3 dir) {
	return min(max(textureLod(sky_lut, w_lut_uv(dir), 0.0).rgb, vec3(0.0)), vec3(40.0));
}

float w_luma(vec3 c) {
	return dot(c, vec3(0.2126, 0.7152, 0.0722));
}

vec3 styl_tone(vec3 x) {
	float L = w_luma(x);
	float Lt = L * (1.0 + L / 7.5) / (1.0 + L);
	vec3 c = x * (Lt / max(L, 1e-5));
	float m = max(c.r, max(c.g, c.b));
	if (m > 1.0) {
		c = mix(c / m, vec3(1.0), clamp((m - 1.0) / (m + 0.55), 0.0, 1.0));
	}
	return clamp(c, 0.0, 1.0);
}

vec3 to_srgb(vec3 c) {
	return mix(c * 12.92, 1.055 * pow(c, vec3(1.0 / 2.4)) - 0.055, step(0.0031308, c));
}

// Stillwater's post chain after bloom: exposure, stylTone, daytime green freshness, split toning,
// saturation / lift / contrast, vignette. Bloom, FXAA, chromatic aberration and grain are not ported.
vec3 w_grade(vec3 col, vec2 screen_uv, vec2 viewport) {
	col = styl_tone(col * exposure);
	{
		float mx = max(col.r, max(col.g, col.b));
		float mn = min(col.r, min(col.g, col.b));
		float chroma = mx - mn;
		float is_green = smoothstep(0.01, 0.09, col.g - max(col.r * 0.84, col.b)) * smoothstep(0.02, 0.14, chroma);
		float day_fresh = is_green * smoothstep(0.16, 0.45, mx);
		col = mix(col, max(col + vec3(-0.008, 0.018, -0.018) * chroma * 1.4, 0.0), day_fresh * 0.45);
	}
	float Lg = w_luma(col);
	col *= mix(shadow_tint, vec3(1.04, 1.0, 0.94), smoothstep(0.08, 0.68, Lg));
	col = mix(col, vec3(Lg) * vec3(0.95, 0.96, 1.08), (1.0 - smoothstep(0.04, 0.36, Lg)) * 0.16);
	float L = w_luma(col);
	col = mix(vec3(L), col, grade_sat);
	col = col + grade_lift * (1.0 - col);
	col = clamp(col, 0.0, 1.0);
	col = mix(col, col * col * (3.0 - 2.0 * col), grade_contrast);
	vec2 vv = (screen_uv - 0.5) * vec2(viewport.x / viewport.y, 1.0);
	col *= clamp(1.0 - dot(vv, vv) * vignette, 0.0, 1.0);
	return to_srgb(col);
}
