extends CanvasLayer

# Perf readout, the cost levers and the bench, laid out in points for a 390 pt wide phone (the
# project's canvas is 390 x 844 and stretches). Every lever is also a start-up flag, so a bench
# URL records its settings: ?res=auto|100%|50%|40% ?dist=100|50|25 ?dens=100|75|50|25 ?nopost
# ?shadow ?nograss ?notrees ?bench (desktop: -- --res=50% ...).

const Flags := preload("res://systems/flags.gd")
# Draw distance: camera far plane (terrain, impostors and clouds beyond it are culled) and a scale
# of the tree hero / mid / bush radii.
const DISTS: Array[Dictionary] = [
	{"label": "100", "far": 60000.0, "radii": 1.0},
	{"label": "50", "far": 8000.0, "radii": 0.75},
	{"label": "25", "far": 4000.0, "radii": 0.5},
]
const DENS: Array[float] = [1.0, 0.75, 0.5, 0.25]

var env_sys: Node
var grass_sys: Node
var bench_sys: Node
var cam: Camera3D
var terrain_sys: Node
var trees_sys: Node
var post: Node
var build_id := ""
# In the game the readout and levers hide behind G / the pause sheet's Perf button (?debug shows
# them at load); bench and pose pages show them as before.
var game := false
var dev_on := true

var dist_i := 0
var dens_i := 0
var label: Label
var progress: Label
var grid: GridContainer
var panel: PanelContainer
var panel_box: VBoxContainer
var btn := {}


func setup(nodes: Dictionary) -> void:
	env_sys = nodes.env
	grass_sys = nodes.grass
	bench_sys = nodes.bench
	cam = nodes.cam
	terrain_sys = nodes.terrain
	trees_sys = nodes.trees
	post = nodes.post
	build_id = nodes.build
	game = nodes.get("game", false)
	dev_on = not game or Flags.has("debug")


func _ready() -> void:
	# Above the game's HUD and pause sheet, so the pause sheet's Perf button can open it.
	layer = 10
	label = _label(11, Color.WHITE)
	label.position = Vector2(8, 8)
	add_child(label)
	progress = _label(20, Color(1.0, 0.95, 0.6))
	progress.set_anchors_and_offsets_preset(Control.PRESET_CENTER_TOP)
	progress.offset_top = 120
	progress.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	progress.grow_horizontal = Control.GROW_DIRECTION_BOTH
	add_child(progress)

	grid = GridContainer.new()
	grid.columns = 3
	grid.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_WIDE)
	grid.offset_left = 8
	grid.offset_right = -8
	grid.offset_top = -152
	grid.offset_bottom = -12
	grid.add_theme_constant_override("h_separation", 6)
	grid.add_theme_constant_override("v_separation", 6)
	for key in ["res", "dist", "dens", "post", "shadow", "grass", "trees", "pose", "bench"]:
		var b := Button.new()
		b.custom_minimum_size = Vector2(0, 42)
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		b.add_theme_font_size_override("font_size", 15)
		b.pressed.connect(_on_button.bind(key))
		grid.add_child(b)
		btn[key] = b
	add_child(grid)
	_build_panel()
	bench_sys.finished.connect(_show_results)

	_apply_start_flags()
	if game:
		btn.pose.visible = false
	_show_dev()
	_refresh()
	# Look-check screenshots hide the overlay: ?noui on Web, `-- --no-ui` on desktop.
	visible = not (Flags.has("noui") or Flags.has("no-ui"))
	if Flags.has("bench"):
		_start_bench.call_deferred()


func _label(size: int, col: Color) -> Label:
	var l := Label.new()
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", col)
	l.add_theme_color_override("font_outline_color", Color.BLACK)
	l.add_theme_constant_override("outline_size", 4)
	return l


func _apply_start_flags() -> void:
	post.set_res_mode(Flags.value("res", "auto"))
	dist_i = maxi(0, DISTS.map(func(d: Dictionary) -> String: return d.label).find(Flags.value("dist", "100")))
	dens_i = maxi(0, DENS.find(float(Flags.value("dens", "100")) / 100.0))
	if Flags.has("nopost"):
		post.set_on(false)
	if Flags.has("shadow"):
		env_sys.sun.shadow_enabled = true
	_apply_dist_dens(true)


