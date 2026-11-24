extends Node

# Two jobs:
# 1. The Bench button / ?bench: Stillwater's bench route (src/dev/bench.js) cut to what this port
#    draws. Per stage: set the pose, settle SETTLE s (and at least 6 frames, Stillwater's warmup),
#    then measure. Stops (trailhead, forest) measure STOP_DUR s and at least 100 frames, capped at
#    30 s; the walk measures WALK_DUR s from the trailhead at 2.0 m/s. Frame time is the wall-clock
#    gap between frames (Time.get_ticks_usec); fps = frames / time; p50 / p95 use bench.js's
#    nearest-rank rule. Draws and triangles are the renderer's own per-frame counts, averaged.
#    The result goes to the on-screen panel, a BENCHRESULT console line and window.__benchResult.
#    Where the time goes, per stage: the main-thread time of each frame and the GPU time where the
#    browser has a timer query (systems/frame_timer.gd, Web only), split into script time (from the
#    tree's process_frame signal to this node, which processes last), render submit (frame_pre_draw
#    to frame_post_draw: culling, draw lists, WebGL calls, minus the GPU waits inside it), the GPU
#    waits and other (input, physics, engine overhead: what is left). Each system reports its own
#    _process time.
# 2. Passive: after any pose change, one BENCH line over a 20 s window (tools/measure_web.mjs).

signal finished(result: Dictionary)

const FrameTimer := preload("res://systems/frame_timer.gd")
const Flags := preload("res://systems/flags.gd")

const STAGES: Array[String] = ["trailhead", "forest", "walk"]
const SETTLE := 2.0
const WARM_FRAMES := 6
const STOP_DUR := 5.0
const MIN_FRAMES := 100
const STOP_MAX := 30.0
const WALK_DUR := 20.0
const TARGET_FPS := 30.0

const WARMUP := 3.0
const WINDOW := 20.0

var terrain_sys: Node
var trees_sys: Node
var grass_sys: Node
var clouds_sys: Node
var cam: Camera3D
var settings: Callable

var running := false
var stage_i := 0
var measuring := false
var t0_us := 0
var last_us := 0
var warm := 0
var frames: Array[float] = []
var sums := {}
var stages: Array[Dictionary] = []
var progress := ""

var pose_name := ""
var t := 0.0
var frame_ms: Array[float] = []
var draws_max := 0
var prims_max := 0
var terrain_tris_max := 0
var terrain_nodes_max := 0
var tree_tris_max := 0
var tree_draws_max := 0
var grass_tris_max := 0
var grass_draws_max := 0
var reported := false
var last_draws := 0
var last_prims := 0

# Systems whose prof_us (and push_us / count_us where present) the bench sums per frame.
var profiled := {}
var prof_us := 0
var _frame_start_us := 0
var _pre_draw_us := 0
var _render_us := -1
var script_ms: Array[float] = []
var render_ms: Array[float] = []
var sys_sums := {}


func _ready() -> void:
	# Last in the frame, so script time covers every other node's _process.
	process_priority = 1 << 30
	get_tree().process_frame.connect(func() -> void: _frame_start_us = Time.get_ticks_usec())
	RenderingServer.frame_pre_draw.connect(func() -> void: _pre_draw_us = Time.get_ticks_usec())
	RenderingServer.frame_post_draw.connect(func() -> void: _render_us = Time.get_ticks_usec() - _pre_draw_us)
	FrameTimer.install()


func setup(terrain_node: Node, trees_node: Node, grass_node: Node, clouds_node: Node, cam_node: Camera3D, settings_fn: Callable) -> void:
	terrain_sys = terrain_node
	trees_sys = trees_node
	grass_sys = grass_node
	clouds_sys = clouds_node
	cam = cam_node
	settings = settings_fn


func start() -> void:
	running = true
	FrameTimer.install()
	stages.clear()
	stage_i = 0
	Engine.max_fps = 0
	if not OS.has_feature("web"):
		DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	_begin_stage()


func _begin_stage() -> void:
	measuring = false
	warm = 0
	t0_us = Time.get_ticks_usec()
	cam.set_mode(cam.MODES.find(STAGES[stage_i]))


