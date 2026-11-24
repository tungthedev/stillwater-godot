extends Node3D

# Sun, sky and the light values the terrain and sky shaders share, fixed at hour 16 like the
# Stillwater bench poses. Sun direction and colours are ports of src/env.js; the hemisphere
# colours and exposure are what Stillwater computes at hour 16 from its sky LUT (read back by
# tools/shoot_stillwater.mjs into captures/slice2/stillwater_values.json).
#
# The environment tonemapper is linear with exposure 1: terrain and sky apply Stillwater's own
# exposure, tone curve and grade in their shaders. The sun light here is for Godot-lit
# placeholders (test grass) and its shadow toggle.

const Flags := preload("res://systems/flags.gd")
const HOURS := 16.0
const LAT := deg_to_rad(46.0)
const DECL := deg_to_rad(17.0)
const HEMI_SKY := Vector3(0.4036, 0.6208, 0.9223)
const HEMI_GROUND := Vector3(0.2488, 0.2827, 0.2194)
const EXPOSURE := 0.6

# Painterly palette at hour 16, held in vars below so a time of day can drive them.
const PAINTERLY_HEMI_SKY := Vector3(0.41, 0.58, 0.94)
const PAINTERLY_HEMI_GROUND := Vector3(0.34, 0.35, 0.56)
const PAINTERLY_SHADOW_TINT := Vector3(0.92, 0.92, 1.20)
const PAINTERLY_AMBIENT_BOOST := 1.12
const PAINTERLY_LIGHT_FLOOR_COL := Vector3(0.42, 0.50, 0.72)
const PAINTERLY_LIGHT_FLOOR := 0.45
const PAINTERLY_HORIZON_TINT := Vector3(0.95, 0.99, 1.07)
const PAINTERLY_SKY_SAT := 1.38
const PAINTERLY_HORIZON_HAZE := 0.34
const PAINTERLY_DIRECT_SCALE := 0.96
const CLOUD_LIT_COL := Vector3(2.55, 2.38, 2.15)
const CLOUD_SHADOW_COL := Vector3(0.62, 0.78, 1.32)
const CLOUD_RIM_COL := Vector3(3.10, 2.65, 1.95)
const PAINTERLY_TRICKS: Array[String] = [
	"light_floor",
	"cool_shadows",
	"matte",
	"horizon_fog",
	"painted_clouds",
	"tree_cores_first",
	"card_edge_fade",
	"cheap_bark",
	"puff_mid_crowns",
]

var style := "painterly"
var painterly := true
var sun: DirectionalLight3D
var sun_dir := Vector3.UP
var sun_col := Vector3.ONE
var light_col := Vector3.ONE
var hemi_sky := PAINTERLY_HEMI_SKY
var hemi_ground := PAINTERLY_HEMI_GROUND
var shadow_ambient_tint := PAINTERLY_SHADOW_TINT
var ambient_boost := PAINTERLY_AMBIENT_BOOST
var light_floor_col := PAINTERLY_LIGHT_FLOOR_COL
var light_floor := PAINTERLY_LIGHT_FLOOR
var horizon_tint := PAINTERLY_HORIZON_TINT
var sky_sat := PAINTERLY_SKY_SAT
var horizon_haze := PAINTERLY_HORIZON_HAZE
var cloud_lit_col := CLOUD_LIT_COL
var cloud_shadow_col := CLOUD_SHADOW_COL
var cloud_rim_col := CLOUD_RIM_COL
var sky_mat: ShaderMaterial
var env: Environment
# Every material that ends in w_grade, so the post switch reaches all of them.
var mats: Array[ShaderMaterial] = []
var post_on := false
var sky_flat := false
var cirrus_on := true
var sky_clouds_on := true
var frozen := false


func _init() -> void:
	style = Flags.style()
	painterly = style != "classic"
	hemi_sky = PAINTERLY_HEMI_SKY if painterly else HEMI_SKY
	hemi_ground = PAINTERLY_HEMI_GROUND if painterly else HEMI_GROUND


func active_tricks() -> Array[String]:
	return PAINTERLY_TRICKS.duplicate() if painterly else []


# src/env.js sunDirection: +x east, +z south, y up; returns the direction towards the sun.
static func sun_direction(hours: float) -> Vector3:
	var h := (hours - 12.0) / 24.0 * TAU
	var e := -cos(DECL) * sin(h)
	var n := cos(LAT) * sin(DECL) - sin(LAT) * cos(DECL) * cos(h)
	var up := sin(LAT) * sin(DECL) + cos(LAT) * cos(DECL) * cos(h)
	return Vector3(e, up, -n).normalized()


