extends Node

# On-device interleaved GPU + CPU cost breakdown (?bench=sweep).
#
# Interleaves `base, V0, base, V1, ..., base, V_{K-1}, base` on fixed camera poses (trailhead and
# forest, first pose alternating between runs) so slow thermal drift cancels against each variant's immediate neighbouring base windows.
# Also records per-window CPU cost from the early HTML rAF wrapper (window.__rafTimer: callback
# duration and rAF interval via performance.now()) and Godot's Performance TIME_PROCESS /
# TIME_PHYSICS_PROCESS medians, alongside FrameTimer's WebGL wait / GPU timer where available.

signal finished(result: Dictionary)

const FrameTimer := preload("res://systems/frame_timer.gd")
const Flags := preload("res://systems/flags.gd")

const DEFAULT_POSES: Array[String] = ["trailhead", "forest"]
const SUB_PROFS: Array[String] = ["select_us", "push_us", "uniform_us", "grass_us", "flowers_us", "hero_us", "mid_us", "flags_us", "prefetch_us", "count_us"]
const POSE_WARMUP_S := 1.5
const POSE_WARMUP_FRAMES := 24
const SWITCH_SETTLE_S := 0.10
const SWITCH_SETTLE_FRAMES := 4
const WINDOW_S := 1.0
const WINDOW_MIN_FRAMES := 60
const WINDOW_MAX_S := 6.0

var env_sys: Node
var post: Node
var terrain_sys: Node
var water_sys: Node
var props_sys: Node
var trees_sys: Node
var grass_sys: Node
var clouds_sys: Node
var cam: Camera3D
var ui_sys: Node
var bench_sys: Node
var settings: Callable
var profiled: Dictionary = {}

var running := false
var progress := ""
var prof_us := 0
var _prof_entries: Array = []
var _sys_sums: Dictionary = {}

var _poses: Array[String] = []
var _pose_i := 0
var _variants: Array[Dictionary] = []
var _skipped: Array[String] = []
var _notes: Array[String] = []
var _schedule: Array[Dictionary] = []
var _step_i := 0
var _measuring := false
var _frozen_step := false
var _settle_s := 0.0
var _settle_frames := 0
var _warm := 0
var _t0_us := 0
var _last_us := 0
var _run_t0_us := 0
var _frame_start_us := 0
var _frames: Array[float] = []
var _script_ms: Array[float] = []
var _proc_ms: Array[float] = []
var _phys_ms: Array[float] = []
var _draws_sum := 0.0
var _tris_sum := 0.0
var _draws_n := 0
var _step_records: Array[Dictionary] = []
var _pose_results: Array[Dictionary] = []

var _base_post := true
var _base_style := "painterly"
var _base_ground_live := false
var _base_grass := true
var _base_grass_painted := true
var _base_trees := true
var _base_water := true
var _base_props := true
var _base_clouds := true
var _base_cloud_billboard := false
var _base_sky_clouds := true
var _base_shadow := false
var _prev_rebaked_grass := false


func _ready() -> void:
	# Strictly after bench.gd (1 << 30), so script_us and bench.prof_us cover the full frame.
	process_priority = (1 << 30) + 1
	get_tree().process_frame.connect(func() -> void: _frame_start_us = Time.get_ticks_usec())
	FrameTimer.install()


func setup(nodes: Dictionary) -> void:
	env_sys = nodes.env
	post = nodes.post
	terrain_sys = nodes.terrain
	water_sys = nodes.get("water", null)
	props_sys = nodes.get("props", null)
	trees_sys = nodes.trees
	grass_sys = nodes.grass
	clouds_sys = nodes.clouds
	cam = nodes.cam
	ui_sys = nodes.get("ui", null)
	bench_sys = nodes.get("bench", null)
	settings = nodes.settings
	profiled = nodes.get("profiled", {})


