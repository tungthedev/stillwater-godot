// Stillwater's far-tree impostors (src/world/treeImpostor.js makeImpostorMaterial) on Godot.
//
// One camera-facing quad per tree, one instanced draw per 1024 m cell. The instance transform is
// the tree's own (position, rotation about +Y, scale (s * sx, s, s * sx)); INSTANCE_CUSTOM is
// (tint rgb, species index in the atlas). The quad picks the nearest of 8 x 3 baked views of its
// species. Trees whose 64 m cell draws as mid or hero geometry (green flag in the shared
// cell-flag texture) collapse to a point.
//
// The atlas is Stillwater's own bake (tools/bake_impostors.mjs): albedo stored gamma-2 and both
// textures premultiplied by coverage, so the shader divides by alpha.
shader_type spatial;
render_mode unshaded, fog_disabled, cull_disabled, depth_draw_opaque, skip_vertex_transform;

#include "res://shaders/stillwater.gdshaderinc"
#include "res://shaders/atmosphere.gdshaderinc"

const float IMP_AZ = 8.0;
const float IMP_VIEWS = 24.0;

uniform sampler2D imp_albedo : filter_linear_mipmap, repeat_disable;
uniform sampler2D imp_normal : filter_linear_mipmap, repeat_disable;
uniform vec4 imp_frames[5];
uniform vec4 imp_grid;
uniform float imp_atlas_px = 1024.0;
uniform sampler2D tree_cells : filter_nearest, repeat_disable;
uniform vec2 tree_cell_origin;
uniform float wind_strength = 0.5;

varying vec2 v_uv;
varying vec2 v_tile;
varying vec3 v_tint;
varying vec3 v_right;
varying vec3 v_up;
varying vec3 v_to_cam;
varying float v_y;
varying vec3 v_wpos;

void vertex() {
	vec3 pos = MODEL_MATRIX[3].xyz;
	vec3 bx = MODEL_MATRIX[0].xyz;
	float sw = length(bx);
	float sh = length(MODEL_MATRIX[1].xyz);
	float cr = bx.x / sw;
	float sr = -bx.z / sw;
	vec4 fr = imp_frames[int(INSTANCE_CUSTOM.a + 0.5)];
	vec3 impC = pos + vec3(0.0, fr.y * sh, 0.0);
	vec3 impTo = CAMERA_POSITION_WORLD - impC;
	float impDist = length(impTo);
	vec3 toCam = impTo / max(impDist, 1e-3);
	vec3 right = normalize(cross(vec3(0.0, 1.0, 0.0), toCam) + vec3(1e-5, 0.0, 0.0));
	vec3 upv = cross(toCam, right);
	vec3 l = vec3(toCam.x * cr - toCam.z * sr, toCam.y, toCam.x * sr + toCam.z * cr);
	float azF = atan(l.x, l.z);
	if (azF < 0.0) {
		azF += 6.2831853;
	}
	float az = mod(floor(azF / (6.2831853 / IMP_AZ) + 0.5), IMP_AZ);
	float elev = atan(l.y, length(l.xz));
	float el = 0.0;
	// IMPOSTOR_ELEVATIONS [0, 0.5, 1.05]: switch at the midpoints.
	if (elev > 0.25) {
		el = 1.0;
	}
	if (elev > 0.775) {
		el = 2.0;
	}
	float idx = INSTANCE_CUSTOM.a * IMP_VIEWS + el * IMP_AZ + az;
	v_tile = vec2(mod(idx, imp_grid.x), floor(idx / imp_grid.x));
	v_uv = VERTEX.xy + 0.5;
	v_tint = INSTANCE_CUSTOM.rgb;
	v_right = right;
	v_up = upv;
	v_to_cam = toCam;
	v_y = VERTEX.y + 0.5;
	// Far forests merge into masses instead of thinning to dots as alpha-tested mips shrink.
	float expand = mix(1.0, 1.22, smoothstep(350.0, 1600.0, impDist));
	float sway = sin(TIME * 0.9 + pos.x * 0.071 + pos.z * 0.053) * 0.012 * (0.4 + wind_strength) * max(VERTEX.y + 0.1, 0.0);
	vec3 w = impC
		+ right * (VERTEX.x * 2.0 * fr.w * sw * expand + sway * sh)
		+ upv * (VERTEX.y * 2.0 * fr.w * sh * expand);
	v_wpos = w;
	vec2 cell = (floor(pos.xz / 64.0) + 0.5) * 64.0;
	float midOn = texelFetch(tree_cells, ivec2(floor(cell / 32.0) - tree_cell_origin), 0).g;
	VERTEX = midOn > 0.5 ? vec3(0.0) : (VIEW_MATRIX * vec4(w, 1.0)).xyz;
}