# src/env.js transmittance + the stylised gold shift + daytime light colour (sun above horizon,
# not golden hour, so the moon and low-sun branches are not needed).
static func sun_colours(dir: Vector3) -> Array[Vector3]:
	var beta_r := Vector3(5.802e-6, 13.558e-6, 33.1e-6) * 8000.0
	var beta_m := 8.0e-6 * 1200.0 * 1.11
	var zen := PI / 2.0 - maxf(asin(dir.y), -0.05)
	var zdeg := rad_to_deg(zen)
	var m := 1.0 / (cos(zen) + 0.50572 * pow(maxf(96.07995 - zdeg, 0.01), -1.6364))
	var t := Vector3(exp(-(beta_r.x + beta_m) * m), exp(-(beta_r.y + beta_m) * m), exp(-(beta_r.z + beta_m) * m))
	var mx := maxf(t.x, 1e-4)
	var tc := (t / mx).lerp(Vector3(1.0, 0.65, 0.34), 0.58)
	var sc := tc * mx
	var ss := func(a: float, b: float, x: float) -> float:
		var u := clampf((x - a) / (b - a), 0.0, 1.0)
		return u * u * (3.0 - 2.0 * u)
	var k: float = 7.6 * ss.call(-0.035, 0.02, dir.y) * (1.0 + 0.85 * ss.call(0.28, 0.03, dir.y))
	var lc := sc * k
	var l := lc.x * 0.3 + lc.y * 0.55 + lc.z * 0.15
	lc = lc.lerp(Vector3(l * 1.06, l * 0.98, l * 0.88), 0.14)
	return [sc, lc]


func _ready() -> void:
	# After the camera has moved this frame (the sky vignette follows it).
	process_priority = 100
	sun_dir = sun_direction(HOURS)
	var cols := sun_colours(sun_dir)
	sun_col = cols[0]
	light_col = cols[1]

	sky_mat = ShaderMaterial.new()
	sky_mat.shader = load("res://shaders/sky.gdshader")
	var sky := Sky.new()
	sky.sky_material = sky_mat
	sky.radiance_size = Sky.RADIANCE_SIZE_32
	# Keep sky process mode static so Godot never treats the sky as real-time radiance work.
	sky.process_mode = Sky.PROCESS_MODE_QUALITY
	env = Environment.new()
	env.background_mode = Environment.BG_SKY
	env.background_color = Color(0.32, 0.56, 0.88)
	env.sky = sky
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.5 * (HEMI_SKY.x + HEMI_GROUND.x), 0.5 * (HEMI_SKY.y + HEMI_GROUND.y), 0.5 * (HEMI_SKY.z + HEMI_GROUND.z))
	env.reflected_light_source = Environment.REFLECTION_SOURCE_DISABLED
	env.tonemap_mode = Environment.TONE_MAPPER_LINEAR
	env.tonemap_exposure = 1.0
	env.fog_enabled = false
	var we := WorldEnvironment.new()
	we.environment = env
	add_child(we)

	sun = DirectionalLight3D.new()
	add_child(sun)
	# A directional light shines along its -Z.
	sun.look_at(sun.global_position - sun_dir, Vector3.UP)
	var peak := maxf(light_col.x, maxf(light_col.y, light_col.z))
	sun.light_color = Color(light_col.x / peak, light_col.y / peak, light_col.z / peak)
	sun.light_energy = peak / PI * EXPOSURE
	# Off by default: every Godot material here is unshaded and casts nothing, so the map would be
	# empty work. Stillwater's side of the comparison runs with no=shadow (docs/compare.md).
	sun.shadow_enabled = false
	sun.directional_shadow_max_distance = 80.0


# Values every Stillwater-look shader reads (shaders/stillwater.gdshaderinc, atmosphere.gdshaderinc,
# clouds.gdshader). Set explicitly on every material including sky_mat because sky-shader uniform
# defaults are not applied in the Compatibility renderer.
func apply_to(mat: ShaderMaterial) -> void:
	var active_light := light_col * (PAINTERLY_DIRECT_SCALE if painterly else 1.0)
	mat.set_shader_parameter("sun_dir", sun_dir)
	mat.set_shader_parameter("sun_col", sun_col)
	mat.set_shader_parameter("light_col", active_light)
	mat.set_shader_parameter("exposure", EXPOSURE)
	mat.set_shader_parameter("post_on", 1.0 if post_on else 0.0)
	mat.set_shader_parameter("painterly", 1.0 if painterly else 0.0)
	mat.set_shader_parameter("horizon_tint", horizon_tint)
	mat.set_shader_parameter("sky_sat", sky_sat)
	mat.set_shader_parameter("horizon_haze", horizon_haze)
	mat.set_shader_parameter("hemi_sky", hemi_sky)
	mat.set_shader_parameter("hemi_ground", hemi_ground)
	mat.set_shader_parameter("shadow_ambient_tint", shadow_ambient_tint)
	mat.set_shader_parameter("ambient_boost", ambient_boost)
	mat.set_shader_parameter("light_floor_col", light_floor_col)
	mat.set_shader_parameter("light_floor", light_floor)
	mat.set_shader_parameter("cloud_lit_col", cloud_lit_col)
	mat.set_shader_parameter("cloud_shadow_col", cloud_shadow_col)
	mat.set_shader_parameter("cloud_rim_col", cloud_rim_col)
	if not mats.has(mat):
		mats.append(mat)


