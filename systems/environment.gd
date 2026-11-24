extends Node3D

# Sun, moon, sky, atmosphere and mood ramps shared by every shader (W5).
#
# Noon (hour 16.0) keeps sky_analytic = 0.0 and uses the prebaked sky_lut_16h.rgbh identically
# to the baseline, guaranteeing zero noon drift. The other presets (golden, dawn, dusk, night,
# mist) and continuous diurnal hours blend to a cheap Genshin-style analytic sky + fog + grade
# ramp via uniforms only: zero per-frame LUT rebuilds, zero radiance-map rebuilds, zero ground
# re-bakes. Every preset honours S1's light floor so foliage and terrain never crush to black.

const Flags := preload("res://systems/flags.gd")

const HOURS := 16.0
const LAT := deg_to_rad(46.0)
const DECL := deg_to_rad(17.0)
const HEMI_SKY := Vector3(0.4036, 0.6208, 0.9223)
const HEMI_GROUND := Vector3(0.2488, 0.2827, 0.2194)
const EXPOSURE := 0.6
const DEFAULT_TIME_SCALE := 6.0 # 6 game-minutes per real minute (1 full day in 24 real min)

# Painterly palette at hour 16 (noon default).
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
const DEFAULT_FOG_BETA := Vector3(2.4e-5, 4.6e-5, 1.18e-4)
const DEFAULT_MIST := 0.028
const DEFAULT_CLOUD_COVER := 0.329
const DEFAULT_GRADE_SHADOW_TINT := Vector3(0.88, 0.90, 1.20)
const DEFAULT_GRADE_SHADOW_CAST := Vector3(0.93, 0.92, 1.14)
const DEFAULT_GRADE_LIFT := Vector3(0.006, 0.006, 0.016)

const TOD_PRESETS: Array[String] = ["noon", "golden", "dawn", "dusk", "night", "mist"]

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
	"painted_grass",
	"painted_water",
	"painted_rocks",
	"painted_props",
	"painted_undergrowth",
	"painted_air",
	"tod_presets",
	"night_pools",
	"painted_fauna",
	"chimney_smoke",
]

var style := "painterly"
var painterly := true
var sun: DirectionalLight3D

# Active time-of-day state.
var tod_preset := "noon"
var hours := HOURS
var cycle_enabled := false
var time_scale := DEFAULT_TIME_SCALE
var hurry := false
var _last_pushed_hours := -999.0

# Shared shader uniforms pushed to all registered materials.
var sun_dir := Vector3.UP
var sun_col := Vector3.ONE
var light_col := Vector3.ONE
var moon_dir := Vector3(0.42, 0.44, -0.79).normalized()
var sun_disc_vis := 1.0
var moon_vis := 0.0
var night_weight := 0.0
var night_glow := 0.0
var mist_weight := 0.0
var exposure := EXPOSURE
var sky_analytic := 0.0
var sky_zenith_col := Vector3(0.18, 0.42, 0.92)
var sky_mid_col := Vector3(0.45, 0.68, 1.05)
var sky_horizon_col := Vector3(0.95, 1.02, 1.14)
var sky_glow_col := Vector3(0.65, 0.52, 0.35)

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
var fog_beta := DEFAULT_FOG_BETA
var mist := DEFAULT_MIST
var valley_mist_mult := 1.0
var cloud_cover := DEFAULT_CLOUD_COVER

var grade_wb := Vector3.ONE
var grade_shadow_tint := DEFAULT_GRADE_SHADOW_TINT
var grade_shadow_cast := DEFAULT_GRADE_SHADOW_CAST
var grade_lift_u := DEFAULT_GRADE_LIFT
var grade_sat_u := 1.12
var grade_contrast_u := 0.08
var day_fresh_k := 1.0

var sky_mat: ShaderMaterial
var env: Environment
# Every material that ends in w_grade, so post and time-of-day reach all of them.
var mats: Array[ShaderMaterial] = []
var tod_listeners: Array[Callable] = []
var post_on := false
var sky_flat := false
var cirrus_on := true
var sky_clouds_on := false
var valley_mist_on := true
var frozen := false