func _build_prof_entries() -> void:
	_prof_entries.clear()
	for k in profiled:
		var node: Object = profiled[k]
		if node == null:
			continue
		_prof_entries.append([String(k), node, &"prof_us"])
		for sub in SUB_PROFS:
			if node.get(sub) != null:
				_prof_entries.append(["%s.%s" % [k, sub.trim_suffix("_us")], node, StringName(sub)])


func start() -> void:
	running = true
	FrameTimer.install()
	Engine.max_fps = 0
	if not OS.has_feature("web"):
		DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	_base_post = post.is_on()
	_base_style = env_sys.style
	_base_ground_live = terrain_sys.live_override
	_base_grass = grass_sys.is_on()
	_base_grass_painted = grass_sys.is_painted()
	_base_trees = trees_sys.is_on()
	_base_water = water_sys != null and water_sys.is_on()
	_base_props = props_sys != null and props_sys.is_on()
	_base_cloud_billboard = clouds_sys.is_on()
	_base_sky_clouds = env_sys.sky_clouds_on
	_base_clouds = _base_cloud_billboard or _base_sky_clouds
	_base_shadow = env_sys.sun != null and env_sys.sun.shadow_enabled
	_build_prof_entries()
	_poses = _pick_poses()
	_build_variants()
	_pose_i = 0
	_pose_results.clear()
	_run_t0_us = Time.get_ticks_usec()
	_begin_pose()


func _pick_poses() -> Array[String]:
	var raw := Flags.value("sweep_poses", "")
	if raw == "":
		# A phone warms up over a run, so the second pose always measures a hotter device. Swapping
		# the order on every other run spreads that bias over both poses.
		var order := DEFAULT_POSES.duplicate()
		if _next_run_index() % 2 == 1:
			order.reverse()
		return order
	var out: Array[String] = []
	for p in raw.split(","):
		var s := p.strip_edges()
		if s == "trailhead" or s == "forest" or (cam != null and cam.world != null and cam.world.has_pose(s)):
			out.append(s)
	return out if not out.is_empty() else DEFAULT_POSES.duplicate()


# Counts sweep runs on this device (localStorage on the web, a user:// file elsewhere) and returns
# the count before this run.
static func _next_run_index() -> int:
	if OS.has_feature("web"):
		var v = JavaScriptBridge.eval("(function(){try{var n=+(localStorage.getItem('sw_sweep_runs')||0);localStorage.setItem('sw_sweep_runs',String(n+1));return n;}catch(e){return 0;}})()")
		return int(v) if v != null else 0
	var path := "user://sweep_runs.txt"
	var n := 0
	if FileAccess.file_exists(path):
		n = FileAccess.get_file_as_string(path).to_int()
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f != null:
		f.store_string(str(n + 1))
	return n