func set_post(on: bool) -> void:
	post_on = on
	if not on:
		_sky_cam_valid = false
	for m in mats:
		m.set_shader_parameter("post_on", 1.0 if on else 0.0)


func set_sky_flat(on: bool) -> void:
	sky_flat = on
	if env != null:
		env.background_mode = Environment.BG_COLOR if on else Environment.BG_SKY


func set_cirrus_on(on: bool) -> void:
	cirrus_on = on
	if sky_mat != null:
		sky_mat.set_shader_parameter("cirrus_on", 1.0 if on else 0.0)


func set_sky_clouds_on(on: bool) -> void:
	sky_clouds_on = on
	if sky_mat != null:
		sky_mat.set_shader_parameter("sky_clouds_on", 1.0 if on else 0.0)


func set_style(s: String) -> void:
	style = "classic" if s == "classic" else "painterly"
	painterly = style != "classic"
	hemi_sky = PAINTERLY_HEMI_SKY if painterly else HEMI_SKY
	hemi_ground = PAINTERLY_HEMI_GROUND if painterly else HEMI_GROUND
	var active_light := light_col * (PAINTERLY_DIRECT_SCALE if painterly else 1.0)
	for m in mats:
		m.set_shader_parameter("light_col", active_light)
		m.set_shader_parameter("painterly", 1.0 if painterly else 0.0)
		m.set_shader_parameter("hemi_sky", hemi_sky)
		m.set_shader_parameter("hemi_ground", hemi_ground)


# Sky LUT and noise; the cirrus values are the hour-16 ones (captures/slice2/stillwater_values.json),
# set explicitly because sky-shader uniform defaults are not applied in this renderer.
func set_sky(lut: Texture2D, noise: Texture2D) -> void:
	sky_mat.set_shader_parameter("sky_lut", lut)
	sky_mat.set_shader_parameter("noise_tex", noise)
	sky_mat.set_shader_parameter("cloud_offset", Vector2(-223.16, -143.45))
	sky_mat.set_shader_parameter("wind_dir", Vector2(0.8253, 0.5646))
	sky_mat.set_shader_parameter("cloud_cover", 0.329)
	sky_mat.set_shader_parameter("cirrus_on", 1.0 if cirrus_on else 0.0)
	sky_mat.set_shader_parameter("sky_clouds_on", 1.0 if sky_clouds_on else 0.0)
	apply_to(sky_mat)


# Script time of this frame's _process, for the bench.
var prof_us := 0
var _sky_cam_valid := false
var _last_view := Vector2.ZERO
var _last_basis := Basis.IDENTITY
var _last_fov := -1.0


func set_frozen(v: bool) -> void:
	frozen = v


func _process(delta: float) -> void:
	var t0 := Time.get_ticks_usec()
	if not frozen:
		_tick(delta)
	prof_us = Time.get_ticks_usec() - t0


func _tick(_delta: float) -> void:
	# Sky shader only uses view_size and camera basis for the LDR vignette when post is off.
	if post_on or sky_flat:
		return
	var vs := get_viewport().get_visible_rect().size
	if not _sky_cam_valid or vs != _last_view:
		_last_view = vs
		sky_mat.set_shader_parameter("view_size", vs)
	var cam := get_viewport().get_camera_3d()
	if cam != null:
		var b := cam.global_transform.basis
		if not _sky_cam_valid or b != _last_basis:
			_last_basis = b
			sky_mat.set_shader_parameter("cam_right", b.x)
			sky_mat.set_shader_parameter("cam_up", b.y)
			sky_mat.set_shader_parameter("cam_fwd", -b.z)
		if not _sky_cam_valid or cam.fov != _last_fov:
			_last_fov = cam.fov
			sky_mat.set_shader_parameter("tan_half_fov", tan(deg_to_rad(cam.fov) * 0.5))
		_sky_cam_valid = true