void fragment() {
	vec2 tuv = (v_tile + imp_grid.z + v_uv * (1.0 - 2.0 * imp_grid.z)) * imp_grid.y;
	vec2 px = tuv * imp_atlas_px;
	vec2 ddx = dFdx(px);
	vec2 ddy = dFdy(px);
	float lod = clamp(0.5 * log2(max(dot(ddx, ddx), dot(ddy, ddy))), 0.0, imp_grid.w);
	vec4 alb = textureLod(imp_albedo, tuv, lod);
	// Keep coverage as the alpha-tested mips average leaves away.
	if (alb.a * (1.0 + lod * 0.45) < 0.5) {
		discard;
	}
	vec4 nrmA = textureLod(imp_normal, tuv, lod);
	vec3 nrm = nrmA.xyz / max(nrmA.a, 1e-3) * 2.0 - 1.0;
	vec3 impN = normalize(v_right * nrm.x + v_up * nrm.y + v_to_cam * nrm.z);
	vec3 base = alb.rgb / max(alb.a, 1e-3);
	base *= base;
	base *= v_tint;
	// Valley-scale hue swells so distant forests read as colour masses, not repeated stamps.
	float macH = texture(noise_tex, v_wpos.xz * 0.0011 + 0.27).r;
	base = mix(base, base * vec3(0.80, 0.97, 1.12), smoothstep(0.48, 0.78, macH) * 0.45);
	base = mix(base, base * vec3(1.14, 1.06, 0.80), smoothstep(0.50, 0.80, 1.0 - macH) * 0.38);
	float sunSide = clamp(dot(impN, sun_dir) * 0.5 + 0.5, 0.0, 1.0);
	float litMask = smoothstep(0.20, 0.78, sunSide * 0.62 + v_y * 0.28);
	vec3 dcol = mix(base * vec3(0.46, 0.82, 1.24), base * vec3(1.18, 1.22, 0.72), litMask);

	vec3 cam = CAMERA_POSITION_WORLD;
	float dist = length(v_wpos - cam);
	float sun_vis = w_cloud_shadow(v_wpos, cam);
	float ramp = w_toon_ramp(dot(impN, sun_dir), 0.48, 0.14, 0.56, dist);
	vec3 lit = ramp * light_col * sun_vis * dcol / PI + w_indirect(impN, dcol);
	{
		vec3 Vw = normalize(v_wpos - cam);
		float sl = sun_vis * smoothstep(-0.02, 0.08, sun_dir.y);
		float back = pow(max(dot(Vw, sun_dir), 0.0), 3.6);
		lit += dcol * light_col * vec3(0.95, 1.02, 0.68) * back * 0.14 * sl;
		lit += dcol * vec3(0.84, 1.0, 0.74) * 0.036 * length(light_col);
	}
	vec3 atm_mul;
	vec3 atm_add;
	w_atmosphere(v_wpos, cam, atm_mul, atm_add);
	ALBEDO = w_grade(lit * atm_mul + atm_add, SCREEN_UV, VIEWPORT_SIZE);
}
