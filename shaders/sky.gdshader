// Stillwater's sky dome (src/world/sky.js) at hour 16: the sky-view LUT read back from the game,
// its saturation and pale-horizon styling, the sun disc and glow, and the cirrus wisps. Stars, moon
// and the golden-hour / dusk terms have zero weight at hour 16. Graded like the terrain (see
// stillwater.gdshaderinc). The cumulus banks are meshes (systems/clouds.gd).
shader_type sky;

#include "res://shaders/stillwater.gdshaderinc"

// SCREEN_UV is not usable in sky shaders on this renderer, so the vignette's screen position is
// found by projecting EYEDIR with the camera basis (set every frame by systems/environment.gd).
uniform vec2 view_size;
uniform vec3 cam_right;
uniform vec3 cam_up;
uniform vec3 cam_fwd;
uniform float tan_half_fov;
uniform vec2 cloud_offset;
uniform vec2 wind_dir;
uniform float cirrus_on = 1.0;

// sky.js cirrus(): a wind-aligned noise layer at 12 km, daytime colour only.
vec4 cirrus(vec3 dir, vec3 cam) {
	if (dir.y <= 0.06) return vec4(0.0);
	float t = (12000.0 - cam.y) / max(dir.y, 0.07);
	vec2 xz = cam.xz + dir.xz * t + cloud_offset * 1.6;
	vec2 wdir = normalize(wind_dir + 1e-4);
	vec2 wperp = vec2(-wdir.y, wdir.x);
	vec2 uv = vec2(dot(xz, wdir) * 0.000016, dot(xz, wperp) * 0.000046);
	vec4 n1 = texture(noise_tex, uv);
	vec2 warp = vec2(n1.r - 0.5, n1.g - 0.5) * 0.38;
	float wisp = texture(noise_tex, uv * vec2(1.1, 1.9) + warp).g * 0.58
			+ texture(noise_tex, uv * vec2(2.6, 4.4) + warp * 1.4 + 0.31).b * 0.42;
	float macro = smoothstep(0.38, 0.72, n1.r);
	float a = smoothstep(0.50, 0.76, wisp) * macro * 0.22 * smoothstep(0.06, 0.26, dir.y) * (1.0 - smoothstep(0.76, 0.98, dir.y) * 0.42);
	if (a < 0.004) return vec4(0.0);
	float mu = dot(normalize(dir), sun_dir);
	vec3 c = w_sky(vec3(0.0, 1.0, 0.0)) * 0.75 + light_col * (0.28 + pow(max(mu, 0.0), 5.0) * 0.75);
	return vec4(c, a);
}

void sky() {
	vec3 dir = EYEDIR;
	vec3 col = w_sky_base(dir);
	float mu = dot(dir, sun_dir);
	float sun_r = 0.02;
	float sd = acos(clamp(mu, -1.0, 1.0));
	if (sd < sun_r * 2.2) {
		float x = clamp(sd / sun_r, 0.0, 1.0);
		float limb = 1.0 - 0.55 * (1.0 - sqrt(1.0 - x * x));
		float disc = smoothstep(1.18, 0.72, sd / sun_r);
		col += sun_col * disc * limb * 24.0;
	}
	col += sun_col * pow(max(mu, 0.0), 140.0) * 0.78 + sun_col * pow(max(mu, 0.0), 28.0) * 0.24 * 0.45;
	if (cirrus_on > 0.5) {
		vec4 ci = cirrus(dir, POSITION);
		col = mix(col, ci.rgb, ci.a);
	}
	col = clamp(mix(col, vec3(0.0), isnan(col)), vec3(0.0), vec3(200.0));
	float fz = max(dot(dir, cam_fwd), 1e-3);
	float aspect = view_size.x / max(view_size.y, 1.0);
	vec2 ndc = vec2(dot(dir, cam_right) / (fz * tan_half_fov * aspect), dot(dir, cam_up) / (fz * tan_half_fov));
	COLOR = w_grade(col, ndc * 0.5 + 0.5, view_size);
}