func _build_variants() -> void:
	_variants.clear()
	_skipped.clear()
	_notes.clear()
	# v2 diagnostic legs (floor, terrain vertex+frag, combined veg, res 25%, frozen GDScript)
	# interleaved with all v1 single-system legs.
	_variants.append({"id": "floor", "label": "floor all off", "disjoint": false})
	_variants.append({"id": "no_script", "label": "no gdscript", "disjoint": false})
	_variants.append({"id": "res_25", "label": "res 25%", "disjoint": false})
	_variants.append({"id": "res_50", "label": "res 50%", "disjoint": false})
	if _base_post:
		_variants.append({"id": "post_off", "label": "post off", "disjoint": true})
	else:
		_skipped.append("post_off (base post already off)")
	_variants.append({"id": "terrain_off", "label": "terrain off", "disjoint": false})
	_variants.append({"id": "terrain_flat", "label": "terrain flat", "disjoint": true})
	if _base_style != "classic":
		if _base_ground_live:
			_variants.append({"id": "ground_baked", "label": "ground baked", "disjoint": false})
		else:
			_variants.append({"id": "ground_live", "label": "ground live", "disjoint": false})
	if _base_grass or _base_trees:
		_variants.append({"id": "veg_off", "label": "all veg off", "disjoint": false})
	if _base_grass:
		_variants.append({"id": "grass_off", "label": "grass off", "disjoint": true})
		if _base_grass_painted:
			_variants.append({"id": "grass_classic", "label": "grass classic", "disjoint": false})
		else:
			_variants.append({"id": "grass_painted", "label": "grass painted", "disjoint": false})
		_variants.append({"id": "flowers_off", "label": "flowers off", "disjoint": true})
	else:
		_skipped.append("grass_off (base grass off)")
		_skipped.append("flowers_off (base grass off)")
	if _base_trees:
		_variants.append({"id": "trees_off", "label": "trees off", "disjoint": true})
		_variants.append({"id": "impostors_off", "label": "impostors off", "disjoint": false})
	else:
		_skipped.append("trees_off (base trees off)")
		_skipped.append("impostors_off (base trees off)")
	if _base_water:
		_variants.append({"id": "water_off", "label": "water off", "disjoint": true})
	else:
		_skipped.append("water_off (base water off)")
	if _base_props:
		_variants.append({"id": "props_off", "label": "props off", "disjoint": true})
	else:
		_skipped.append("props_off (base props off)")
	_variants.append({"id": "sky_flat", "label": "sky flat", "disjoint": true})
	if _base_clouds:
		_variants.append({"id": "clouds_off", "label": "clouds off", "disjoint": true})
	else:
		_skipped.append("clouds_off (base clouds off)")
	if _base_cloud_billboard:
		_variants.append({"id": "clouds_sky", "label": "clouds sky", "disjoint": false})
	else:
		_variants.append({"id": "clouds_billboard", "label": "clouds bboard", "disjoint": false})
	_variants.append({"id": "cirrus_off", "label": "cirrus off", "disjoint": false})
	var alt_style := "classic" if _base_style == "painterly" else "painterly"
	_variants.append({"id": "style_" + alt_style, "label": "style " + alt_style, "disjoint": false})
	if _base_shadow:
		_variants.append({"id": "shadows_off", "label": "shadows off", "disjoint": false})
	else:
		_notes.append("no shadow pass")
		_skipped.append("shadows_off (no shadow pass)")
		print("SWEEP_NOTE no shadow pass")


func _set_systems_frozen(v: bool) -> void:
	_frozen_step = v
	terrain_sys.set_frozen(v)
	grass_sys.set_frozen(v)
	trees_sys.set_frozen(v)
	if props_sys != null:
		props_sys.set_frozen(v)
	env_sys.set_frozen(v)
	post.set_frozen(v)
	cam.set_process(not v)
	if bench_sys != null:
		bench_sys.set_process(not v)
	if ui_sys != null:
		ui_sys.set_frozen(v)


func _reset_to_base() -> void:
	_set_systems_frozen(false)
	post.set_on(_base_post)
	post.set_scale_mult(1.0)
	terrain_sys.set_on(true)
	terrain_sys.set_flat(false)
	terrain_sys.set_live(_base_ground_live)
	terrain_sys.set_painterly(_base_style != "classic")
	grass_sys.set_on(_base_grass)
	grass_sys.set_painted(_base_grass_painted)
	grass_sys.set_grass_on(true)
	grass_sys.set_flowers_on(true)
	trees_sys.set_on(_base_trees)
	trees_sys.set_impostors_on(true)
	if water_sys != null:
		water_sys.set_on(_base_water)
	if props_sys != null:
		props_sys.set_on(_base_props)
	env_sys.set_sky_flat(false)
	env_sys.set_cirrus_on(true)
	env_sys.set_sky_clouds_on(_base_sky_clouds)
	if env_sys.sun != null:
		env_sys.sun.shadow_enabled = _base_shadow
	clouds_sys.set_on(_base_cloud_billboard)
	env_sys.set_style(_base_style)
	post.set_painterly(_base_style != "classic")
	clouds_sys.set_painterly(_base_style != "classic")