func _begin_measure(now: int) -> void:
	measuring = true
	t0_us = now
	last_us = now
	frames.clear()
	sums = {"draws": 0.0, "tris": 0.0, "terrain": 0.0, "trees": 0.0, "grass": 0.0}
	script_ms.clear()
	render_ms.clear()
	sys_sums.clear()
	_render_us = -1
	FrameTimer.start(Flags.has("nogputimer"))
	if STAGES[stage_i] == "walk":
		# The walk distance counts from the first measured frame, as bench.js times it.
		cam.set_mode(cam.MODES.find("walk"))


func restart(pose: String) -> void:
	pose_name = pose
	t = 0.0
	frame_ms.clear()
	draws_max = 0
	prims_max = 0
	terrain_tris_max = 0
	terrain_nodes_max = 0
	tree_tris_max = 0
	tree_draws_max = 0
	grass_tris_max = 0
	grass_draws_max = 0
	reported = false


func _process(delta: float) -> void:
	var t0 := Time.get_ticks_usec()
	var script_us := t0 - _frame_start_us
	last_draws = RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_DRAW_CALLS_IN_FRAME)
	last_prims = RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_PRIMITIVES_IN_FRAME)
	if running:
		_step_bench(script_us)
	else:
		_step_passive(delta)
	# Outside script_us (this node is last), so it counts as "other"; sampled into the next frame.
	prof_us = Time.get_ticks_usec() - t0


func _step_bench(script_us: int) -> void:
	var now := Time.get_ticks_usec()
	var stage := STAGES[stage_i]
	var el := (now - t0_us) / 1.0e6
	if not measuring:
		warm += 1
		progress = "%s  settling %.0f s" % [stage, maxf(0.0, SETTLE - el)]
		if el >= SETTLE and warm >= WARM_FRAMES:
			_begin_measure(now)
		return
	frames.append((now - last_us) / 1000.0)
	last_us = now
	sums.draws += last_draws
	sums.tris += last_prims
	sums.terrain += terrain_sys.last_tris
	sums.trees += trees_sys.last_tris
	sums.grass += grass_sys.last_tris
	script_ms.append(script_us / 1000.0)
	# The render span of the previous frame; the first measured frame has none.
	if _render_us >= 0:
		render_ms.append(_render_us / 1000.0)
	for k in profiled:
		var node: Object = profiled[k]
		sys_sums[k] = sys_sums.get(k, 0.0) + node.prof_us
		for sub in ["push_us", "count_us"]:
			var v = node.get(sub)
			if v != null:
				var key := "%s.%s" % [k, sub.trim_suffix("_us")]
				sys_sums[key] = sys_sums.get(key, 0.0) + v
	var n := frames.size()
	var dur := WALK_DUR if stage == "walk" else STOP_DUR
	progress = "%s  %.1f / %.0f s  %d frames" % [stage, el, dur, n]
	var done := el >= WALK_DUR if stage == "walk" else ((el >= STOP_DUR and n >= MIN_FRAMES) or el >= STOP_MAX)
	if not done:
		return
	var timing := FrameTimer.analyze(FrameTimer.stop())
	var st := _stage_stats(stage, el).merged(timing)
	if st.has("cpu_avg"):
		# The GPU waits happen inside the render span (Emscripten's frame commit), so render work is
		# the span minus them; other is what is left of the main-thread time.
		st["render_work_avg"] = snappedf(maxf(0.0, float(st.render_avg) - float(st.wait_avg)), 0.01)
		st["other_avg"] = snappedf(float(st.cpu_avg) - float(st.wait_avg) - float(st.script_avg) - float(st.render_work_avg), 0.01)
	stages.append(st)
	stage_i += 1
	if stage_i < STAGES.size():
		_begin_stage()
	else:
		running = false
		progress = ""
		_finish()


# bench.js percentiles: sorted[ceil(p * n) - 1].
static func pct(sorted: Array, p: float) -> float:
	return sorted[clampi(int(ceil(p * sorted.size())) - 1, 0, sorted.size() - 1)]