func _init() -> void:
	style = Flags.style()
	painterly = style != "classic"
	hemi_sky = PAINTERLY_HEMI_SKY if painterly else HEMI_SKY
	hemi_ground = PAINTERLY_HEMI_GROUND if painterly else HEMI_GROUND


func active_tricks() -> Array[String]:
	return PAINTERLY_TRICKS.duplicate() if painterly else []


# src/env.js sunDirection: +x east, +z south, y up; returns the direction towards the sun.
static func sun_direction(h_val: float) -> Vector3:
	var h := (h_val - 12.0) / 24.0 * TAU
	var e := -cos(DECL) * sin(h)
	var n := cos(LAT) * sin(DECL) - sin(LAT) * cos(DECL) * cos(h)
	var up := sin(LAT) * sin(DECL) + cos(LAT) * cos(DECL) * cos(h)
	return Vector3(e, up, -n).normalized()


# Smooth moon path arcing high over the northern peaks so moonlit ridges, lake & sheep read clearly.
static func moon_direction(h_val: float) -> Vector3:
	var phase := (h_val - 22.5) / 24.0 * TAU
	return Vector3(-0.34 - sin(phase) * 0.42, clampf(0.46 + cos(phase) * 0.16, 0.24, 0.64), -0.82 + sin(phase) * 0.18).normalized()


# src/env.js transmittance + the stylised gold shift + daytime light colour.
static func sun_colours(dir: Vector3) -> Array[Vector3]:
	var beta_r := Vector3(5.802e-6, 13.558e-6, 33.1e-6) * 8000.0
	var beta_m := 8.0e-6 * 1200.0 * 1.11
	var zen := PI / 2.0 - maxf(asin(clampf(dir.y, -1.0, 1.0)), -0.05)
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


