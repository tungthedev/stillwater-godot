extends Node

# Stillwater's `low` post chain and render-size rule (src/post.js, src/engine/app.js, quality.js).
#
# The 3D world renders into `scene_vp` at the internal size: the screen's device pixels times the
# tier scale 0.6, capped at 0.9 MP (capScaleForPixels), as Stillwater does on a phone. The target is
# RGBA16F like Stillwater's half-float scene target, holding scene-linear HDR (every object shader
# ends in w_grade, which in post mode writes the plain value; see stillwater.gdshaderinc).
# Bloom runs a 3-level mip chain at half the internal size and below; the composite then runs on
# every screen pixel: FXAA, sharpen, bloom, grade, vignette, grain (shaders/post_composite).
#
# Post off: objects grade themselves (the slice 2-4 look path) and the composite only upscales.
# 8-bit fallback (?ldr, or no float colour buffers on Web): RGBA8 scene target, post forced off.

const LEVELS := 3
const BLOOM_THRESHOLD := 0.95
const TIER_SCALE := 0.6
const TIER_MAX_PIXELS := 900000
# Res button: the tier rule first, then plain scales of the device pixels (an explicit scale skips
# the pixel cap, like Stillwater's ?scale=).
const RES_MODES: Array[Dictionary] = [
	{"label": "auto", "scale": TIER_SCALE, "cap": TIER_MAX_PIXELS},
	{"label": "100%", "scale": 1.0, "cap": 0},
	{"label": "50%", "scale": 0.5, "cap": 0},
	{"label": "40%", "scale": 0.4, "cap": 0},
]

var env_sys: Node
var hdr := true
var on := true
var res_i := 0
var scene_vp: SubViewport
var down: Array[SubViewport] = []
var up: Array[SubViewport] = []
var down_mats: Array[ShaderMaterial] = []
var up_mats: Array[ShaderMaterial] = []
var comp_mat: ShaderMaterial
var comp_layer: CanvasLayer
var screen := Vector2i(16, 16)
var internal := Vector2i(16, 16)
var scale := TIER_SCALE
var scale_mult := 1.0
var fx := true
var frozen := false


func setup(env_node: Node, float_targets: bool) -> void:
	env_sys = env_node
	hdr = float_targets
	on = hdr
	scene_vp = SubViewport.new()
	scene_vp.name = "scene"
	scene_vp.use_hdr_2d = hdr
	scene_vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	scene_vp.msaa_3d = Viewport.MSAA_DISABLED
	scene_vp.screen_space_aa = Viewport.SCREEN_SPACE_AA_DISABLED
	add_child(scene_vp)
	var src: Texture2D = scene_vp.get_texture()
	for i in LEVELS:
		var d := _pass_vp("down%d" % i, "res://shaders/post_down.gdshader")
		var dm: ShaderMaterial = d.get_child(0).material
		dm.set_shader_parameter("src", src)
		dm.set_shader_parameter("first", 1.0 if i == 0 else 0.0)
		dm.set_shader_parameter("threshold", BLOOM_THRESHOLD)
		down.append(d)
		down_mats.append(dm)
		src = d.get_texture()
	for i in LEVELS - 1:
		var u := _pass_vp("up%d" % i, "res://shaders/post_up.gdshader")
		up.append(u)
		up_mats.append(u.get_child(0).material)
	var prev: Texture2D = down[LEVELS - 1].get_texture()
	for i in range(LEVELS - 2, -1, -1):
		up_mats[i].set_shader_parameter("src", prev)
		up_mats[i].set_shader_parameter("add", down[i].get_texture())
		prev = up[i].get_texture()

	comp_layer = CanvasLayer.new()
	comp_layer.layer = -1
	var rect := ColorRect.new()
	rect.set_anchors_preset(Control.PRESET_FULL_RECT)
	rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	comp_mat = ShaderMaterial.new()
	comp_mat.shader = load("res://shaders/post_composite.gdshader")
	comp_mat.set_shader_parameter("t_scene", scene_vp.get_texture())
	comp_mat.set_shader_parameter("t_bloom", up[0].get_texture())
	comp_mat.set_shader_parameter("exposure", env_sys.EXPOSURE)
	comp_mat.set_shader_parameter("painterly", 1.0 if env_sys.painterly else 0.0)
	rect.material = comp_mat
	comp_layer.add_child(rect)
	add_child(comp_layer)


