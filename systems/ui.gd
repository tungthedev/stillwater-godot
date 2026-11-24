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
var sweep_sys: Node
var cam: Camera3D
var terrain_sys: Node
var trees_sys: Node
var post: Node
var build_id := ""
# In the game the readout and levers hide behind G / the pause sheet's Perf button (?debug shows
# them at load); bench and pose pages show them as before.
var game := false
var dev_on := true
var _showing_sweep := false
var _panel_sb: StyleBoxFlat
var frozen := false
var _scr_line := ""
var _scr_ema := {}
var _scr_tot_ema := 0.0
var _scr_t := 0.0

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
	sweep_sys = nodes.get("sweep", null)
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
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.custom_minimum_size = Vector2(374, 0)
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
	if sweep_sys != null:
		sweep_sys.finished.connect(_show_sweep_results)

	_apply_start_flags()
	if game:
		btn.pose.visible = false
	_show_dev()
	_refresh()
	# Look-check screenshots hide the overlay: ?noui on Web, `-- --no-ui` on desktop.
	visible = not (Flags.has("noui") or Flags.has("no-ui"))
	if sweep_sys != null:
		_start_sweep.call_deferred()
	elif Flags.has("bench"):
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
	var busy: bool = bool(bench_sys.running) or (sweep_sys != null and bool(sweep_sys.running))
	var sweep_sheet: bool = _showing_sweep and panel.visible
	label.visible = dev_on and not sweep_sheet
	grid.visible = dev_on and not busy and not sweep_sheet
	if not dev_on:
		panel.visible = false


func _start_bench() -> void:
	_showing_sweep = false
	panel.visible = false
	grid.visible = false
	bench_sys.start()


func _start_sweep() -> void:
	_showing_sweep = false
	panel.visible = false
	grid.visible = false
	sweep_sys.start()


func _run_again() -> void:
	if _showing_sweep and sweep_sys != null:
		_start_sweep()
	else:
		_start_bench()


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
	_panel_sb = StyleBoxFlat.new()
	_panel_sb.bg_color = Color(0.06, 0.07, 0.09, 0.93)
	_panel_sb.set_corner_radius_all(10)
	_panel_sb.set_content_margin_all(12)
	panel.add_theme_stylebox_override("panel", _panel_sb)
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
	for pair in [["Close", _close_panel], ["Run again", _run_again]]:
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
# 7 compact columns (332 + 12 = 344 pt) fit inside a 375 pt iPhone mini panel (355 pt inner).
const WIDTHS_SWEEP := [94, 40, 44, 38, 40, 40, 36]


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
	_showing_sweep = false
	_panel_sb.set_content_margin_all(12)
	panel.offset_left = 6
	panel.offset_right = -6
	panel.offset_top = 40
	panel.offset_bottom = grid.offset_top - 8
	panel_box.add_theme_constant_override("separation", 5)
	for bk in ["panel_close", "panel_run_again"]:
		if btn.has(bk):
			(btn[bk] as Button).custom_minimum_size = Vector2(0, 40)
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