# Six Genshin-inspired mood presets honouring S1's light floor (foliage & ground never crush black).
static func _preset_spec(name: String) -> Dictionary:
	var noon_dir := sun_direction(HOURS)
	var noon_cols := sun_colours(noon_dir)
	match name:
		"golden":
			var d := sun_direction(18.35)
			return {
				"hours": 18.35, "sun_dir": d, "sun_col": Vector3(1.10, 0.62, 0.24),
				"light_col": Vector3(6.85, 3.85, 1.65), "sun_disc_vis": 1.0, "moon_vis": 0.0,
				"night_weight": 0.0, "night_glow": 0.32, "mist_weight": 0.0, "exposure": 0.62,
				"sky_analytic": 1.0,
				"sky_zenith_col": Vector3(0.22, 0.42, 0.88),
				"sky_mid_col": Vector3(0.56, 0.64, 0.94),
				"sky_horizon_col": Vector3(1.62, 0.92, 0.46),
				"sky_glow_col": Vector3(1.85, 0.86, 0.30),
				"hemi_sky": Vector3(0.46, 0.50, 0.80), "hemi_ground": Vector3(0.44, 0.34, 0.38),
				"shadow_ambient_tint": Vector3(0.92, 0.85, 1.16), "ambient_boost": 1.14,
				"light_floor_col": Vector3(0.48, 0.44, 0.64), "light_floor": 0.46,
				"horizon_tint": Vector3(1.06, 0.94, 0.84), "sky_sat": 1.32, "horizon_haze": 0.44,
				"cloud_lit_col": Vector3(2.85, 2.05, 1.35),
				"cloud_shadow_col": Vector3(0.68, 0.62, 1.05),
				"cloud_rim_col": Vector3(3.60, 2.25, 1.05),
				"fog_beta": Vector3(2.8e-5, 5.2e-5, 1.15e-4), "mist": 0.045, "valley_mist_mult": 1.25,
				"cloud_cover": 0.35,
				"grade_wb": Vector3(1.04, 1.00, 0.94),
				"grade_shadow_tint": Vector3(0.90, 0.87, 1.18),
				"grade_shadow_cast": Vector3(0.95, 0.90, 1.12),
				"grade_lift_u": Vector3(0.008, 0.006, 0.014),
				"grade_sat_u": 1.15, "grade_contrast_u": 0.09, "day_fresh_k": 0.60,
			}
		"dawn":
			var d := sun_direction(5.55)
			return {
				"hours": 5.55, "sun_dir": d, "sun_col": Vector3(1.04, 0.68, 0.48),
				"light_col": Vector3(4.80, 3.25, 2.35), "sun_disc_vis": 1.0, "moon_vis": 0.12,
				"night_weight": 0.08, "night_glow": 0.35, "mist_weight": 0.35, "exposure": 0.65,
				"sky_analytic": 1.0,
				"sky_zenith_col": Vector3(0.18, 0.32, 0.76),
				"sky_mid_col": Vector3(0.48, 0.56, 0.92),
				"sky_horizon_col": Vector3(1.52, 0.98, 0.86),
				"sky_glow_col": Vector3(1.55, 0.88, 0.62),
				"hemi_sky": Vector3(0.44, 0.48, 0.78), "hemi_ground": Vector3(0.36, 0.34, 0.48),
				"shadow_ambient_tint": Vector3(0.94, 0.88, 1.18), "ambient_boost": 1.16,
				"light_floor_col": Vector3(0.46, 0.46, 0.68), "light_floor": 0.48,
				"horizon_tint": Vector3(1.04, 0.95, 0.98), "sky_sat": 1.28, "horizon_haze": 0.48,
				"cloud_lit_col": Vector3(2.40, 1.85, 1.65),
				"cloud_shadow_col": Vector3(0.56, 0.58, 0.98),
				"cloud_rim_col": Vector3(3.10, 2.10, 1.55),
				"fog_beta": Vector3(3.4e-5, 5.2e-5, 1.10e-4), "mist": 0.068, "valley_mist_mult": 1.45,
				"cloud_cover": 0.36,
				"grade_wb": Vector3(1.02, 0.99, 1.01),
				"grade_shadow_tint": Vector3(0.90, 0.88, 1.20),
				"grade_shadow_cast": Vector3(0.95, 0.91, 1.15),
				"grade_lift_u": Vector3(0.008, 0.007, 0.018),
				"grade_sat_u": 1.12, "grade_contrast_u": 0.07, "day_fresh_k": 0.45,
			}
		"dusk":
			var d := sun_direction(19.55)
			if d.y < 0.06:
				d = Vector3(d.x, 0.06, d.z).normalized()
			return {
				"hours": 19.55, "sun_dir": d, "sun_col": Vector3(1.05, 0.48, 0.24),
				"light_col": Vector3(2.85, 1.52, 0.98), "sun_disc_vis": 0.85, "moon_vis": 0.45,
				"night_weight": 0.38, "night_glow": 0.90, "mist_weight": 0.15, "exposure": 0.72,
				"sky_analytic": 1.0,
				"sky_zenith_col": Vector3(0.09, 0.13, 0.38),
				"sky_mid_col": Vector3(0.30, 0.28, 0.64),
				"sky_horizon_col": Vector3(1.26, 0.56, 0.42),
				"sky_glow_col": Vector3(1.45, 0.52, 0.26),
				"hemi_sky": Vector3(0.32, 0.36, 0.70), "hemi_ground": Vector3(0.24, 0.24, 0.42),
				"shadow_ambient_tint": Vector3(0.90, 0.86, 1.22), "ambient_boost": 1.20,
				"light_floor_col": Vector3(0.38, 0.42, 0.68), "light_floor": 0.50,
				"horizon_tint": Vector3(1.04, 0.88, 0.96), "sky_sat": 1.25, "horizon_haze": 0.44,
				"cloud_lit_col": Vector3(1.95, 1.08, 0.88),
				"cloud_shadow_col": Vector3(0.34, 0.34, 0.72),
				"cloud_rim_col": Vector3(2.90, 1.40, 0.76),
				"fog_beta": Vector3(3.4e-5, 5.0e-5, 1.12e-4), "mist": 0.048, "valley_mist_mult": 1.20,
				"cloud_cover": 0.36,
				"grade_wb": Vector3(1.02, 0.98, 1.04),
				"grade_shadow_tint": Vector3(0.86, 0.86, 1.22),
				"grade_shadow_cast": Vector3(0.90, 0.90, 1.18),
				"grade_lift_u": Vector3(0.010, 0.010, 0.024),
				"grade_sat_u": 1.12, "grade_contrast_u": 0.07, "day_fresh_k": 0.15,
			}
		"night":
			var md := moon_direction(22.5)
			return {
				"hours": 22.5, "sun_dir": md, "sun_col": Vector3(0.55, 0.72, 1.05),
				"light_col": Vector3(0.88, 1.16, 1.95), "sun_disc_vis": 0.0, "moon_vis": 1.0,
				"night_weight": 1.0, "night_glow": 1.0, "mist_weight": 0.12, "exposure": 0.68,
				"sky_analytic": 1.0,
				"sky_zenith_col": Vector3(0.026, 0.050, 0.170),
				"sky_mid_col": Vector3(0.058, 0.104, 0.290),
				"sky_horizon_col": Vector3(0.118, 0.198, 0.430),
				"sky_glow_col": Vector3(0.16, 0.24, 0.48),
				"hemi_sky": Vector3(0.19, 0.28, 0.58), "hemi_ground": Vector3(0.14, 0.19, 0.38),
				"shadow_ambient_tint": Vector3(0.84, 0.90, 1.24), "ambient_boost": 1.22,
				"light_floor_col": Vector3(0.24, 0.34, 0.62), "light_floor": 0.50,
				"horizon_tint": Vector3(0.82, 0.92, 1.14), "sky_sat": 1.16, "horizon_haze": 0.36,
				"cloud_lit_col": Vector3(0.46, 0.60, 1.02),
				"cloud_shadow_col": Vector3(0.12, 0.17, 0.38),
				"cloud_rim_col": Vector3(0.92, 1.14, 1.68),
				"fog_beta": Vector3(3.2e-5, 5.2e-5, 1.08e-4), "mist": 0.042, "valley_mist_mult": 1.15,
				"cloud_cover": 0.30,
				"grade_wb": Vector3(0.94, 0.97, 1.09),
				"grade_shadow_tint": Vector3(0.82, 0.88, 1.22),
				"grade_shadow_cast": Vector3(0.84, 0.90, 1.18),
				"grade_lift_u": Vector3(0.009, 0.013, 0.028),
				"grade_sat_u": 1.08, "grade_contrast_u": 0.07, "day_fresh_k": 0.0,
			}
		"mist":
			var d := sun_direction(10.5)
			return {
				"hours": 10.5, "sun_dir": d, "sun_col": Vector3(0.88, 0.90, 0.92),
				"light_col": Vector3(2.85, 2.78, 2.70), "sun_disc_vis": 0.32, "moon_vis": 0.0,
				"night_weight": 0.0, "night_glow": 0.22, "mist_weight": 1.0, "exposure": 0.66,
				"sky_analytic": 1.0,
				"sky_zenith_col": Vector3(0.46, 0.64, 0.90),
				"sky_mid_col": Vector3(0.76, 0.90, 1.08),
				"sky_horizon_col": Vector3(1.22, 1.32, 1.42),
				"sky_glow_col": Vector3(0.68, 0.72, 0.76),
				"hemi_sky": Vector3(0.56, 0.68, 0.86), "hemi_ground": Vector3(0.42, 0.46, 0.56),
				"shadow_ambient_tint": Vector3(0.94, 0.98, 1.10), "ambient_boost": 1.18,
				"light_floor_col": Vector3(0.50, 0.58, 0.72), "light_floor": 0.52,
				"horizon_tint": Vector3(0.96, 1.00, 1.04), "sky_sat": 0.92, "horizon_haze": 0.74,
				"cloud_lit_col": Vector3(2.15, 2.20, 2.26),
				"cloud_shadow_col": Vector3(0.78, 0.88, 1.08),
				"cloud_rim_col": Vector3(2.45, 2.48, 2.52),
				"fog_beta": Vector3(1.25e-4, 1.45e-4, 1.85e-4), "mist": 0.24, "valley_mist_mult": 1.95,
				"cloud_cover": 0.56,
				"grade_wb": Vector3(0.97, 1.00, 1.03),
				"grade_shadow_tint": Vector3(0.92, 0.96, 1.10),
				"grade_shadow_cast": Vector3(0.94, 0.97, 1.08),
				"grade_lift_u": Vector3(0.010, 0.012, 0.018),
				"grade_sat_u": 0.96, "grade_contrast_u": 0.05, "day_fresh_k": 0.40,
			}
		_:
			# "noon" — exact baseline hour 16.0 values (0% drift vs main 2081d03).
			return {
				"hours": HOURS, "sun_dir": noon_dir, "sun_col": noon_cols[0],
				"light_col": noon_cols[1], "sun_disc_vis": 1.0, "moon_vis": 0.0,
				"night_weight": 0.0, "night_glow": 0.0, "mist_weight": 0.0, "exposure": EXPOSURE,
				"sky_analytic": 0.0,
				"sky_zenith_col": Vector3(0.18, 0.42, 0.92),
				"sky_mid_col": Vector3(0.45, 0.68, 1.05),
				"sky_horizon_col": Vector3(0.95, 1.02, 1.14),
				"sky_glow_col": Vector3(0.65, 0.52, 0.35),
				"hemi_sky": PAINTERLY_HEMI_SKY, "hemi_ground": PAINTERLY_HEMI_GROUND,
				"shadow_ambient_tint": PAINTERLY_SHADOW_TINT, "ambient_boost": PAINTERLY_AMBIENT_BOOST,
				"light_floor_col": PAINTERLY_LIGHT_FLOOR_COL, "light_floor": PAINTERLY_LIGHT_FLOOR,
				"horizon_tint": PAINTERLY_HORIZON_TINT, "sky_sat": PAINTERLY_SKY_SAT,
				"horizon_haze": PAINTERLY_HORIZON_HAZE,
				"cloud_lit_col": CLOUD_LIT_COL,
				"cloud_shadow_col": CLOUD_SHADOW_COL,
				"cloud_rim_col": CLOUD_RIM_COL,
				"fog_beta": DEFAULT_FOG_BETA, "mist": DEFAULT_MIST, "valley_mist_mult": 1.0,
				"cloud_cover": DEFAULT_CLOUD_COVER,
				"grade_wb": Vector3.ONE,
				"grade_shadow_tint": DEFAULT_GRADE_SHADOW_TINT,
				"grade_shadow_cast": DEFAULT_GRADE_SHADOW_CAST,
				"grade_lift_u": DEFAULT_GRADE_LIFT,
				"grade_sat_u": 1.12, "grade_contrast_u": 0.08, "day_fresh_k": 1.0,
			}