func _apply_dist_dens(rebuild_grass: bool) -> void:
	var d: Dictionary = DISTS[dist_i]
	cam.far = d.far
	trees_sys.set_levers(DENS[dens_i], d.radii)
	if rebuild_grass:
		grass_sys.set_density(DENS[dens_i])


func _on_button(key: String) -> void:
	match key:
		"res":
			post.next_res()
		"dist":
			dist_i = (dist_i + 1) % DISTS.size()
			_apply_dist_dens(false)
		"dens":
			dens_i = (dens_i + 1) % DENS.size()
			_apply_dist_dens(true)
		"post":
			post.set_on(not post.is_on())
		"shadow":
			env_sys.sun.shadow_enabled = not env_sys.sun.shadow_enabled
		"grass":
			grass_sys.set_on(not grass_sys.is_on())
		"trees":
			trees_sys.set_on(not trees_sys.is_on())
		"pose":
			cam.next_mode()
		"bench":
			_start_bench()
	_refresh()


func toggle_dev() -> void:
	dev_on = not dev_on
	_show_dev()


func _show_dev() -> void:
	label.visible = dev_on
	grid.visible = dev_on and not bench_sys.running
	if not dev_on:
		panel.visible = false


func _start_bench() -> void:
	panel.visible = false
	grid.visible = false
	bench_sys.start()


func _refresh() -> void:
	btn.res.text = "Res " + post.res_label()
	btn.dist.text = "Dist %s%%" % DISTS[dist_i].label
	btn.dens.text = "Dens %d%%" % roundi(DENS[dens_i] * 100.0)
	btn.post.text = "Post " + ("on" if post.is_on() else ("off" if post.hdr else "8-bit"))
	btn.shadow.text = "Shadow " + ("on" if env_sys.sun.shadow_enabled else "off")
	btn.grass.text = "Grass " + ("on" if grass_sys.is_on() else "off")
	btn.trees.text = "Trees " + ("on" if trees_sys.is_on() else "off")
	btn.pose.text = "Pose " + cam.mode()
	btn.bench.text = "Bench"


# Everything a run depends on, recorded with its result.
func settings() -> Dictionary:
	return {
		"build": build_id,
		"engine": "Godot %s Compatibility%s" % [Engine.get_version_info().string, " (WebGL2)" if OS.has_feature("web") else ""],
		"renderer": Flags.gpu_name(),
		"vendor": RenderingServer.get_video_adapter_vendor(),
		"ua": Flags.user_agent(),
		"dpr": Flags.device_pixel_ratio(),
		"screen": [post.screen.x, post.screen.y],
		"internal": [post.internal.x, post.internal.y],
		"res": post.res_label(),
		"scale": snappedf(post.scale, 0.001),
		"target": post.target_format(),
		"post": post.is_on(),
		"dist": DISTS[dist_i].label,
		"dens": roundi(DENS[dens_i] * 100.0),
		"shadow": env_sys.sun.shadow_enabled,
		"grass": grass_sys.is_on(),
		"trees": trees_sys.is_on(),
		"style": env_sys.style,
		"style_tricks": env_sys.active_tricks(),
		"frame_cap": "rAF (display rate, 60 on iPhone)" if OS.has_feature("web") else "none (vsync off)",
	}


func _build_panel() -> void:
	panel = PanelContainer.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.06, 0.07, 0.09, 0.93)
	sb.set_corner_radius_all(10)
	sb.set_content_margin_all(12)
	panel.add_theme_stylebox_override("panel", sb)
	# A sheet between the readout and the lever grid; the results scroll, the buttons stay.
	panel.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	panel.offset_left = 6
	panel.offset_right = -6
	panel.offset_top = 40
	panel.offset_bottom = grid.offset_top - 8
	panel.visible = false
	var outer := VBoxContainer.new()
	outer.add_theme_constant_override("separation", 8)
	panel.add_child(outer)
	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	outer.add_child(scroll)
	panel_box = VBoxContainer.new()
	panel_box.add_theme_constant_override("separation", 5)
	panel_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(panel_box)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	for pair in [["Close", _close_panel], ["Run again", _start_bench]]:
		var b := Button.new()
		b.text = pair[0]
		b.custom_minimum_size = Vector2(0, 40)
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		b.add_theme_font_size_override("font_size", 15)
		b.pressed.connect(pair[1])
		row.add_child(b)
		btn["panel_" + pair[0].to_lower().replace(" ", "_")] = b
	outer.add_child(row)
	add_child(panel)


