extends Node

# On-device interleaved GPU cost breakdown (?bench=sweep).
#
# Why interleaved: on phones (e.g. iPhone 13 mini) WebGL2 lacks EXT_disjoint_timer_query_webgl2
# and the SoC heats up over successive runs, so separate page loads cannot be compared. Running
# `base, V0, base, V1, base, V2, ..., base` inside one run lets each variant compare its median
# frame time against the mean of its two immediate neighbouring base windows, cancelling thermal
# drift while also reporting start-vs-end base drift.
#
# Fixed camera poses (trailhead, then forest; no walking). Reuses existing lever paths where they
# exist and restores base state completely when finished.

signal finished(result: Dictionary)

const FrameTimer := preload("res://systems/frame_timer.gd")
const Flags := preload("res://systems/flags.gd")

const DEFAULT_POSES: Array[String] = ["trailhead", "forest"]
const POSE_WARMUP_S := 2.0
const POSE_WARMUP_FRAMES := 30
const SWITCH_SETTLE_S := 0.30
const SWITCH_SETTLE_FRAMES := 8
const WINDOW_S := 2.5
const WINDOW_MIN_FRAMES := 60
const WINDOW_MAX_S := 8.0

var env_sys: Node
var post: Node
var terrain_sys: Node
var trees_sys: Node
var grass_sys: Node
var clouds_sys: Node
var cam: Camera3D
var settings: Callable

var running := false
var progress := ""
var prof_us := 0

var _poses: Array[String] = []
var _pose_i := 0
var _variants: Array[Dictionary] = []
var _skipped: Array[String] = []
var _schedule: Array[Dictionary] = []
var _step_i := 0
var _measuring := false
var _settle_s := 0.0
var _settle_frames := 0
var _warm := 0
var _t0_us := 0
var _last_us := 0
var _run_t0_us := 0
var _frames: Array[float] = []
var _draws_sum := 0.0
var _tris_sum := 0.0
var _step_records: Array[Dictionary] = []
var _pose_results: Array[Dictionary] = []

var _base_post := true
var _base_style := "painterly"
var _base_grass := true
var _base_trees := true
var _base_clouds := true


func _ready() -> void:
	# Last in the frame, matching bench.gd.
	process_priority = 1 << 30
	FrameTimer.install()


func setup(nodes: Dictionary) -> void:
	env_sys = nodes.env
	post = nodes.post
	terrain_sys = nodes.terrain
	trees_sys = nodes.trees
	grass_sys = nodes.grass
	clouds_sys = nodes.clouds
	cam = nodes.cam
	settings = nodes.settings


func start() -> void:
	running = true
	FrameTimer.install()
	Engine.max_fps = 0
	if not OS.has_feature("web"):
		DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	_base_post = post.is_on()
	_base_style = env_sys.style
	_base_grass = grass_sys.is_on()
	_base_trees = trees_sys.is_on()
	_base_clouds = clouds_sys.is_on()
	_poses = _pick_poses()
	_build_variants()
	_pose_i = 0
	_pose_results.clear()
	_run_t0_us = Time.get_ticks_usec()
	_begin_pose()


func _pick_poses() -> Array[String]:
	var raw := Flags.value("sweep_poses", "")
	if raw == "":
		return DEFAULT_POSES.duplicate()
	var out: Array[String] = []
	for p in raw.split(","):
		var s := p.strip_edges()
		if s == "trailhead" or s == "forest":
			out.append(s)
	return out if not out.is_empty() else DEFAULT_POSES.duplicate()


func _build_variants() -> void:
	_variants.clear()
	_skipped.clear()
	if _base_post:
		_variants.append({"id": "post_off", "label": "post off", "disjoint": true})
	else:
		_skipped.append("post_off (base post already off)")
	_variants.append({"id": "res_50", "label": "res 50%", "disjoint": false})
	if _base_grass:
		_variants.append({"id": "grass_off", "label": "grass off", "disjoint": true})
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
	_variants.append({"id": "terrain_flat", "label": "terrain flat", "disjoint": true})
	_variants.append({"id": "sky_flat", "label": "sky flat", "disjoint": true})
	if _base_clouds:
		_variants.append({"id": "clouds_off", "label": "clouds off", "disjoint": true})
	else:
		_skipped.append("clouds_off (base clouds off)")
	_variants.append({"id": "cirrus_off", "label": "cirrus off", "disjoint": false})
	var alt_style := "classic" if _base_style == "painterly" else "painterly"
	_variants.append({"id": "style_" + alt_style, "label": "style " + alt_style, "disjoint": false})


func _reset_to_base() -> void:
	post.set_on(_base_post)
	post.set_scale_mult(1.0)
	grass_sys.set_on(_base_grass)
	grass_sys.set_grass_on(true)
	grass_sys.set_flowers_on(true)
	trees_sys.set_on(_base_trees)
	trees_sys.set_impostors_on(true)
	terrain_sys.set_flat(false)
	env_sys.set_sky_flat(false)
	env_sys.set_cirrus_on(true)
	clouds_sys.set_on(_base_clouds)
	env_sys.set_style(_base_style)
	post.set_painterly(_base_style != "classic")
	clouds_sys.set_painterly(_base_style != "classic")