static func _blend_spec(a: Dictionary, b: Dictionary, t: float) -> Dictionary:
	var u := clampf(t, 0.0, 1.0)
	u = u * u * (3.0 - 2.0 * u)
	var out := {}
	for k in a.keys():
		var va = a[k]
		var vb = b[k]
		if va is Vector3:
			var v: Vector3 = (va as Vector3).lerp(vb as Vector3, u)
			if k == "sun_dir":
				v = v.normalized() if v.length_squared() > 1e-6 else Vector3.UP
			out[k] = v
		else:
			out[k] = lerpf(float(va), float(vb), u)
	return out


static func _spec_for_hour(h_in: float) -> Dictionary:
	var h := fposmod(h_in, 24.0)
	# Smooth diurnal keyframes wrapping 0..24h.
	var kf: Array = [
		[0.0, "night"], [4.2, "night"], [5.55, "dawn"], [8.4, "noon"],
		[16.2, "noon"], [18.35, "golden"], [19.55, "dusk"], [21.3, "night"], [24.0, "night"],
	]
	for i in range(kf.size() - 1):
		var h0 := float(kf[i][0])
		var h1 := float(kf[i + 1][0])
		if h >= h0 and h <= h1:
			var s0 := _preset_spec(str(kf[i][1]))
			var s1 := _preset_spec(str(kf[i + 1][1]))
			var t := (h - h0) / maxf(h1 - h0, 1e-4)
			var spec := _blend_spec(s0, s1, t)
			spec.hours = h
			# Track real solar arc during day and moon arc during night so shadows/rims glide smoothly.
			var sd := sun_direction(h)
			var md := moon_direction(h)
			var nw := float(spec.night_weight)
			var active_dir := sd if nw < 0.55 else md
			if active_dir.y < 0.06:
				active_dir = Vector3(active_dir.x, 0.06, active_dir.z).normalized()
			spec.sun_dir = active_dir
			return spec
	return _preset_spec("noon")