const WIDTHS_FPS := [78, 44, 50, 50, 56, 44]
# Fits the 354 pt inside of the panel on a 390 pt wide phone.
const WIDTHS_MS := [60, 58, 58, 60, 54, 46]


func _row(cells: Array, size: int, col: Color, widths: Array = WIDTHS_FPS) -> HBoxContainer:
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", 2)
	for i in cells.size():
		var l := Label.new()
		l.text = str(cells[i])
		l.custom_minimum_size = Vector2(widths[i], 0)
		l.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT if i == 0 else HORIZONTAL_ALIGNMENT_RIGHT
		l.add_theme_font_size_override("font_size", size)
		l.add_theme_color_override("font_color", col)
		h.add_child(l)
	return h


func _text(t: String, size: int, col: Color) -> Label:
	var l := Label.new()
	l.text = t
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", col)
	return l


func _show_results(r: Dictionary) -> void:
	for c in panel_box.get_children():
		c.queue_free()
	var ok: bool = float(r.worst_fps) >= 30.0
	# The build id stays above the fold, so any screenshot of the panel names the build that ran.
	panel_box.add_child(_text("Godot bench %s  vs 30 fps" % r.build, 17, Color.WHITE))
	panel_box.add_child(_row(["stage", "fps", "p50", "p95", "tris", "draws"], 13, Color(0.7, 0.75, 0.8)))
	for s in r.stages:
		panel_box.add_child(_row([s.stage, "%.1f" % s.fps, "%.1f" % s.p50_ms, "%.1f" % s.p95_ms, "%.2fM" % (s.tris / 1.0e6), s.draws], 15, Color.WHITE))
	panel_box.add_child(_text(r.verdict, 16, Color(0.55, 0.95, 0.6) if ok else Color(1.0, 0.6, 0.45)))
	_timing_rows(r)
	var tricks_arr: Array = r.get("style_tricks", [])
	var tricks_str := ", ".join(PackedStringArray(tricks_arr)) if not tricks_arr.is_empty() else "none"
	var info := "%d x %d internal of %d x %d screen (Res %s, scale %.3f), dpr %s\nStyle %s (%s) · clouds %d tris\nPost %s · Dist %s%% · Dens %d%% · Shadow %s · Grass %s · Trees %s\nTarget %s · frame cap %s\n%s\n%s · build %s" % [
		r.internal[0], r.internal[1], r.screen[0], r.screen[1], r.res, r.scale, str(r.dpr),
		str(r.get("style", "painterly")), tricks_str, int(r.get("clouds_tris", 0)),
		"on" if r.post else "off", r.dist, r.dens, "on" if r.shadow else "off", "on" if r.grass else "off", "on" if r.trees else "off",
		r.target, r.frame_cap, r.renderer, r.engine, r.build]
	panel_box.add_child(_text(info, 11, Color(0.85, 0.87, 0.9)))
	panel_box.add_child(_text(_short_ua(str(r.ua)), 11, Color(0.6, 0.63, 0.68)))
	dev_on = true
	panel.visible = true
	_show_dev()
	_refresh()


