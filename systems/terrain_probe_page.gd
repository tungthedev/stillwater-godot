extends Node

# ?probe=terrain: on-device bisection for a terrain that renders black on one GPU only.
# Renders the trailhead view (terrain + sky, nothing else) offscreen once per variant, reads the
# frame back and reports the ground colour and the share of black pixels. Each variant flips one
# suspect through the terrain shader's `dbg_terrain` bits (shaders/stillwater.gdshaderinc), the
# style, or the post mode, so one phone screenshot says which suspect blacks the ground out.
# The control rows force a NaN into the trail colour: they must read BLACK, which proves the page
# can see the failure, and their colour is what "black" means for the other rows.
# The first rows run with no grass system at all. The "after ... bake" rows then run the real grass
# and flower bakes (systems/grass.gd) in the same viewport, hide the blades and render the terrain
# again, to tell whether a bake leaves the GPU in a state that breaks the terrain.
# Publishes window.__probe. Desktop: `godot --path . -- --probe=terrain --quit`.

const Flags := preload("res://systems/flags.gd")

const W := 160
const H := 120
# The ground fills the rows below the horizon at the trailhead; the lowest 40% is all near ground.
const GROUND_FROM := 0.6
const NEAR_BLACK := 0.05
const BLACK_GROUND_SHARE := 0.5
const BLACK_FRAME_SHARE := 0.35

const LEGACY_POW := 1
const LEGACY_RSTEP := 2
const LEGACY_MISC := 4
const NO_GUARD := 8
const NO_FLOOR := 16
const NO_ATM := 32
const CLASSIC_IND := 64
const CLASSIC_RAMP := 128
const OUT_ALBEDO := 256
const NAN_POW := 1024

# Frames a fresh grass system gets to bake its rings (4 new tiles a frame per ring).
const BAKE_FRAMES := 45

# post: "dev" = what the game picks on this device, "alt" = the other mode.
# bake: run that ring's real bakes first ("grass", "flowers" or "both"); rows before the first
# bake row run with no grass system in the scene. Most telling rows first: a phone screenshot
# may cut the list.
const VARIANTS: Array[Dictionary] = [
	{"name": "CONTROL forced NaN", "bits": NAN_POW, "control": true},
	{"name": "CONTROL NaN, other post", "bits": NAN_POW, "post": "alt", "control": true},
	{"name": "default (this build)", "bits": 0},
	{"name": "OLD trail pow(neg, 2)", "bits": LEGACY_POW},
	{"name": "OLD trail pow, guards off", "bits": LEGACY_POW | NO_GUARD},
	{"name": "OLD reversed smoothsteps", "bits": LEGACY_RSTEP},
	{"name": "OLD rim pow + normalize", "bits": LEGACY_MISC},
	{"name": "OLD all three (s1-2 math)", "bits": LEGACY_POW | LEGACY_RSTEP | LEGACY_MISC},
	{"name": "no isnan in shader", "bits": 0, "no_isnan": true},
	{"name": "no isnan + OLD trail pow", "bits": LEGACY_POW, "no_isnan": true},
	{"name": "other post mode", "bits": 0, "post": "alt"},
	{"name": "painterly off (classic)", "bits": 0, "classic": true},
	{"name": "classic + OLD all three", "bits": LEGACY_POW | LEGACY_RSTEP | LEGACY_MISC, "classic": true},
	{"name": "light floor off", "bits": NO_FLOOR},
	{"name": "atmosphere bypassed", "bits": NO_ATM},
	{"name": "classic indirect", "bits": CLASSIC_IND},
	{"name": "classic toon ramp", "bits": CLASSIC_RAMP},
	{"name": "NaN guards off", "bits": NO_GUARD},
	{"name": "albedo only", "bits": OUT_ALBEDO | NO_ATM},
	{"name": "after GRASS bake", "bits": 0, "bake": "grass"},
	{"name": "after FLOWER bake", "bits": 0, "bake": "flowers"},
	{"name": "after BOTH bakes", "bits": 0, "bake": "both"},
	{"name": "after both + OLD all three", "bits": LEGACY_POW | LEGACY_RSTEP | LEGACY_MISC, "bake": "keep"},
]

var world: RefCounted
var build_id := ""
var _box: VBoxContainer
var _title_l: Label
var _vp: SubViewport
var _env: Node3D
var _terrain: Node3D
var _shader: Shader
var _shader_no_isnan: Shader
var _float_targets := true
var _grass: Node3D


func setup(w: RefCounted, build: String) -> void:
	world = w
	build_id = build


func _ready() -> void:
	_build_ui()
	_run.call_deferred()