func _ready() -> void:
	get_tree().root.size_changed.connect(resize)
	resize()
	set_on(on)


func _pass_vp(vp_name: String, shader: String) -> SubViewport:
	var vp := SubViewport.new()
	vp.name = vp_name
	vp.use_hdr_2d = hdr
	vp.disable_3d = true
	vp.transparent_bg = false
	vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	var rect := ColorRect.new()
	var m := ShaderMaterial.new()
	m.shader = load(shader)
	rect.material = m
	vp.add_child(rect)
	add_child(vp)
	return vp


# quality.js capScaleForPixels.
static func cap_scale(w: int, h: int, s: float, max_pixels: int) -> float:
	if max_pixels <= 0 or w <= 0 or h <= 0:
		return s
	var max_scale := sqrt(float(max_pixels) / float(w * h))
	if s <= max_scale:
		return s
	var c := max_scale
	while c > 0.1 and roundi(w * c) * roundi(h * c) > max_pixels:
		c -= 0.001
	return maxf(0.1, c)


static func internal_size(w: int, h: int, s: float) -> Vector2i:
	return Vector2i(maxi(16, roundi(w * s)), maxi(16, roundi(h * s)))


func resize() -> void:
	screen = DisplayServer.window_get_size()
	var m: Dictionary = RES_MODES[res_i]
	scale = cap_scale(screen.x, screen.y, float(m.scale), int(m.cap)) * scale_mult
	internal = internal_size(screen.x, screen.y, scale)
	scene_vp.size = internal
	var bw := internal.x >> 1
	var bh := internal.y >> 1
	for i in LEVELS:
		var sz := Vector2i(maxi(2, bw), maxi(2, bh))
		down[i].size = sz
		(down[i].get_child(0) as ColorRect).size = Vector2(sz)
		if i < LEVELS - 1:
			up[i].size = sz
			(up[i].get_child(0) as ColorRect).size = Vector2(sz)
		bw >>= 1
		bh >>= 1
	down_mats[0].set_shader_parameter("texel", Vector2(1.0 / internal.x, 1.0 / internal.y))
	for i in range(1, LEVELS):
		down_mats[i].set_shader_parameter("texel", Vector2(1.0, 1.0) / Vector2(down[i - 1].size))
	for i in LEVELS - 1:
		up_mats[i].set_shader_parameter("texel", Vector2(1.0, 1.0) / Vector2(down[i + 1].size))
	comp_mat.set_shader_parameter("res", Vector2(screen))
	comp_mat.set_shader_parameter("src_texel", Vector2(1.0 / internal.x, 1.0 / internal.y))
	comp_mat.set_shader_parameter("sharpen", _sharpen())


func next_res() -> void:
	res_i = (res_i + 1) % RES_MODES.size()
	resize()


func set_res_mode(label: String) -> void:
	for i in RES_MODES.size():
		if RES_MODES[i].label.trim_suffix("%") == label.trim_suffix("%"):
			res_i = i
	resize()


func res_label() -> String:
	return RES_MODES[res_i].label


func set_scale_mult(mult: float) -> void:
	if is_equal_approx(mult, scale_mult):
		return
	scale_mult = mult
	resize()


func set_painterly(p: bool) -> void:
	if comp_mat != null:
		comp_mat.set_shader_parameter("painterly", 1.0 if p else 0.0)