# Where the frame time goes: ms avg / p95 per stage (main-thread CPU = work + GPU wait), the CPU or
# GPU verdict per stage, the biggest GPU waits and the per-system script costs of the slowest stage.
func _timing_rows(r: Dictionary) -> void:
	var head := Color(0.7, 0.75, 0.8)
	panel_box.add_child(_row(["ms avg/p95", "frame", "CPU", "GPU wait", "script", "render"], 12, head, WIDTHS_MS))
	for st in r.stages:
		var s: Dictionary = st
		if s.has("cpu_avg"):
			panel_box.add_child(_row([s.stage, _pair(s.frame_avg, s.frame_p95), _pair(s.cpu_avg, s.cpu_p95), _pair(s.wait_avg, s.wait_p95),
				_pair(s.script_avg, s.script_p95), "%.1f" % s.render_work_avg], 13, Color.WHITE, WIDTHS_MS))
		else:
			panel_box.add_child(_row([s.stage, _pair(1000.0 / maxf(float(s.fps), 0.1), s.p95_ms), "n/a", "n/a",
				_pair(s.script_avg, s.script_p95), "%.1f" % s.render_avg], 13, Color.WHITE, WIDTHS_MS))
	var lines := PackedStringArray()
	for st in r.stages:
		var s: Dictionary = st
		lines.append("%s: %s" % [s.stage, s.get("bound_note", "n/a")])
	panel_box.add_child(_text("\n".join(lines), 12, Color(0.95, 0.9, 0.65)))
	var worst: Dictionary = r.stages[0]
	for st in r.stages:
		if float(st.fps) < float(worst.fps):
			worst = st
	var waits := PackedStringArray()
	var wb: Dictionary = worst.get("wait_by", {})
	for k in wb:
		if float(wb[k]) >= 0.05:
			waits.append("%s %.2f" % [k, wb[k]])
	if not waits.is_empty():
		panel_box.add_child(_text("GPU waits ms/frame, %s: %s" % [worst.stage, " · ".join(waits)], 12, Color(0.85, 0.87, 0.9)))
	var parts := PackedStringArray()
	var sys: Dictionary = worst.get("sys_ms", {})
	for k in sys:
		if "." in k or parts.size() >= 6:
			continue
		var sub := PackedStringArray()
		for sk in ["push", "count"]:
			if sys.has("%s.%s" % [k, sk]):
				sub.append("%s %.2f" % [sk, sys["%s.%s" % [k, sk]]])
		parts.append("%s %.2f%s" % [k, sys[k], (" (%s)" % ", ".join(sub)) if not sub.is_empty() else ""])
	panel_box.add_child(_text("Script ms/frame, %s: %s%s" % [worst.stage, " · ".join(parts),
		(" · other %.1f" % worst.other_avg) if worst.has("other_avg") else ""], 12, Color(0.85, 0.87, 0.9)))
	panel_box.add_child(_text("CPU = main-thread ms per frame = work + GPU wait (time inside WebGL calls that wait for the GPU); render = render submit minus those waits. GPU timer: %s" % str(r.stages[0].get("gpu_state", "n/a")), 11, Color(0.6, 0.63, 0.68)))


static func _pair(a, b) -> String:
	return "%.1f/%.0f" % [float(a), float(b)]


func _close_panel() -> void:
	panel.visible = false


static func _short_ua(ua: String) -> String:
	var i := ua.find("(")
	var j := ua.find(")")
	return ua.substr(i + 1, j - i - 1) if i >= 0 and j > i else ua


# Script time of this frame's _process, for the bench.
var prof_us := 0


func _process(delta: float) -> void:
	var t0 := Time.get_ticks_usec()
	_tick(delta)
	prof_us = Time.get_ticks_usec() - t0


func _tick(_delta: float) -> void:
	progress.text = ("Bench  " + bench_sys.progress) if bench_sys.running else ""
	if not dev_on:
		return
	label.text = "%d fps  %d x %d of %d x %d  post %s  style %s\n%d draws  %.2f M tris (terrain %.2f, trees %.2f, grass %.2f)" % [
		Engine.get_frames_per_second(), post.internal.x, post.internal.y, post.screen.x, post.screen.y, "on" if post.is_on() else "off", env_sys.style,
		bench_sys.last_draws, bench_sys.last_prims / 1.0e6, terrain_sys.last_tris / 1.0e6, trees_sys.last_tris / 1.0e6, grass_sys.last_tris / 1.0e6]
