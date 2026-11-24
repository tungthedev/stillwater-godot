// Stillwater's sky dome (src/world/sky.js) at hour 16: the sky-view LUT read back from the game,
// its saturation and pale-horizon styling, and the sun disc and glow. Cirrus wisps, stars and the
// moon are not ported. Graded like the terrain (see stillwater.gdshaderinc).
shader_type sky;

#include "res://shaders/stillwater.gdshaderinc"

// SCREEN_UV is not usable in sky shaders on this renderer, so the vignette's screen position is
// found by projecting EYEDIR with the camera basis (set every frame by systems/environment.gd).
uniform vec2 view_size;
uniform vec3 cam_right;
uniform vec3 cam_up;
uniform vec3 cam_fwd;
uniform float tan_half_fov;

void sky() {
	vec3 dir = EYEDIR;
	vec3 col = w_sky(vec3(dir.x, max(dir.y, -0.02), dir.z));
	float lum_s = w_luma(col);
	col = mix(vec3(lum_s), col, 1.40);
	float hz = exp(-max(dir.y, 0.0) * 8.5);
	col = mix(col, vec3(lum_s) * vec3(0.96, 1.0, 1.04) * 1.15, hz * 0.32);
	col = max(col, vec3(0.0));
	col.g = min(col.g, (col.r + col.b) * 0.6);
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
	float fz = max(dot(dir, cam_fwd), 1e-3);
	float aspect = view_size.x / max(view_size.y, 1.0);
	vec2 ndc = vec2(dot(dir, cam_right) / (fz * tan_half_fov * aspect), dot(dir, cam_up) / (fz * tan_half_fov));
	COLOR = w_grade(col, ndc * 0.5 + 0.5, view_size);
}
