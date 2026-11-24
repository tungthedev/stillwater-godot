extends Node3D

# Sun, sky and the light values the terrain and sky shaders share, fixed at hour 16 like the
# Stillwater bench poses. Sun direction and colours are ports of src/env.js; the hemisphere
# colours and exposure are what Stillwater computes at hour 16 from its sky LUT (read back by
# tools/shoot_stillwater.mjs into captures/slice2/stillwater_values.json).
#
# The environment tonemapper is linear with exposure 1: terrain and sky apply Stillwater's own
# exposure, tone curve and grade in their shaders. The sun light here is for Godot-lit
# placeholders (test grass) and its shadow toggle.

const HOURS := 16.0
const LAT := deg_to_rad(46.0)
const DECL := deg_to_rad(17.0)
const HEMI_SKY := Vector3(0.4036, 0.6208, 0.9223)
const HEMI_GROUND := Vector3(0.2488, 0.2827, 0.2194)
const EXPOSURE := 0.6

var sun: DirectionalLight3D
var sun_dir := Vector3.UP
var sun_col := Vector3.ONE
var light_col := Vector3.ONE
var sky_mat: ShaderMaterial
# Every material that ends in w_grade, so the post switch reaches all of them.
var mats: Array[ShaderMaterial] = []
var post_on := false


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
	var env := Environment.new()
	env.background_mode = Environment.BG_SKY
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


# Values every Stillwater-look shader reads (shaders/stillwater.gdshaderinc).
func apply_to(mat: ShaderMaterial) -> void:
	mat.set_shader_parameter("sun_dir", sun_dir)
	mat.set_shader_parameter("sun_col", sun_col)
	mat.set_shader_parameter("light_col", light_col)
	mat.set_shader_parameter("exposure", EXPOSURE)
	mat.set_shader_parameter("post_on", 1.0 if post_on else 0.0)
	if not mats.has(mat):
		mats.append(mat)


func set_post(on: bool) -> void:
	post_on = on
	for m in mats:
		m.set_shader_parameter("post_on", 1.0 if on else 0.0)


# Sky LUT and noise; the cirrus values are the hour-16 ones (captures/slice2/stillwater_values.json),
# set explicitly because sky-shader uniform defaults are not applied in this renderer.
func set_sky(lut: Texture2D, noise: Texture2D) -> void:
	sky_mat.set_shader_parameter("sky_lut", lut)
	sky_mat.set_shader_parameter("noise_tex", noise)
	sky_mat.set_shader_parameter("cloud_offset", Vector2(-223.16, -143.45))
	sky_mat.set_shader_parameter("wind_dir", Vector2(0.8253, 0.5646))
	apply_to(sky_mat)


# Script time of this frame's _process, for the bench.
var prof_us := 0


func _process(delta: float) -> void:
	var t0 := Time.get_ticks_usec()
	_tick(delta)
	prof_us = Time.get_ticks_usec() - t0


func _tick(_delta: float) -> void:
	sky_mat.set_shader_parameter("view_size", get_viewport().get_visible_rect().size)
	var cam := get_viewport().get_camera_3d()
	if cam != null:
		var b := cam.global_transform.basis
		sky_mat.set_shader_parameter("cam_right", b.x)
		sky_mat.set_shader_parameter("cam_up", b.y)
		sky_mat.set_shader_parameter("cam_fwd", -b.z)
		sky_mat.set_shader_parameter("tan_half_fov", tan(deg_to_rad(cam.fov) * 0.5))
