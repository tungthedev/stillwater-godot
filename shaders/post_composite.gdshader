// Stillwater's composite (src/post.js COMPOSITE) for a tier without MSAA, at hour 16: FXAA on
// display-like values with sharpening off the edges, bloom, the sun-side veil, exposure, stylTone,
// the daytime green grade, split toning, saturation / lift / contrast, vignette, sRGB, grain and
// dither. Runs on every screen pixel; the scene comes in at the internal resolution. Terms that
// Stillwater weights by golden hour or dawn are left out: both are exactly 0 at hour 16. God rays,
// lens ghost, fade and letterbox are off at `low`.
//
// passthrough = 1 (post off): the scene was graded by the objects themselves; just upscale it.
shader_type canvas_item;
render_mode unshaded, blend_disabled;

uniform sampler2D t_scene : filter_linear, repeat_disable;
uniform sampler2D t_bloom : filter_linear, repeat_disable;
uniform float passthrough = 0.0;
uniform float bloom_k = 0.055;
uniform float exposure = 0.6;
uniform vec2 res = vec2(1.0);
uniform vec2 src_texel = vec2(1.0);
uniform float sharpen = 0.6;
// 0 only for the parity test (tests/post_parity.gd): FXAA off.
uniform float fxaa = 1.0;
uniform float grain = 0.022;
uniform vec2 sun_uv;
uniform float sun_vis = 0.0;
uniform vec3 ray_color = vec3(1.0);
uniform float painterly = 1.0;
const vec3 WB = vec3(1.0);
const vec3 SHADOW_TINT = vec3(0.90, 0.95, 1.14);
const vec3 LIFT = vec3(0.004, 0.006, 0.012);
const float SAT = 1.1;
const float CONTRAST = 0.11;
const float VIGNETTE = 0.28;

vec3 styl_tone(vec3 x) {
	float L = dot(x, vec3(0.2126, 0.7152, 0.0722));
	float Lt = L * (1.0 + L / 7.5) / (1.0 + L);
	vec3 c = x * (Lt / max(L, 1e-5));
	float m = max(c.r, max(c.g, c.b));
	if (m > 1.0) c = mix(c / m, vec3(1.0), clamp((m - 1.0) / (m + 0.55), 0.0, 1.0));
	return clamp(c, 0.0, 1.0);
}
vec3 to_srgb(vec3 c) { return mix(c * 12.92, 1.055 * pow(c, vec3(1.0 / 2.4)) - 0.055, step(0.0031308, c)); }
float hash(vec2 p) { return fract(sin(dot(p, vec2(12.9898, 78.233))) * 43758.5453); }
float fx_l(vec3 c) { return dot(c, vec3(0.2126, 0.7152, 0.0722)); }
vec3 fx_encode(vec3 c) { vec3 x = c * exposure * WB; return x / (1.0 + fx_l(x)); }
vec3 fx_decode(vec3 t) { return t / max(1.0 - fx_l(t), 1e-3) / max(exposure * WB, vec3(1e-4)); }
float fx_luma(vec3 t) { return sqrt(fx_l(t)); }