func _apply_variant(id: String) -> void:
	_reset_to_base()
	match id:
		"base":
			pass
		"floor":
			terrain_sys.set_on(false)
			if water_sys != null:
				water_sys.set_on(false)
			if props_sys != null:
				props_sys.set_on(false)
			grass_sys.set_on(false)
			trees_sys.set_on(false)
			trees_sys.set_impostors_on(false)
			clouds_sys.set_on(false)
			env_sys.set_sky_flat(true)
			post.set_on(false)
		"no_script":
			if ui_sys != null:
				ui_sys.set_progress_text("Sweep  %s %d/%d  no gdscript" % [_poses[_pose_i], _step_i + 1, _schedule.size()])
			_set_systems_frozen(true)
		"post_off":
			post.set_on(false)
		"res_50":
			post.set_scale_mult(0.5)
		"res_25":
			post.set_scale_mult(0.25)
		"terrain_off":
			terrain_sys.set_on(false)
		"terrain_flat":
			terrain_sys.set_flat(true)
			if terrain_sys.flat_mat != null:
				terrain_sys.flat_mat.render_priority = -1
		"ground_live":
			terrain_sys.set_live(true)
		"ground_baked":
			terrain_sys.set_live(false)
		"veg_off":
			grass_sys.set_on(false)
			trees_sys.set_on(false)
			trees_sys.set_impostors_on(false)
		"grass_off":
			grass_sys.set_grass_on(false)
		"grass_classic":
			grass_sys.set_painted(false)
		"grass_painted":
			grass_sys.set_painted(true)
		"flowers_off":
			grass_sys.set_flowers_on(false)
		"trees_off":
			trees_sys.set_on(false)
		"impostors_off":
			trees_sys.set_impostors_on(false)
		"water_off":
			if water_sys != null:
				water_sys.set_on(false)
		"props_off":
			if props_sys != null:
				props_sys.set_on(false)
		"sky_flat":
			env_sys.set_sky_flat(true)
		"clouds_off":
			clouds_sys.set_on(false)
			env_sys.set_sky_clouds_on(false)
		"clouds_billboard":
			env_sys.set_sky_clouds_on(false)
			clouds_sys.set_on(true)
		"clouds_sky":
			clouds_sys.set_on(false)
			env_sys.set_sky_clouds_on(true)
		"cirrus_off":
			env_sys.set_cirrus_on(false)
		"shadows_off":
			if env_sys.sun != null:
				env_sys.sun.shadow_enabled = false
		"style_classic":
			env_sys.set_style("classic")
			post.set_painterly(false)
			clouds_sys.set_painterly(false)
			terrain_sys.set_painterly(false)
			grass_sys.set_painted(false)
		"style_painterly":
			env_sys.set_style("painterly")
			post.set_painterly(true)
			clouds_sys.set_painterly(true)
			terrain_sys.set_painterly(true)
			grass_sys.set_painted(true)


func _begin_pose() -> void:
	var pose := _poses[_pose_i]
	_reset_to_base()
	cam.set_pose_name(pose)
	_schedule.clear()
	_step_records.clear()
	# Interleave: base, V0, base, V1, ..., base, V_{K-1}, base.
	for i in _variants.size():
		_schedule.append({"id": "base", "label": "base", "kind": "base", "base_idx": i})
		_schedule.append({"id": _variants[i].id, "label": _variants[i].label, "kind": "variant", "var_idx": i, "disjoint": _variants[i].disjoint})
	_schedule.append({"id": "base", "label": "base", "kind": "base", "base_idx": _variants.size()})
	_step_i = 0
	_begin_step(true)


func _begin_step(is_pose_warmup: bool) -> void:
	var step: Dictionary = _schedule[_step_i]
	var prev_painted: bool = grass_sys.is_painted()
	_apply_variant(step.id)
	var rebaked_grass: bool = grass_sys.is_painted() != prev_painted
	_measuring = false
	_warm = 0
	var long_settle: bool = is_pose_warmup or str(step.id) == "ground_baked" or rebaked_grass or _prev_rebaked_grass
	_prev_rebaked_grass = rebaked_grass
	_settle_s = POSE_WARMUP_S if long_settle else SWITCH_SETTLE_S
	_settle_frames = POSE_WARMUP_FRAMES if long_settle else SWITCH_SETTLE_FRAMES
	_t0_us = Time.get_ticks_usec()


