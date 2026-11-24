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
// 1: the post chain grades (systems/post.gd), so objects write scene-linear HDR; 0: graded here.
uniform float post_on = 0.0;
// 1: painterly look; 0: classic port of Stillwater (?style=classic). Set by environment.gd.
uniform float painterly = 1.0;
// Sky and horizon styling, set from environment.gd so a time of day can drive them.
uniform vec3 horizon_tint = vec3(0.95, 0.99, 1.07);
uniform float sky_sat = 1.38;
uniform float horizon_haze = 0.34;
// Stillwater's grade at hour 16 (env.js grade, post.js vignette). Constants rather than uniforms:
// Godot leaves sky-shader uniform defaults unset (zero) in this renderer.
const vec3 shadow_tint = vec3(0.90, 0.95, 1.14);
const vec3 grade_lift = vec3(0.004, 0.006, 0.012);
const float grade_sat = 1.1;
const float grade_contrast = 0.11;
const float vignette = 0.28;

// ?probe=terrain switches (systems/terrain_probe_page.gd): one bit per suspect, so a phone can
// bisect a wrong picture without a new build. Only the terrain shader defines W_DBG; in every
// other shader DBG() is the constant false and the compiler drops the branches.
#define DBG_LEGACY_POW 1
#define DBG_LEGACY_RSTEP 2
#define DBG_LEGACY_MISC 4
#define DBG_NO_GUARD 8
#define DBG_NO_FLOOR 16
#define DBG_NO_ATM 32
#define DBG_CLASSIC_IND 64
#define DBG_CLASSIC_RAMP 128
#define DBG_OUT_ALBEDO 256
#define DBG_NAN_POW 1024
#define DBG_MATH_MODE 2048
#ifdef W_DBG
uniform int dbg_terrain = 0;
// Always 0; a uniform so the compiler cannot work out 0 / 0 itself (DBG_MATH_MODE).
uniform float dbg_zero = 0.0;
#define DBG(bit) ((dbg_terrain & (bit)) != 0)
#else
#define DBG(bit) false
#endif

// smoothstep falling from 1 to 0 as x goes from `lo` up to `hi`. GLSL leaves
// smoothstep(edge0, edge1, x) undefined when edge0 >= edge1, so the falling ones are written as
// one minus the rising one.
float w_rstep(float hi, float lo, float x) {
	if (DBG(DBG_LEGACY_RSTEP)) {
		return smoothstep(hi, lo, x);
	}
	return 1.0 - smoothstep(lo, hi, x);
}

// NaN -> fallback, by testing the float's bits. Never isnan() or isinf() in these shaders:
// ANGLE's Metal backend (Safari) compiles any shader that calls one of them with safe math
// instead of fast math. That costs speed on iPhone, and it turned an old pow() of a negative
// base in the terrain into real NaNs (build s1-2: black ground). The bit test is integer work,
// which keeps fast math on and which a fast-math compiler cannot fold away.
vec3 w_denan(vec3 c, vec3 fallback) {
	if (DBG(DBG_NO_GUARD)) {
		return c;
	}
	return mix(c, fallback, greaterThan(floatBitsToUint(c) & uvec3(2147483647u), uvec3(2139095040u)));
}

// normalize() of a zero vector is undefined; this returns zero for it instead.
vec3 w_normalize(vec3 v) {
	return v * inversesqrt(max(dot(v, v), 1e-20));
}

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
	// atan(0, 0) is undefined (a direction straight up or down).
	float az = abs(dir.x) + abs(dir.z) > 1e-7 ? atan(dir.z, dir.x) : 0.0;
	float el = asin(clamp(dir.y, -1.0, 1.0));
	float u = clamp(fract(az / 6.2831853 + 0.5), 0.003, 0.997);
	float v = clamp(0.5 + 0.5 * sign(el) * sqrt(abs(el) / 1.5707963), 0.005, 0.995);
	return vec2(u, v);
}

vec3 w_sky(vec3 dir) {
	vec3 c = textureLod(sky_lut, w_lut_uv(dir), 0.0).rgb;
	// Guard NaN/Inf before clamping so bloom never explodes into squares.
	c = w_denan(c, vec3(0.0));
	return clamp(c, vec3(0.0), vec3(40.0));
}

float w_luma(vec3 c) {
	return dot(c, vec3(0.2126, 0.7152, 0.0722));
}