func _ready() -> void:
	# After the camera has moved this frame (the sky vignette follows it).
	process_priority = 100
	_apply_spec(_preset_spec("noon"), false)

	sky_mat = ShaderMaterial.new()
	sky_mat.shader = load("res://shaders/sky.gdshader")
	var sky := Sky.new()
	sky.sky_material = sky_mat
	sky.radiance_size = Sky.RADIANCE_SIZE_32
	# Keep sky process mode static so Godot never triggers real-time radiance rebuilds on TOD changes.
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
	sun.shadow_enabled = false
	sun.directional_shadow_max_distance = 80.0
	_sync_directional_light()

	# Honour URL/CLI flags: ?tod=noon|golden|dawn|dusk|night|mist or ?time=<hours>.
	var flag_tod := Flags.value("tod", "").to_lower()
	var flag_time := Flags.value("time", "")
	if flag_tod != "" and TOD_PRESETS.has(flag_tod):
		set_tod(flag_tod)
	elif flag_time != "":
		set_hours(float(flag_time), true)


func _sync_directional_light() -> void:
	if sun == null:
		return
	var target := sun.global_position - sun_dir
	if target.distance_squared_to(sun.global_position) > 1e-6:
		var up := Vector3.UP if absf(sun_dir.y) < 0.98 else Vector3.FORWARD
		sun.look_at(target, up)
	var peak := maxf(light_col.x, maxf(light_col.y, maxf(light_col.z, 1e-4)))
	sun.light_color = Color(light_col.x / peak, light_col.y / peak, light_col.z / peak)
	sun.light_energy = peak / PI * exposure