func _begin_measure(now: int) -> void:
	_measuring = true
	_t0_us = now
	_last_us = now
	_frames.clear()
	_script_ms.clear()
	_proc_ms.clear()
	_phys_ms.clear()
	_sys_sums.clear()
	for e in _prof_entries:
		_sys_sums[e[0]] = 0.0
	_draws_sum = 0.0
	_tris_sum = 0.0
	_draws_n = 0
	FrameTimer.start(Flags.has("nogputimer"))
	_raf_start()


func _raf_start() -> void:
	if OS.has_feature("web"):
		JavaScriptBridge.eval("window.__rafTimer && window.__rafTimer.start()")


func _raf_stop() -> Dictionary:
	if not OS.has_feature("web"):
		return {}
	var s = JavaScriptBridge.eval("window.__rafTimer ? window.__rafTimer.stop() : ''")
	if s == null or str(s) == "":
		return {}
	var d = JSON.parse_string(str(s))
	return d if d is Dictionary else {}


func _process(_delta: float) -> void:
	var t0 := Time.get_ticks_usec()
	var script_us := t0 - _frame_start_us
	if running:
		_step(script_us)
	prof_us = Time.get_ticks_usec() - t0


func _step(script_us: int) -> void:
	var now := Time.get_ticks_usec()
	var step: Dictionary = _schedule[_step_i]
	var el := (now - _t0_us) / 1.0e6
	if not _measuring:
		_warm += 1
		if not _frozen_step:
			progress = "%s %d/%d  %s (settle)" % [_poses[_pose_i], _step_i + 1, _schedule.size(), step.label]
		if el >= _settle_s and _warm >= _settle_frames:
			_begin_measure(now)
		return
	_frames.append((now - _last_us) / 1000.0)
	_last_us = now
	_script_ms.append(maxf(0.0, float(script_us) / 1000.0))
	_proc_ms.append(Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0)
	_phys_ms.append(Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0)
	for e in _prof_entries:
		_sys_sums[e[0]] = float(_sys_sums[e[0]]) + float((e[1] as Object).get(e[2]))
	if not _frozen_step or _draws_n == 0:
		_draws_sum += RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_DRAW_CALLS_IN_FRAME)
		_tris_sum += RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_PRIMITIVES_IN_FRAME)
		_draws_n += 1
	var n := _frames.size()
	if not _frozen_step and (n == 1 or n % 15 == 0):
		progress = "%s %d/%d  %s  %.1f/%.1fs (%df)" % [_poses[_pose_i], _step_i + 1, _schedule.size(), step.label, el, WINDOW_S, n]
	if not ((el >= WINDOW_S and n >= WINDOW_MIN_FRAMES) or el >= WINDOW_MAX_S):
		return
	var raf := _raf_stop()
	var timing := FrameTimer.analyze(FrameTimer.stop())
	var rec := _window_stats(step, el, timing, raf)
	_step_records.append(rec)
	_step_i += 1
	if _step_i < _schedule.size():
		_begin_step(false)
	else:
		_finish_pose()
		_pose_i += 1
		if _pose_i < _poses.size():
			_begin_pose()
		else:
			_finish_all()