func _build_ui() -> void:
	var layer := CanvasLayer.new()
	layer.layer = 20
	add_child(layer)
	var bg := ColorRect.new()
	bg.color = Color(0.05, 0.06, 0.08, 1.0)
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	layer.add_child(bg)
	var safe := _read_safe()
	var margin := MarginContainer.new()
	margin.set_anchors_preset(Control.PRESET_FULL_RECT)
	margin.add_theme_constant_override("margin_top", int(maxf(10.0, safe.x + 4.0)))
	margin.add_theme_constant_override("margin_right", int(maxf(14.0, safe.y + 10.0)))
	margin.add_theme_constant_override("margin_bottom", int(maxf(10.0, safe.z + 4.0)))
	margin.add_theme_constant_override("margin_left", int(maxf(8.0, safe.w + 4.0)))
	layer.add_child(margin)
	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	margin.add_child(scroll)
	_box = VBoxContainer.new()
	_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_box.add_theme_constant_override("separation", 0)
	scroll.add_child(_box)
	_title_l = _line("TERRAIN PROBE  RUNNING... (%s)" % build_id, 15, Color(0.96, 0.92, 0.7))
	_box.add_child(_title_l)


func _line(text: String, size: int, col: Color) -> Label:
	var l := Label.new()
	l.text = text
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", col)
	return l


func _read_safe() -> Vector4:
	if not OS.has_feature("web"):
		return Vector4.ZERO
	var s = JavaScriptBridge.eval("(() => { const e = document.getElementById('safe'); if (!e) return '0,0,0,0'; const c = getComputedStyle(e); return [c.paddingTop, c.paddingRight, c.paddingBottom, c.paddingLeft].map(parseFloat).join(','); })()")
	var p := str(s).split(",")
	return Vector4(float(p[0]), float(p[1]), float(p[2]), float(p[3])) if p.size() == 4 else Vector4.ZERO


func _gl_caps() -> Dictionary:
	if not OS.has_feature("web"):
		return {"float_linear": true, "color_float": true, "color_half": true, "vtx_tex_units": -1}
	var raw = JavaScriptBridge.eval("JSON.stringify((() => { const gl = document.createElement('canvas').getContext('webgl2'); if (!gl) return {}; return { float_linear: !!gl.getExtension('OES_texture_float_linear'), color_float: !!gl.getExtension('EXT_color_buffer_float'), color_half: !!gl.getExtension('EXT_color_buffer_half_float'), vtx_tex_units: gl.getParameter(gl.MAX_VERTEX_TEXTURE_IMAGE_UNITS) }; })())")
	var parsed = JSON.parse_string(str(raw))
	return parsed if parsed is Dictionary else {}


# The game's scene target and systems, cut down to terrain and sky at the trailhead bench pose.
func _build_scene() -> void:
	_float_targets = Flags.float_targets() and not Flags.has("ldr")
	_vp = SubViewport.new()
	_vp.size = Vector2i(W, H)
	_vp.own_world_3d = true
	_vp.use_hdr_2d = _float_targets
	_vp.msaa_3d = Viewport.MSAA_DISABLED
	_vp.screen_space_aa = Viewport.SCREEN_SPACE_AA_DISABLED
	_vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	add_child(_vp)
	_env = Node3D.new()
	_env.set_script(load("res://systems/environment.gd"))
	_vp.add_child(_env)
	_env.set_sky(world.sky_lut_tex, world.noise_tex)
	_terrain = Node3D.new()
	_terrain.set_script(load("res://systems/terrain.gd"))
	_terrain.setup(world)
	_vp.add_child(_terrain)
	_env.apply_to(_terrain.mat)
	var p: Dictionary = world.pose("trailhead")
	var poses: Dictionary = world.meta.poses
	var cam := Camera3D.new()
	cam.fov = float(poses.fovVerticalDeg)
	cam.near = float(poses.near)
	cam.far = float(poses.far)
	cam.keep_aspect = Camera3D.KEEP_HEIGHT
	cam.position = Vector3(float(p.position[0]), float(p.position[1]), float(p.position[2]))
	cam.rotation = Vector3(float(p.pitch), float(p.yaw), 0.0)
	_vp.add_child(cam)
	_shader = _terrain.mat.shader
	# The same terrain shader with no isnan() anywhere in its source: tells whether the mere
	# presence of isnan() changes how the driver compiles the rest of the shader.
	_shader_no_isnan = Shader.new()
	_shader_no_isnan.code = _shader.code.replace("#define W_DBG", "#define W_DBG\n#define W_NO_ISNAN")