func _apply_spec(spec: Dictionary, push: bool = true) -> void:
	hours = float(spec.hours)
	sun_dir = spec.sun_dir
	sun_col = spec.sun_col
	light_col = spec.light_col
	moon_dir = moon_direction(hours)
	sun_disc_vis = float(spec.sun_disc_vis)
	moon_vis = float(spec.moon_vis)
	night_weight = float(spec.night_weight)
	night_glow = float(spec.night_glow)
	mist_weight = float(spec.mist_weight)
	exposure = float(spec.exposure)
	sky_analytic = float(spec.sky_analytic)
	sky_zenith_col = spec.sky_zenith_col
	sky_mid_col = spec.sky_mid_col
	sky_horizon_col = spec.sky_horizon_col
	sky_glow_col = spec.sky_glow_col
	if painterly:
		hemi_sky = spec.hemi_sky
		hemi_ground = spec.hemi_ground
	else:
		# Classic mode keeps exact HEMI_SKY / HEMI_GROUND at noon, scales softly for other presets.
		var k := 1.0 if sky_analytic < 0.001 else 0.0
		hemi_sky = spec.hemi_sky.lerp(HEMI_SKY, k)
		hemi_ground = spec.hemi_ground.lerp(HEMI_GROUND, k)
	shadow_ambient_tint = spec.shadow_ambient_tint
	ambient_boost = float(spec.ambient_boost)
	light_floor_col = spec.light_floor_col
	light_floor = float(spec.light_floor)
	horizon_tint = spec.horizon_tint
	sky_sat = float(spec.sky_sat)
	horizon_haze = float(spec.horizon_haze)
	cloud_lit_col = spec.cloud_lit_col
	cloud_shadow_col = spec.cloud_shadow_col
	cloud_rim_col = spec.cloud_rim_col
	fog_beta = spec.fog_beta
	mist = float(spec.mist)
	valley_mist_mult = float(spec.valley_mist_mult)
	cloud_cover = float(spec.cloud_cover)
	grade_wb = spec.grade_wb
	grade_shadow_tint = spec.grade_shadow_tint
	grade_shadow_cast = spec.grade_shadow_cast
	grade_lift_u = spec.grade_lift_u
	grade_sat_u = float(spec.grade_sat_u)
	grade_contrast_u = float(spec.grade_contrast_u)
	day_fresh_k = float(spec.day_fresh_k)
	_last_pushed_hours = hours
	if push:
		_push_all()