// Styled sky base shared by sky.gdshader and w_horizon_color so far terrain fog matches the sky.
vec3 w_sky_base(vec3 dir) {
	vec3 col = w_sky(vec3(dir.x, max(dir.y, -0.02), dir.z));
	float lum_s = w_luma(col);
	float sat = painterly > 0.5 ? sky_sat : 1.40;
	col = mix(vec3(lum_s), col, sat);
	float hz = exp(-max(dir.y, 0.0) * 8.5);
	vec3 h_tint = painterly > 0.5 ? horizon_tint : vec3(0.96, 1.0, 1.04);
	float h_mix = painterly > 0.5 ? horizon_haze : 0.32;
	col = mix(col, vec3(lum_s) * h_tint * 1.15, hz * h_mix);
	col = max(col, vec3(0.0));
	col.g = min(col.g, (col.r + col.b) * 0.6);
	return clamp(col, vec3(0.0), vec3(40.0));
}

// Shared horizon-matched sky colour (base sky + broad sun halo) used by w_atmosphere and clouds
// so distant slopes fade seamlessly into the exact sky colour behind them.
vec3 w_horizon_color(vec3 dir) {
	vec3 d = normalize(vec3(dir.x, max(dir.y, -0.02), dir.z));
	vec3 col = w_sky_base(d);
	float mu = dot(d, sun_dir);
	col += sun_col * pow(max(mu, 0.0), 28.0) * 0.24 * 0.45;
	col = w_denan(col, vec3(0.0));
	return clamp(col, vec3(0.0), vec3(40.0));
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

// The Compatibility renderer passes every 3D colour output through
// linear_to_srgb(srgb_to_linear(c)) with two different approximations (a cubic one way, a
// pow(1 / 2.4) without the linear toe the other), which crushes values under ~0.02 and lifts
// bright HDR. This undoes that, so the render target holds exactly v: solve the cubic for the
// value whose round trip is v (three Newton steps from a power-law guess).
vec3 godot_out(vec3 v) {
	vec3 p = pow((max(v, vec3(0.0)) + 0.055) / 1.055, vec3(2.4));
	vec3 x = mix(pow(p, vec3(0.4545)), pow(p / 0.305306011, vec3(0.33333)), step(1.0, p));
	for (int i = 0; i < 3; i++) {
		vec3 f = x * (x * (x * 0.305306011 + 0.682171111) + 0.012522878) - p;
		vec3 d = x * (x * 0.915918033 + 1.364342222) + 0.012522878;
		x -= f / d;
	}
	return x;
}

// Stillwater's post chain after bloom: exposure, stylTone, daytime green freshness, split toning,
// saturation / lift / contrast, vignette, sRGB encode. With post_on the composite pass does this
// (plus bloom, FXAA, sharpen and grain) on the full-resolution screen, as Stillwater does.
vec3 w_grade_ldr(vec3 col, vec2 screen_uv, vec2 viewport) {
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
	vec3 s_tint = painterly > 0.5 ? vec3(0.88, 0.90, 1.20) : shadow_tint;
	vec3 s_cast = painterly > 0.5 ? vec3(0.93, 0.92, 1.14) : vec3(0.95, 0.96, 1.08);
	vec3 lift = painterly > 0.5 ? vec3(0.006, 0.006, 0.016) : grade_lift;
	float sat = painterly > 0.5 ? 1.12 : grade_sat;
	float contrast = painterly > 0.5 ? 0.08 : grade_contrast;
	float vig = painterly > 0.5 ? 0.24 : vignette;
	col *= mix(s_tint, vec3(1.04, 1.0, 0.94), smoothstep(0.08, 0.68, Lg));
	col = mix(col, vec3(Lg) * s_cast, (1.0 - smoothstep(0.04, 0.36, Lg)) * 0.16);
	float L = w_luma(col);
	col = mix(vec3(L), col, sat);
	col = col + lift * (1.0 - col);
	col = clamp(col, 0.0, 1.0);
	col = mix(col, col * col * (3.0 - 2.0 * col), contrast);
	vec2 vv = (screen_uv - 0.5) * vec2(viewport.x / viewport.y, 1.0);
	col *= clamp(1.0 - dot(vv, vv) * vig, 0.0, 1.0);
	return to_srgb(col);
}

vec3 w_grade(vec3 col, vec2 screen_uv, vec2 viewport) {
	col = w_denan(col, vec3(0.0));
	if (post_on > 0.5) {
		return godot_out(clamp(col, vec3(0.0), vec3(200.0)));
	}
	return godot_out(w_grade_ldr(col, screen_uv, viewport));
}