func set_on(v: bool) -> void:
	on = v and hdr
	var mode := SubViewport.UPDATE_ALWAYS if on else SubViewport.UPDATE_DISABLED
	for vp in down + up:
		vp.render_target_update_mode = mode
	comp_mat.set_shader_parameter("passthrough", 0.0 if on else 1.0)
	env_sys.set_post(on)


func is_on() -> bool:
	return on


func target_format() -> String:
	return "RGBA16F" if hdr else "RGBA8"


# Bloom, FXAA, sharpen, grain and the sun veil to zero: then post on must match post off (test).
func set_effects(enabled: bool) -> void:
	fx = enabled
	comp_mat.set_shader_parameter("fxaa", 1.0 if enabled else 0.0)
	comp_mat.set_shader_parameter("bloom_k", 0.055 if enabled else 0.0)
	comp_mat.set_shader_parameter("grain", 0.022 if enabled else 0.0)
	comp_mat.set_shader_parameter("sharpen", _sharpen())


# post.js: stronger sharpening when the scene is upscaled.
func _sharpen() -> float:
	return (0.6 if scale < 0.99 else 0.18) if fx else 0.0


# Script time of this frame's _process, for the bench.
var prof_us := 0
var _cam: Camera3D
var _sun_valid := false
var _last_bz := Vector3.ZERO
var _last_bx := Vector3.ZERO
var _last_sun_dir := Vector3.ZERO
var _last_sun_col := Vector3(-1.0, -1.0, -1.0)
var _last_internal := Vector2i.ZERO
var _last_fov := -1.0
var _last_fx := false
var _last_vis := -1.0
var _last_uv := Vector2(-99.0, -99.0)


func set_frozen(v: bool) -> void:
	frozen = v


func _process(delta: float) -> void:
	var t0 := Time.get_ticks_usec()
	if not frozen:
		_tick(delta)
	prof_us = Time.get_ticks_usec() - t0


func _tick(_delta: float) -> void:
	if not on:
		return
	# buildWorld.js getPostParams: the veil shows when the sun is on screen and roughly ahead.
	if _cam == null or not is_instance_valid(_cam):
		_cam = scene_vp.get_camera_3d()
		if _cam == null:
			return
	var sun_dir: Vector3 = env_sys.sun_dir
	var sun_col: Vector3 = env_sys.sun_col
	var b := _cam.global_basis
	if _sun_valid and b.z == _last_bz and b.x == _last_bx and sun_dir == _last_sun_dir and sun_col == _last_sun_col and internal == _last_internal and _cam.fov == _last_fov and fx == _last_fx:
		return
	_sun_valid = true
	_last_bz = b.z
	_last_bx = b.x
	_last_sun_dir = sun_dir
	_last_internal = internal
	_last_fov = _cam.fov
	_last_fx = fx
	if sun_col != _last_sun_col:
		_last_sun_col = sun_col
		comp_mat.set_shader_parameter("ray_color", sun_col)
	var facing := (-b.z).dot(sun_dir)
	var vis := 0.0
	var uv := Vector2(-10.0, -10.0)
	if fx and facing > 0.0:
		var p := _cam.global_position + sun_dir * 10000.0
		if not _cam.is_position_behind(p):
			uv = _cam.unproject_position(p) / Vector2(internal)
			var ndc := uv * 2.0 - Vector2.ONE
			if absf(ndc.x) < 1.3 and absf(ndc.y) < 1.3:
				vis = _ss(-0.03, 0.04, sun_dir.y) * _ss(0.3, 0.8, facing)
	if vis != _last_vis:
		_last_vis = vis
		comp_mat.set_shader_parameter("sun_vis", vis)
	if vis > 0.001 and uv != _last_uv:
		_last_uv = uv
		comp_mat.set_shader_parameter("sun_uv", uv)


static func _ss(a: float, b: float, x: float) -> float:
	var t := clampf((x - a) / (b - a), 0.0, 1.0)
	return t * t * (3.0 - 2.0 * t)