func _push_all() -> void:
	_sync_directional_light()
	if env != null:
		env.background_color = Color(
			clampf(sky_mid_col.x * 0.55, 0.03, 0.85),
			clampf(sky_mid_col.y * 0.55, 0.05, 0.90),
			clampf(sky_mid_col.z * 0.65, 0.12, 0.96)
		)
	for m in mats:
		if m != null:
			_push_mat(m)
	for cb in tod_listeners:
		if cb.is_valid():
			cb.call(self)


func set_tod(preset_name: String) -> void:
	var key := preset_name.to_lower()
	if not TOD_PRESETS.has(key):
		key = "noon"
	tod_preset = key
	cycle_enabled = false
	_apply_spec(_preset_spec(key), true)


func next_tod() -> String:
	var idx := TOD_PRESETS.find(tod_preset)
	idx = (idx + 1) % TOD_PRESETS.size()
	set_tod(TOD_PRESETS[idx])
	return tod_preset


func set_hours(h_val: float, lock_cycle: bool = false) -> void:
	if lock_cycle:
		cycle_enabled = false
	var h := fposmod(h_val, 24.0)
	tod_preset = _label_for_hour(h)
	_apply_spec(_spec_for_hour(h), true)


func step_hours(delta_h: float) -> void:
	set_hours(hours + delta_h, false)


func set_hurry(on: bool) -> void:
	hurry = on


func set_cycle_enabled(on: bool) -> void:
	cycle_enabled = on


static func _label_for_hour(h: float) -> String:
	if h < 4.5 or h >= 21.0:
		return "night"
	if h < 7.2:
		return "dawn"
	if h < 17.5:
		return "noon"
	if h < 19.0:
		return "golden"
	return "dusk"


func add_tod_listener(cb: Callable) -> void:
	if not tod_listeners.has(cb):
		tod_listeners.append(cb)
	if cb.is_valid():
		cb.call(self)


# Values every Stillwater-look shader reads (shaders/stillwater.gdshaderinc, atmosphere.gdshaderinc,
# clouds.gdshader). Set explicitly on every material including sky_mat because sky-shader uniform
# defaults are not applied in the Compatibility renderer.
func apply_to(mat: ShaderMaterial) -> void:
	_push_mat(mat)
	if not mats.has(mat):
		mats.append(mat)