void fragment() {
	vec2 uv = UV;
	if (passthrough > 0.5) {
		COLOR = vec4(texture(t_scene, uv).rgb, 1.0);
	} else {
		vec3 rgbM = texture(t_scene, uv).rgb;
		vec3 rgbE = texture(t_scene, uv + vec2(src_texel.x, 0)).rgb, rgbW = texture(t_scene, uv - vec2(src_texel.x, 0)).rgb;
		vec3 rgbN = texture(t_scene, uv + vec2(0, src_texel.y)).rgb, rgbS = texture(t_scene, uv - vec2(0, src_texel.y)).rgb;
		float lM = fx_luma(fx_encode(rgbM)), lE = fx_luma(fx_encode(rgbE)), lW = fx_luma(fx_encode(rgbW));
		float lN = fx_luma(fx_encode(rgbN)), lS = fx_luma(fx_encode(rgbS));
		float lMin = min(lM, min(min(lE, lW), min(lN, lS)));
		float lMax = max(lM, max(max(lE, lW), max(lN, lS)));
		vec3 col = rgbM;
		if (fxaa > 0.5 && lMax - lMin >= max(0.0312, lMax * 0.125)) {
			vec2 dir = vec2(lS - lN, lE - lW);
			float reduce = max((lE + lW + lN + lS) * 0.03125, 1.0 / 128.0);
			dir = clamp(dir / (min(abs(dir.x), abs(dir.y)) + reduce), -8.0, 8.0) * src_texel;
			vec3 tA = 0.5 * (fx_encode(texture(t_scene, uv - dir * (1.0 / 6.0)).rgb) + fx_encode(texture(t_scene, uv + dir * (1.0 / 6.0)).rgb));
			vec3 tB = tA * 0.5 + 0.25 * (fx_encode(texture(t_scene, uv - dir * 0.5).rgb) + fx_encode(texture(t_scene, uv + dir * 0.5).rgb));
			float lB = fx_luma(tB);
			col = fx_decode((lB < lMin || lB > lMax) ? tA : tB);
		} else if (sharpen > 0.0) {
			col = max(col + (col * 4.0 - (rgbE + rgbW + rgbN + rgbS)) * sharpen * 0.25, 0.0);
		}
		col += texture(t_bloom, uv).rgb * bloom_k;
		if (sun_vis > 0.001) {
			vec2 sd = (uv - sun_uv) * vec2(res.x / max(res.y, 1.0), 1.0);
			col += ray_color * vec3(1.0, 0.86, 0.66) * exp(-dot(sd, sd) * 5.2) * 0.045 * sun_vis;
		}
		col *= exposure;
		col *= WB;
		col = styl_tone(col);
		{
			float mx = max(col.r, max(col.g, col.b)), mn = min(col.r, min(col.g, col.b));
			float chroma = mx - mn;
			float is_green = smoothstep(0.01, 0.09, col.g - max(col.r * 0.84, col.b)) * smoothstep(0.02, 0.14, chroma);
			float day_fresh = is_green * smoothstep(0.16, 0.45, mx);
			col = mix(col, max(col + vec3(-0.008, 0.018, -0.018) * chroma * 1.4, 0.0), day_fresh * 0.45);
		}
		float Lg = dot(col, vec3(0.2126, 0.7152, 0.0722));
		vec3 s_tint = painterly > 0.5 ? vec3(0.88, 0.90, 1.20) : SHADOW_TINT;
		vec3 s_cast = painterly > 0.5 ? vec3(0.93, 0.92, 1.14) : vec3(0.95, 0.96, 1.08);
		vec3 lift = painterly > 0.5 ? vec3(0.006, 0.006, 0.016) : LIFT;
		float sat = painterly > 0.5 ? 1.12 : SAT;
		float contrast = painterly > 0.5 ? 0.08 : CONTRAST;
		float vig = painterly > 0.5 ? 0.24 : VIGNETTE;
		col *= mix(s_tint, vec3(1.04, 1.0, 0.94), smoothstep(0.08, 0.68, Lg));
		col = mix(col, vec3(Lg) * s_cast, (1.0 - smoothstep(0.04, 0.36, Lg)) * 0.16);
		float L = dot(col, vec3(0.2126, 0.7152, 0.0722));
		col = mix(vec3(L), col, sat);
		col = col + lift * (1.0 - col);
		col = clamp(col, 0.0, 1.0);
		col = mix(col, col * col * (3.0 - 2.0 * col), contrast);
		vec2 vv = (uv - 0.5) * vec2(res.x / res.y, 1.0);
		col *= clamp(1.0 - dot(vv, vv) * vig, 0.0, 1.0);
		col = to_srgb(col);
		float n = hash(uv * res + fract(TIME * 7.13) * 100.0) - 0.5;
		col += n * grain * (1.0 - col * 0.5);
		col += (hash(uv * res * 1.3 + 3.1) - 0.5) / 255.0;
		COLOR = vec4(col, 1.0);
	}
}