func _window_stats(step: Dictionary, dur_s: float, timing: Dictionary, raf: Dictionary) -> Dictionary:
	var sorted := _frames.duplicate()
	sorted.sort()
	var scr_s := _script_ms.duplicate()
	scr_s.sort()
	var proc_s := _proc_ms.duplicate()
	proc_s.sort()
	var phys_s := _phys_ms.duplicate()
	phys_s.sort()
	var n := _frames.size()
	var sum := 0.0
	for v in _frames:
		sum += v
	var raf_cpu: Array = raf.get("cpu", [])
	var raf_iv: Array = raf.get("iv", [])
	var raf_cpu_med := -1.0
	var raf_iv_med := -1.0
	if not raf_cpu.is_empty():
		var rc := raf_cpu.duplicate()
		rc.sort()
		raf_cpu_med = snappedf(_median_sorted(rc), 0.01)
	if not raf_iv.is_empty():
		var ri := raf_iv.duplicate()
		ri.sort()
		raf_iv_med = snappedf(_median_sorted(ri), 0.01)
	var out := {
		"id": step.id,
		"label": step.label,
		"kind": step.kind,
		"frames": n,
		"seconds": snappedf(dur_s, 0.01),
		"median_ms": snappedf(_median_sorted(sorted), 0.01),
		"avg_ms": snappedf(sum / maxf(1.0, float(n)), 0.01),
		"p95_ms": snappedf(_pct_sorted(sorted, 0.95), 0.01),
		"raf_cpu_ms": raf_cpu_med,
		"raf_iv_ms": raf_iv_med,
		"raf_samples": raf_cpu.size(),
		"script_ms": snappedf(_median_sorted(scr_s), 0.01),
		"perf_proc_ms": snappedf(_median_sorted(proc_s), 0.01),
		"phys_ms": snappedf(_median_sorted(phys_s), 0.01),
		"sys_ms": _sys_avgs(n),
		"draws": roundi(_draws_sum / maxf(1.0, float(_draws_n))),
		"tris": roundi(_tris_sum / maxf(1.0, float(_draws_n))),
		"internal": [post.internal.x, post.internal.y],
	}
	if timing.has("cpu_avg"):
		out["cpu_avg"] = timing.cpu_avg
		out["work_avg"] = timing.work_avg
		out["wait_avg"] = timing.wait_avg
		out["gpu_avg"] = timing.gpu_avg
		out["gpu_state"] = timing.gpu_state
		out["vsync_locked"] = timing.vsync_locked
	return out


func _finish_pose() -> void:
	var pose := _poses[_pose_i]
	var base_samples: Array[Dictionary] = []
	var base_meds: Array[float] = []
	var base_cpus: Array[float] = []
	var base_rafs: Array[float] = []
	var base_scrs: Array[float] = []
	var base_procs: Array[float] = []
	var base_physs: Array[float] = []
	var base_sys_acc: Dictionary = {}
	for rec in _step_records:
		if rec.kind == "base":
			base_samples.append(rec)
			base_meds.append(float(rec.median_ms))
			if float(rec.raf_cpu_ms) >= 0.0:
				base_cpus.append(float(rec.raf_cpu_ms))
			if float(rec.raf_iv_ms) >= 0.0:
				base_rafs.append(float(rec.raf_iv_ms))
			base_scrs.append(float(rec.script_ms))
			base_procs.append(float(rec.perf_proc_ms))
			base_physs.append(float(rec.phys_ms))
			var sm: Dictionary = rec.get("sys_ms", {})
			for sk in sm:
				base_sys_acc[sk] = float(base_sys_acc.get(sk, 0.0)) + float(sm[sk])
	var rows: Array[Dictionary] = []
	var additive_save := 0.0
	for k in _variants.size():
		var rec: Dictionary = _step_records[2 * k + 1]
		var b_before: float = base_meds[k]
		var b_after: float = base_meds[k + 1]
		var local_base := 0.5 * (b_before + b_after)
		var med := float(rec.median_ms)
		var delta_ms := med - local_base
		var save_ms := local_base - med
		var delta_pct := (delta_ms / maxf(local_base, 0.001)) * 100.0
		var share_pct := (save_ms / maxf(local_base, 0.001)) * 100.0
		var row := rec.duplicate()
		row["disjoint"] = _variants[k].disjoint
		row["base_before_ms"] = snappedf(b_before, 0.01)
		row["base_after_ms"] = snappedf(b_after, 0.01)
		row["base_ms"] = snappedf(local_base, 0.01)
		row["delta_ms"] = snappedf(delta_ms, 0.01)
		row["save_ms"] = snappedf(save_ms, 0.01)
		row["delta_pct"] = snappedf(delta_pct, 0.1)
		row["share_pct"] = snappedf(share_pct, 0.1)
		if _variants[k].disjoint:
			additive_save += save_ms
		rows.append(row)
	# Biggest savings (most negative delta_ms) first.
	rows.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return float(a.delta_ms) < float(b.delta_ms))
	var base_sorted := base_meds.duplicate()
	base_sorted.sort()
	var base_med := _median_sorted(base_sorted)
	var base_start := base_meds[0]
	var base_end := base_meds[base_meds.size() - 1]
	base_cpus.sort()
	base_rafs.sort()
	base_scrs.sort()
	base_procs.sort()
	base_physs.sort()
	var base_sys_ms := {}
	var bn := maxf(1.0, float(base_samples.size()))
	var skeys := base_sys_acc.keys()
	skeys.sort_custom(func(a: String, b: String) -> bool: return float(base_sys_acc[a]) > float(base_sys_acc[b]))
	for sk in skeys:
		base_sys_ms[sk] = snappedf(float(base_sys_acc[sk]) / bn, 0.001)
	_pose_results.append({
		"pose": pose,
		"base_start_ms": snappedf(base_start, 0.01),
		"base_end_ms": snappedf(base_end, 0.01),
		"base_median_ms": snappedf(base_med, 0.01),
		"base_raf_cpu_ms": snappedf(_median_sorted(base_cpus), 0.01) if not base_cpus.is_empty() else -1.0,
		"base_raf_iv_ms": snappedf(_median_sorted(base_rafs), 0.01) if not base_rafs.is_empty() else -1.0,
		"base_script_ms": snappedf(_median_sorted(base_scrs), 0.01),
		"base_perf_proc_ms": snappedf(_median_sorted(base_procs), 0.01),
		"base_phys_ms": snappedf(_median_sorted(base_physs), 0.01),
		"base_sys_ms": base_sys_ms,
		"drift_ms": snappedf(base_end - base_start, 0.01),
		"additive_save_ms": snappedf(additive_save, 0.01),
		"additive_share_pct": snappedf((additive_save / maxf(base_med, 0.001)) * 100.0, 0.1),
		"base_draws": int(base_samples[0].draws),
		"base_tris": int(base_samples[0].tris),
		"base_samples": base_samples,
		"variants": rows,
	})