func _push_mat(mat: ShaderMaterial) -> void:
	var active_light := light_col * (PAINTERLY_DIRECT_SCALE if painterly else 1.0)
	mat.set_shader_parameter("sun_dir", sun_dir)
	mat.set_shader_parameter("sun_col", sun_col)
	mat.set_shader_parameter("light_col", active_light)
	mat.set_shader_parameter("exposure", exposure)
	mat.set_shader_parameter("post_on", 1.0 if post_on else 0.0)
	mat.set_shader_parameter("painterly", 1.0 if painterly else 0.0)
	mat.set_shader_parameter("horizon_tint", horizon_tint)
	mat.set_shader_parameter("sky_sat", sky_sat)
	mat.set_shader_parameter("horizon_haze", horizon_haze)
	mat.set_shader_parameter("sky_analytic", sky_analytic)
	mat.set_shader_parameter("sky_zenith_col", sky_zenith_col)
	mat.set_shader_parameter("sky_mid_col", sky_mid_col)
	mat.set_shader_parameter("sky_horizon_col", sky_horizon_col)
	mat.set_shader_parameter("sky_glow_col", sky_glow_col)
	mat.set_shader_parameter("sun_disc_vis", sun_disc_vis)
	mat.set_shader_parameter("night_weight", night_weight)
	mat.set_shader_parameter("moon_vis", moon_vis)
	mat.set_shader_parameter("moon_dir", moon_dir)
	mat.set_shader_parameter("grade_wb", grade_wb)
	mat.set_shader_parameter("grade_shadow_tint", grade_shadow_tint)
	mat.set_shader_parameter("grade_shadow_cast", grade_shadow_cast)
	mat.set_shader_parameter("grade_lift_u", grade_lift_u)
	mat.set_shader_parameter("grade_sat_u", grade_sat_u)
	mat.set_shader_parameter("grade_contrast_u", grade_contrast_u)
	mat.set_shader_parameter("day_fresh_k", day_fresh_k)
	mat.set_shader_parameter("hemi_sky", hemi_sky)
	mat.set_shader_parameter("hemi_ground", hemi_ground)
	mat.set_shader_parameter("shadow_ambient_tint", shadow_ambient_tint)
	mat.set_shader_parameter("ambient_boost", ambient_boost)
	mat.set_shader_parameter("light_floor_col", light_floor_col)
	mat.set_shader_parameter("light_floor", light_floor)
	mat.set_shader_parameter("cloud_lit_col", cloud_lit_col)
	mat.set_shader_parameter("cloud_shadow_col", cloud_shadow_col)
	mat.set_shader_parameter("cloud_rim_col", cloud_rim_col)
	mat.set_shader_parameter("fog_beta", fog_beta)
	mat.set_shader_parameter("mist", mist)
	mat.set_shader_parameter("cloud_cover", cloud_cover)
	mat.set_shader_parameter("valley_mist", valley_mist_mult if valley_mist_on else 0.0)


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


func set_valley_mist(on: bool) -> void:
	valley_mist_on = on
	var v := valley_mist_mult if on else 0.0
	for m in mats:
		m.set_shader_parameter("valley_mist", v)


func set_style(s: String) -> void:
	style = "classic" if s == "classic" else "painterly"
	painterly = style != "classic"
	var spec := _preset_spec(tod_preset) if TOD_PRESETS.has(tod_preset) else _spec_for_hour(hours)
	if painterly:
		hemi_sky = spec.hemi_sky
		hemi_ground = spec.hemi_ground
	else:
		hemi_sky = HEMI_SKY if sky_analytic < 0.001 else spec.hemi_sky
		hemi_ground = HEMI_GROUND if sky_analytic < 0.001 else spec.hemi_ground
	var active_light := light_col * (PAINTERLY_DIRECT_SCALE if painterly else 1.0)
	for m in mats:
		m.set_shader_parameter("light_col", active_light)
		m.set_shader_parameter("painterly", 1.0 if painterly else 0.0)
		m.set_shader_parameter("hemi_sky", hemi_sky)
		m.set_shader_parameter("hemi_ground", hemi_ground)


# Sky LUT and noise; the cirrus values are the hour-16 ones, set explicitly because sky-shader
# uniform defaults are not applied in this renderer.
func set_sky(lut: Texture2D, noise: Texture2D) -> void:
	sky_mat.set_shader_parameter("sky_lut", lut)
	sky_mat.set_shader_parameter("noise_tex", noise)
	sky_mat.set_shader_parameter("cloud_offset", Vector2(-223.16, -143.45))
	sky_mat.set_shader_parameter("wind_dir", Vector2(0.8253, 0.5646))
	sky_mat.set_shader_parameter("cloud_cover", cloud_cover)
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


func _tick(delta: float) -> void:
	# Slow diurnal cycle in game mode (or rapid scrub when T is held). Only push uniforms when
	# hours move by >= 0.008 so stationary/normal frames stay near-zero script cost.
	if hurry:
		hours = fposmod(hours + delta * 1.8, 24.0)
		tod_preset = _label_for_hour(hours)
		_apply_spec(_spec_for_hour(hours), true)
	elif cycle_enabled:
		hours = fposmod(hours + delta * (time_scale / 3600.0), 24.0)
		if absf(hours - _last_pushed_hours) >= 0.008:
			tod_preset = _label_for_hour(hours)
			_apply_spec(_spec_for_hour(hours), true)

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