# Replaces the grass system with a fresh one that bakes only the named ring(s) around the camera,
# lets it bake, then hides its blades: the bakes have run, and the readback shows bare terrain.
func _bake(which: String) -> Dictionary:
	if _grass != null:
		_grass.queue_free()
		await get_tree().process_frame
	_grass = Node3D.new()
	_grass.set_script(load("res://systems/grass.gd"))
	_grass.setup(world)
	_grass.update_grass = which != "flowers"
	_grass.update_flowers = which != "grass"
	_vp.add_child(_grass)
	for m in _grass.materials():
		_env.apply_to(m)
	for i in BAKE_FRAMES:
		await get_tree().process_frame
	var baked := {"grass": 0, "flowers": 0}
	for s in _grass.grass.slots:
		if s.get("ready", false):
			baked.grass += 1
	for s in _grass.flowers.slots:
		if s.get("ready", false):
			baked.flowers += 1
	_grass.set_on(false)
	return baked


func _set_style(classic: bool) -> void:
	_env.painterly = not classic
	_env.hemi_sky = _env.HEMI_SKY if classic else _env.PAINTERLY_HEMI_SKY
	_env.hemi_ground = _env.HEMI_GROUND if classic else _env.PAINTERLY_HEMI_GROUND
	_env.apply_to(_terrain.mat)
	_env.apply_to(_env.sky_mat)


func _run() -> void:
	_build_scene()
	var rows: Array[Dictionary] = []
	# Black as the control rows read it back, per post mode (post off grades black to navy).
	var black := {}
	for v in VARIANTS:
		var post_dev: bool = _float_targets
		var post: bool = post_dev if str(v.get("post", "dev")) == "dev" else not post_dev
		var row := {"name": v.name, "bits": int(v.bits), "post": post, "classic": bool(v.get("classic", false)),
			"no_isnan": bool(v.get("no_isnan", false)), "control": bool(v.get("control", false))}
		if post and not _float_targets:
			row.verdict = "N/A"
			row.note = "no float colour buffers"
			rows.append(row)
			continue
		var bake := str(v.get("bake", ""))
		if bake != "":
			row.bake = bake
			if bake != "keep":
				row.baked = await _bake(bake)
		_vp.use_hdr_2d = post
		_env.set_post(post)
		_set_style(row.classic)
		_terrain.mat.shader = _shader_no_isnan if row.no_isnan else _shader
		_terrain.mat.set_shader_parameter("dbg_terrain", row.bits)
		for i in 3:
			await get_tree().process_frame
		await RenderingServer.frame_post_draw
		var img := _vp.get_texture().get_image()
		if img == null or img.is_empty():
			row.verdict = "ERR"
			row.note = "no readback"
			rows.append(row)
			continue
		img.convert(Image.FORMAT_RGBAF)
		var px := img.get_data().to_float32_array()
		if row.control:
			black[post] = _median(px, int(H * GROUND_FROM), H)
		var ref: Vector3 = black.get(post, Vector3.ZERO)
		var g := _stats(px, int(H * GROUND_FROM), H, ref)
		var all := _stats(px, 0, H, ref)
		row.ground = [snappedf(g.mean.x, 0.001), snappedf(g.mean.y, 0.001), snappedf(g.mean.z, 0.001)]
		row.black_ground = snappedf(g.black, 0.001)
		row.black_frame = snappedf(all.black, 0.001)
		row.black_ref = [snappedf(ref.x, 0.001), snappedf(ref.y, 0.001), snappedf(ref.z, 0.001)]
		row.verdict = "BLACK" if g.black > BLACK_GROUND_SHARE or all.black > BLACK_FRAME_SHARE else "OK"
		var thumb := img.duplicate()
		thumb.convert(Image.FORMAT_RGBA8)
		row.thumb = ImageTexture.create_from_image(thumb)
		rows.append(row)

	# The control must be black in absolute terms too, or "black" above meant nothing.
	var control_ok := true
	var bad := 0
	for r in rows:
		if r.control:
			var ref_a: Array = r.get("black_ref", [1.0, 1.0, 1.0])
			if r.verdict != "N/A" and (r.verdict != "BLACK" or maxf(ref_a[0], maxf(ref_a[1], ref_a[2])) > 0.3):
				control_ok = false
		elif r.verdict != "OK" and r.verdict != "N/A":
			bad += 1
	var result := {
		"probe": "terrain",
		"build": build_id,
		"pass": control_ok and bad == 0,
		"control_ok": control_ok,
		"not_ok": bad,
		"post_default": _float_targets,
		"gpu": Flags.gpu_name(),
		"ua": Flags.user_agent(),
		"dpr": Flags.device_pixel_ratio(),
		"gl": _gl_caps(),
		"rows": rows.map(func(r: Dictionary) -> Dictionary:
			var o := r.duplicate()
			o.erase("thumb")
			return o),
	}
	_render_result(result, rows)
	var json := JSON.stringify(result)
	if OS.has_feature("web"):
		JavaScriptBridge.eval("window.__probe = %s;" % json)
	print("PROBE %s" % json)
	print("TERRAIN_PROBE %s" % ("PASS" if result.pass else "FAIL"))
	if Flags.has("quit"):
		var shot := Flags.value("shot")
		if shot != "":
			await RenderingServer.frame_post_draw
			get_viewport().get_texture().get_image().save_png(shot)
		get_tree().quit(0 if result.pass else 1)