func _finish_all() -> void:
	_reset_to_base()
	running = false
	progress = ""
	var total_s := snappedf((Time.get_ticks_usec() - _run_t0_us) / 1.0e6, 0.1)
	var result: Dictionary = settings.call()
	result["mode"] = "sweep"
	result["total_s"] = total_s
	result["window_s"] = WINDOW_S
	result["window_min_frames"] = WINDOW_MIN_FRAMES
	result["settle_frames"] = SWITCH_SETTLE_FRAMES
	result["pose_order"] = _poses.duplicate()
	result["poses"] = _pose_results.duplicate(true)
	result["notes"] = _notes.duplicate()
	result["skipped"] = _skipped.duplicate()
	var line := JSON.stringify(result)
	print("SWEEP " + line)
	if OS.has_feature("web"):
		JavaScriptBridge.eval("window.__sweep = JSON.parse(%s);" % JSON.stringify(line))
	finished.emit(result)


func _sys_avgs(n: int) -> Dictionary:
	var keys := _sys_sums.keys()
	keys.sort_custom(func(a: String, b: String) -> bool: return float(_sys_sums[a]) > float(_sys_sums[b]))
	var out := {}
	var div := maxf(1.0, float(n)) * 1000.0
	for k in keys:
		out[k] = snappedf(float(_sys_sums[k]) / div, 0.001)
	return out


static func _median_sorted(s: Array) -> float:
	var n := s.size()
	if n == 0:
		return 0.0
	if n % 2 == 1:
		return float(s[n / 2])
	return 0.5 * (float(s[n / 2 - 1]) + float(s[n / 2]))


static func _pct_sorted(s: Array, p: float) -> float:
	if s.is_empty():
		return 0.0
	return float(s[clampi(int(ceil(p * s.size())) - 1, 0, s.size() - 1)])