func _apply_variant(id: String) -> void:
	_reset_to_base()
	match id:
		"base":
			pass
		"post_off":
			post.set_on(false)
		"res_50":
			post.set_scale_mult(0.5)
		"grass_off":
			grass_sys.set_grass_on(false)
		"flowers_off":
			grass_sys.set_flowers_on(false)
		"trees_off":
			trees_sys.set_on(false)
		"impostors_off":
			trees_sys.set_impostors_on(false)
		"terrain_flat":
			terrain_sys.set_flat(true)
		"sky_flat":
			env_sys.set_sky_flat(true)
		"clouds_off":
			clouds_sys.set_on(false)
		"cirrus_off":
			env_sys.set_cirrus_on(false)
		"style_classic":
			env_sys.set_style("classic")
			post.set_painterly(false)
			clouds_sys.set_painterly(false)
		"style_painterly":
			env_sys.set_style("painterly")
			post.set_painterly(true)
			clouds_sys.set_painterly(true)


func _begin_pose() -> void:
	var pose := _poses[_pose_i]
	_reset_to_base()
	cam.set_mode(cam.MODES.find(pose))
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
	_apply_variant(step.id)
	_measuring = false
	_warm = 0
	_settle_s = POSE_WARMUP_S if is_pose_warmup else SWITCH_SETTLE_S
	_settle_frames = POSE_WARMUP_FRAMES if is_pose_warmup else SWITCH_SETTLE_FRAMES
	_t0_us = Time.get_ticks_usec()


func _begin_measure(now: int) -> void:
	_measuring = true
	_t0_us = now
	_last_us = now
	_frames.clear()
	_draws_sum = 0.0
	_tris_sum = 0.0
	FrameTimer.start(Flags.has("nogputimer"))


func _process(_delta: float) -> void:
	var t0 := Time.get_ticks_usec()
	if running:
		_step()
	prof_us = Time.get_ticks_usec() - t0


func _step() -> void:
	var now := Time.get_ticks_usec()
	var pose := _poses[_pose_i]
	var step: Dictionary = _schedule[_step_i]
	var el := (now - _t0_us) / 1.0e6
	var total_steps := _schedule.size()
	if not _measuring:
		_warm += 1
		progress = "%s %d/%d  %s (settle)" % [pose, _step_i + 1, total_steps, step.label]
		if el >= _settle_s and _warm >= _settle_frames:
			_begin_measure(now)
		return
	_frames.append((now - _last_us) / 1000.0)
	_last_us = now
	_draws_sum += RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_DRAW_CALLS_IN_FRAME)
	_tris_sum += RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_PRIMITIVES_IN_FRAME)
	var n := _frames.size()
	progress = "%s %d/%d  %s  %.1f/%.1fs (%df)" % [pose, _step_i + 1, total_steps, step.label, el, WINDOW_S, n]
	if not ((el >= WINDOW_S and n >= WINDOW_MIN_FRAMES) or el >= WINDOW_MAX_S):
		return
	var timing := FrameTimer.analyze(FrameTimer.stop())
	var rec := _window_stats(step, el, timing)
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


func _window_stats(step: Dictionary, dur_s: float, timing: Dictionary) -> Dictionary:
	var sorted := _frames.duplicate()
	sorted.sort()
	var n := _frames.size()
	var sum := 0.0
	for v in _frames:
		sum += v
	var out := {
		"id": step.id,
		"label": step.label,
		"kind": step.kind,
		"frames": n,
		"seconds": snappedf(dur_s, 0.01),
		"median_ms": snappedf(_median_sorted(sorted), 0.01),
		"avg_ms": snappedf(sum / maxf(1.0, float(n)), 0.01),
		"p95_ms": snappedf(_pct_sorted(sorted, 0.95), 0.01),
		"draws": roundi(_draws_sum / maxf(1.0, float(n))),
		"tris": roundi(_tris_sum / maxf(1.0, float(n))),
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
	for rec in _step_records:
		if rec.kind == "base":
			base_samples.append(rec)
			base_meds.append(float(rec.median_ms))
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
	_pose_results.append({
		"pose": pose,
		"base_start_ms": snappedf(base_start, 0.01),
		"base_end_ms": snappedf(base_end, 0.01),
		"base_median_ms": snappedf(base_med, 0.01),
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
	result["poses"] = _pose_results.duplicate(true)
	result["skipped"] = _skipped.duplicate()
	var line := JSON.stringify(result)
	print("SWEEP " + line)
	if OS.has_feature("web"):
		JavaScriptBridge.eval("window.__sweep = JSON.parse(%s);" % JSON.stringify(line))
	finished.emit(result)


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