func _stage_stats(stage: String, dur_s: float) -> Dictionary:
	var sorted := frames.duplicate()
	sorted.sort()
	var n := frames.size()
	return {
		"stage": stage, "frames": n, "seconds": snappedf(dur_s, 0.01),
		"fps": snappedf(n / maxf(dur_s, 1e-3), 0.1),
		"p50_ms": snappedf(pct(sorted, 0.5), 0.01), "p95_ms": snappedf(pct(sorted, 0.95), 0.01),
		"draws": roundi(sums.draws / n), "tris": roundi(sums.tris / n),
		"terrain_tris": roundi(sums.terrain / n), "tree_tris": roundi(sums.trees / n), "grass_tris": roundi(sums.grass / n),
		"script_avg": snappedf(FrameTimer.avg(script_ms), 0.01), "script_p95": snappedf(FrameTimer.p95(script_ms), 0.01),
		"render_avg": snappedf(FrameTimer.avg(render_ms), 0.01), "render_p95": snappedf(FrameTimer.p95(render_ms), 0.01),
		"sys_ms": _sys_avgs(n),
	}


# Average ms per frame of each system's _process, biggest first.
func _sys_avgs(n: int) -> Dictionary:
	var keys := sys_sums.keys()
	keys.sort_custom(func(a: String, b: String) -> bool: return sys_sums[a] > sys_sums[b])
	var out := {}
	for k in keys:
		out[k] = snappedf(sys_sums[k] / n / 1000.0, 0.001)
	return out


func _finish() -> void:
	var worst: Dictionary = stages[0]
	for s in stages:
		if s.fps < worst.fps:
			worst = s
	var verdict: String
	if worst.fps >= TARGET_FPS:
		verdict = "MEETS 30 fps: worst stage %s at %.1f fps" % [worst.stage, worst.fps]
	else:
		verdict = "BELOW 30 fps: %s at %.1f fps, needs %.2fx faster" % [worst.stage, worst.fps, TARGET_FPS / maxf(worst.fps, 0.1)]
	var result: Dictionary = settings.call()
	result["stages"] = stages.duplicate()
	result["worst_fps"] = worst.fps
	result["verdict"] = verdict
	result["clouds_tris"] = clouds_sys.tris
	var line := JSON.stringify(result)
	print("BENCHRESULT " + line)
	if OS.has_feature("web"):
		JavaScriptBridge.eval("window.__benchResult = %s;" % JSON.stringify(line))
	finished.emit(result)


func _step_passive(delta: float) -> void:
	t += delta
	if t > WARMUP and t < WARMUP + WINDOW:
		frame_ms.append(delta * 1000.0)
		draws_max = maxi(draws_max, last_draws)
		prims_max = maxi(prims_max, last_prims)
		terrain_tris_max = maxi(terrain_tris_max, terrain_sys.last_tris)
		terrain_nodes_max = maxi(terrain_nodes_max, terrain_sys.last_nodes)
		tree_tris_max = maxi(tree_tris_max, trees_sys.last_tris)
		tree_draws_max = maxi(tree_draws_max, trees_sys.last_draws)
		grass_tris_max = maxi(grass_tris_max, grass_sys.last_tris)
		grass_draws_max = maxi(grass_draws_max, grass_sys.last_draws)
	elif t >= WARMUP + WINDOW and not reported:
		reported = true
		_report()


func _report() -> void:
	if frame_ms.is_empty():
		return
	var sorted := frame_ms.duplicate()
	sorted.sort()
	var total := 0.0
	for v in frame_ms:
		total += v
	var avg := total / maxf(1.0, frame_ms.size())
	var p50: float = sorted[int(sorted.size() * 0.5)]
	var p95: float = sorted[int(sorted.size() * 0.95)]
	var size := DisplayServer.window_get_size()
	var line := "BENCH pose=%s size=%dx%d frames=%d avg_fps=%.1f p50_ms=%.1f p95_ms=%.1f max_draws=%d max_tris=%d terrain_tris=%d terrain_nodes=%d trees=%s tree_tris=%d tree_draws=%d grass=%s grass_tris=%d grass_draws=%d" % [
		pose_name, size.x, size.y, frame_ms.size(), 1000.0 / avg, p50, p95, draws_max, prims_max, terrain_tris_max, terrain_nodes_max, "on" if trees_sys.is_on() else "off", tree_tris_max, tree_draws_max, "on" if grass_sys.is_on() else "off", grass_tris_max, grass_draws_max]
	print(line)
	if OS.has_feature("web"):
		JavaScriptBridge.eval("window.__bench = %s;" % JSON.stringify(line))