func _show_sweep_results(r: Dictionary) -> void:
	_showing_sweep = true
	for c in panel_box.get_children():
		c.queue_free()
	var safe := _read_safe()
	_panel_sb.set_content_margin_all(6)
	panel.offset_left = 4
	panel.offset_right = -4
	panel.offset_top = maxf(4.0, safe.x + 2.0)
	panel.offset_bottom = -maxf(4.0, safe.z + 2.0)
	panel_box.add_theme_constant_override("separation", 2)
	for bk in ["panel_close", "panel_run_again"]:
		if btn.has(bk):
			(btn[bk] as Button).custom_minimum_size = Vector2(0, 30)
	var notes: Array = r.get("notes", [])
	var note_s := (" · " + ", ".join(PackedStringArray(notes))) if not notes.is_empty() else ""
	panel_box.add_child(_text("GPU Sweep %s · %.0fs%s" % [str(r.build), float(r.total_s), note_s], 12, Color.WHITE))
	panel_box.add_child(_text("%dx%d of %dx%d (dpr %s) · post %s · %s · %s" % [
		int(r.internal[0]), int(r.internal[1]), int(r.screen[0]), int(r.screen[1]),
		str(r.dpr), "on" if r.post else "off", str(r.target), str(r.style)], 9, Color(0.84, 0.87, 0.92)))
	panel_box.add_child(_text("GPU: %s" % str(r.renderer), 9, Color(0.68, 0.72, 0.78)))
	for p_any in r.poses:
		var p: Dictionary = p_any
		var drift: float = float(p.drift_ms)
		var hdr := "%s base %.1f->%.1f (%+.1f) cpu %s raf %s scr %.1f phy %.1f" % [
			str(p.pose).capitalize(), float(p.base_start_ms), float(p.base_end_ms), drift,
			_opt_ms(p.get("base_raf_cpu_ms", -1.0)), _opt_ms(p.get("base_raf_iv_ms", -1.0)),
			float(p.get("base_script_ms", 0.0)), float(p.get("base_phys_ms", 0.0))]
		panel_box.add_child(_text(hdr, 9, Color(0.96, 0.90, 0.62)))
		var bsys: Dictionary = p.get("base_sys_ms", {})
		if not bsys.is_empty():
			panel_box.add_child(_text(_format_sys_line("scr", float(p.get("base_script_ms", 0.0)), bsys), 8, Color(0.76, 0.84, 0.94)))
		var tbl := VBoxContainer.new()
		tbl.add_theme_constant_override("separation", 0)
		tbl.add_child(_row(["variant", "med", "Δms", "%", "cpu", "raf", "scr"], 9, Color(0.68, 0.74, 0.82), WIDTHS_SWEEP))
		for v_any in p.variants:
			var v: Dictionary = v_any
			var d: float = float(v.delta_ms)
			var col := Color(0.55, 0.95, 0.6) if d <= -0.8 else (Color(1.0, 0.62, 0.48) if d >= 0.8 else Color(0.92, 0.93, 0.95))
			tbl.add_child(_row([
				str(v.label), "%.1f" % float(v.median_ms), "%+.1f" % d, "%+.0f%%" % float(v.delta_pct),
				_opt_ms(v.get("raf_cpu_ms", -1.0)), _opt_ms(v.get("raf_iv_ms", -1.0)),
				"%.1f" % float(v.get("script_ms", 0.0))], 10, col, WIDTHS_SWEEP))
		panel_box.add_child(tbl)
	dev_on = true
	panel.visible = true
	_show_dev()
	_refresh()


static func _opt_ms(v) -> String:
	var f := float(v)
	return "%.1f" % f if f >= 0.0 else "-"


func set_frozen(v: bool) -> void:
	frozen = v


func set_progress_text(t: String) -> void:
	if progress != null:
		progress.text = t


func _read_safe() -> Vector4:
	if not OS.has_feature("web"):
		return Vector4.ZERO
	var s = JavaScriptBridge.eval("(() => { const e = document.getElementById('safe'); if (!e) return ''; const st = getComputedStyle(e); return [st.paddingTop, st.paddingRight, st.paddingBottom, st.paddingLeft].map((v) => parseFloat(v) || 0).join(','); })()")
	if s == null or str(s) == "":
		return Vector4.ZERO
	var p := str(s).split(",")
	if p.size() < 4:
		return Vector4.ZERO
	return Vector4(float(p[0]), float(p[1]), float(p[2]), float(p[3]))


func _close_panel() -> void:
	panel.visible = false
	if _showing_sweep:
		_showing_sweep = false
		_panel_sb.set_content_margin_all(12)
		panel.offset_left = 6
		panel.offset_right = -6
		panel.offset_top = 40
		panel.offset_bottom = grid.offset_top - 8
		panel_box.add_theme_constant_override("separation", 5)
		for bk in ["panel_close", "panel_run_again"]:
			if btn.has(bk):
				(btn[bk] as Button).custom_minimum_size = Vector2(0, 40)
		_show_dev()