# Per-channel median over rows [y0, y1): the colour most of the ground has.
func _median(px: PackedFloat32Array, y0: int, y1: int) -> Vector3:
	var ch: Array[PackedFloat32Array] = [PackedFloat32Array(), PackedFloat32Array(), PackedFloat32Array()]
	for i in range(y0 * W, y1 * W):
		for c in 3:
			ch[c].append(px[i * 4 + c])
	for c in 3:
		ch[c].sort()
	var m := ch[0].size() / 2
	return Vector3(ch[0][m], ch[1][m], ch[2][m])


# Mean colour and the share of pixels within NEAR_BLACK of the control's black, rows [y0, y1).
func _stats(px: PackedFloat32Array, y0: int, y1: int, ref: Vector3) -> Dictionary:
	var sum := Vector3.ZERO
	var n_black := 0
	var n := (y1 - y0) * W
	for i in range(y0 * W, y1 * W):
		var c := Vector3(px[i * 4], px[i * 4 + 1], px[i * 4 + 2])
		# A NaN that survives to the readback compares false to everything: count it as black.
		if is_nan(c.x) or is_nan(c.y) or is_nan(c.z):
			n_black += 1
			continue
		sum += c
		var d := (c - ref).abs()
		if maxf(d.x, maxf(d.y, d.z)) < NEAR_BLACK:
			n_black += 1
	return {"mean": sum / maxf(float(n), 1.0), "black": float(n_black) / maxf(float(n), 1.0)}


func _render_result(r: Dictionary, rows: Array[Dictionary]) -> void:
	var ok: bool = r.pass
	var head := "ALL OK" if ok else ("%d NOT OK" % int(r.not_ok) if r.control_ok else "CONTROL NOT BLACK: probe invalid")
	_title_l.text = "TERRAIN PROBE  %s  (%s)" % [head, r.build]
	_title_l.add_theme_color_override("font_color", Color(0.45, 0.96, 0.55) if ok else Color(1.0, 0.45, 0.4))
	_box.add_child(_line("%s, post %s. BLACK = the bug; CONTROL rows must be BLACK. Numbers: ground r g b, %% black ground/frame." % [
		str(r.gpu), "on" if r.post_default else "off"], 10, Color(0.78, 0.85, 0.96)))
	for row in rows:
		var verdict: String = row.verdict
		var good: bool = (verdict == "BLACK") if row.control else (verdict == "OK")
		var col := Color(0.55, 0.95, 0.6) if good else Color(1.0, 0.5, 0.45)
		if verdict == "N/A":
			col = Color(0.6, 0.63, 0.68)
		var h := HBoxContainer.new()
		h.add_theme_constant_override("separation", 5)
		var tr := TextureRect.new()
		tr.custom_minimum_size = Vector2(26, 19)
		tr.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		tr.stretch_mode = TextureRect.STRETCH_SCALE
		tr.texture = row.get("thumb")
		h.add_child(tr)
		var lv := _line(verdict, 11, col)
		lv.autowrap_mode = TextServer.AUTOWRAP_OFF
		lv.custom_minimum_size = Vector2(42, 0)
		h.add_child(lv)
		var ln := _line(row.name, 11, col)
		ln.autowrap_mode = TextServer.AUTOWRAP_OFF
		ln.clip_text = true
		ln.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		h.add_child(ln)
		var stats := str(row.get("note", ""))
		if row.has("ground"):
			stats = "%02d %02d %02d  %d/%d" % [mini(99, roundi(row.ground[0] * 100.0)), mini(99, roundi(row.ground[1] * 100.0)),
				mini(99, roundi(row.ground[2] * 100.0)), roundi(row.black_ground * 100.0), roundi(row.black_frame * 100.0)]
		var ls := _line(stats, 10, col)
		ls.autowrap_mode = TextServer.AUTOWRAP_OFF
		h.add_child(ls)
		_box.add_child(h)
	var gl: Dictionary = r.gl
	_box.add_child(_line("GL: float_lin=%s col_f=%s col_h=%s vtx_tex=%s dpr=%s" % [
		str(gl.get("float_linear", "?")), str(gl.get("color_float", "?")), str(gl.get("color_half", "?")),
		str(gl.get("vtx_tex_units", "?")), str(r.dpr)], 10, Color(0.78, 0.85, 0.96)))
	_box.add_child(_line("UA: %s" % str(r.ua), 10, Color(0.68, 0.72, 0.78)))