static func _short_ua(ua: String) -> String:
	var i := ua.find("(")
	var j := ua.find(")")
	return ua.substr(i + 1, j - i - 1) if i >= 0 and j > i else ua


# Script time of this frame's _process, for the bench.
var prof_us := 0


func _process(delta: float) -> void:
	var t0 := Time.get_ticks_usec()
	if not frozen:
		_tick(delta)
	prof_us = Time.get_ticks_usec() - t0


static func _format_sys_line(prefix: String, total_ms: float, sys: Dictionary) -> String:
	var order: Array[String] = ["terrain", "grass", "trees", "sky", "post", "ui", "player", "session", "hud", "camera", "bench"]
	var parts := PackedStringArray()
	for k in order:
		if not sys.has(k):
			continue
		var v := float(sys[k])
		if v < 0.005 and k not in ["terrain", "grass", "trees", "sky", "post", "ui"]:
			continue
		var detail := ""
		if k == "terrain":
			detail = _sub_str(sys, [["terrain.select", "sel"], ["terrain.push", "psh"], ["terrain.uniform", "uni"]])
		elif k == "grass":
			detail = _sub_str(sys, [["grass.grass", "g"], ["grass.flowers", "f"], ["grass.push", "psh"]])
		elif k == "trees":
			detail = _sub_str(sys, [["trees.hero", "h"], ["trees.mid", "m"], ["trees.flags", "flg"], ["trees.prefetch", "pre"], ["trees.count", "cnt"]])
		parts.append("%s %.2f%s" % [k, v, detail])
	return "%s %.2f ms: %s" % [prefix, total_ms, " · ".join(parts)]


static func _sub_str(sys: Dictionary, specs: Array) -> String:
	var out := PackedStringArray()
	for sp in specs:
		var v := float(sys.get(sp[0], 0.0))
		if v >= 0.005:
			out.append("%s %.2f" % [sp[1], v])
	return (" (%s)" % " ".join(out)) if not out.is_empty() else ""


func _update_scr_line(delta: float) -> void:
	_scr_t += delta
	if _scr_t < 0.25 and _scr_line != "":
		return
	_scr_t = 0.0
	var a := 0.35 if _scr_line != "" else 1.0
	_scr_tot_ema = lerpf(_scr_tot_ema, float(bench_sys.last_script_us) / 1000.0, a)
	for k in bench_sys.profiled:
		var node: Object = bench_sys.profiled[k]
		if node == null:
			continue
		var ks := String(k)
		_scr_ema[ks] = lerpf(float(_scr_ema.get(ks, 0.0)), float(node.prof_us) / 1000.0, a)
		for sub in bench_sys.SUB_PROFS:
			var v = node.get(sub)
			if v != null:
				var sk := "%s.%s" % [ks, sub.trim_suffix("_us")]
				_scr_ema[sk] = lerpf(float(_scr_ema.get(sk, 0.0)), float(v) / 1000.0, a)
	_scr_line = _format_sys_line("scr", _scr_tot_ema, _scr_ema)


func _tick(delta: float) -> void:
	if sweep_sys != null and sweep_sys.running:
		progress.text = "Sweep  " + sweep_sys.progress
	elif bench_sys.running:
		progress.text = "Bench  " + bench_sys.progress
	else:
		progress.text = ""
	if not dev_on:
		return
	_update_scr_line(delta)
	label.text = "%d fps  %d x %d of %d x %d  post %s  style %s\n%d draws  %.2f M tris (terrain %.2f, trees %.2f, grass %.2f)\n%s" % [
		Engine.get_frames_per_second(), post.internal.x, post.internal.y, post.screen.x, post.screen.y, "on" if post.is_on() else "off", env_sys.style,
		bench_sys.last_draws, bench_sys.last_prims / 1.0e6, terrain_sys.last_tris / 1.0e6, trees_sys.last_tris / 1.0e6, grass_sys.last_tris / 1.0e6, _scr_line]
