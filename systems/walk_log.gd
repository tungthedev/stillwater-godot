extends Node

# ?walklog (tools/free_walk_check.mjs): per-frame script time of every system while the game is
# in play, so a walk can fail on streaming hitches. Frame gaps are too noisy for that with vsync
# off; each system's own _process time is not. Twice a second the summary goes to
# window.__walk (Web) or a WALK line (desktop).

var systems := {}
var session: Node
var player: Node
var ui: Node
var frames := 0
var t := 0.0
var sum_frame := 0.0
var max_frame := 0.0
var worst := {}
var over := {}
var limit_us := 5000
var sums := {}
# The slowest frames: gap, what each system spent in the frame before it (its render is in the gap).
var hitches: Array = []
var _prev := {}
# Frames that a check's own screenshot stalled (the page marks the capture window).
var shot_frames := 0
var stall_frames := 0
# Over-limit frames: system, its script ms and how much of it was its GPU buffer upload.
var spikes: Array = []
const IDLE: Array[String] = ["camera", "bench", "ui"]
var _next := 0.5


func _ready() -> void:
	process_priority = (1 << 30) - 1


func _process(delta: float) -> void:
	_publish_ui(delta)
	if session.mode != "play" or session.paused or session.fade < 0.95:
		return
	frames += 1
	t += delta
	sum_frame += delta
	if delta > 0.05 and frames > 1 and _in_shot():
		shot_frames += 1
	else:
		max_frame = maxf(max_frame, delta)
		if delta > 0.05 and frames > 1:
			hitches.append({"t": snappedf(t, 0.01), "ms": snappedf(delta * 1000.0, 0.1), "prev_ms": _ms(_prev), "pos": [roundi(player.pos.x), roundi(player.pos.y)]})
			hitches.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return a.ms > b.ms)
			hitches.resize(mini(hitches.size(), 6))
	# Systems that do no work this frame: time in them means the browser held the page (another
	# tab, a capture, the GPU queue), and that frame's script times say nothing about our work.
	var idle_us := 0
	for k in IDLE:
		if systems.has(k):
			idle_us += systems[k].prof_us
	var stalled := idle_us > 1000
	if stalled:
		stall_frames += 1
	var cur := {}
	for k in systems:
		var us: int = systems[k].prof_us
		cur[k] = us
		sums[k] = sums.get(k, 0) + us
		if us > limit_us:
			if stalled or _in_shot():
				shot_frames += 1
			else:
				over[k] = over.get(k, 0) + 1
				var push = systems[k].get("push_us")
				var det = systems[k].get("detail")
				spikes.append({"sys": k, "ms": snappedf(us / 1000.0, 0.01), "upload_ms": snappedf((push if push != null else 0) / 1000.0, 0.01), "t": snappedf(t, 0.01), "detail": det if det != null else {}})
				if us > worst.get(k, 0):
					worst[k] = us
			continue
		if us > worst.get(k, 0):
			worst[k] = us
	_prev = cur
	if t >= _next:
		_next = t + 0.5
		var s := {
			"frames": frames, "seconds": snappedf(t, 0.01), "fps": snappedf(frames / maxf(t, 1e-3), 0.1),
			"max_frame_ms": snappedf(max_frame * 1000.0, 0.1), "worst_ms": _ms(worst), "over_5ms": over, "avg_ms": _avg(), "hitches": hitches, "shot_frames": shot_frames, "stall_frames": stall_frames, "spikes": spikes.slice(0, 10),
			"tree_build_max_ms": snappedf(systems.trees.build_max_us / 1000.0, 0.01),
			"pos": [snappedf(player.pos.x, 0.1), snappedf(player.pos.y, 0.1)], "distance": snappedf(player.distance, 0.1),
			"auto_walk": player.auto_walk, "trail_idx": player.trail_idx,
			"edge": snappedf(maxf(absf(player.pos.x), absf(player.pos.y)), 0.01),
			# Where the Trail button is, in CSS pixels, so a check can tap it.
			"trail_btn": _rect(session.hud.btn.autoWalk),
		}
		var line := JSON.stringify(s)
		if OS.has_feature("web"):
			JavaScriptBridge.eval("window.__walk = %s;" % line)
		else:
			print("WALK " + line)


# State and control rects in every mode (title, pause, bench), so a check can tap the pause
# sheet, the perf levers and Bench, and see what they did.
var _ui_t := 0.0
func _publish_ui(delta: float) -> void:
	_ui_t -= delta
	if _ui_t > 0.0 or not OS.has_feature("web"):
		return
	_ui_t = 0.25
	var h: CanvasLayer = session.hud
	var s := {
		"mode": session.mode, "paused": session.paused, "fade": snappedf(session.fade, 0.01),
		"distance": snappedf(player.distance, 0.01), "yaw": snappedf(player.yaw, 0.001),
		"auto_walk": player.auto_walk, "sitting": not player.sitting.is_empty(), "sit_text": h.btn.sit.text,
		"stick_active": session.input.has_stick(), "stick_alpha": snappedf(h.stick.modulate.a, 0.01),
		"stick_pos": [snappedf(h.stick.position.x, 0.5), snappedf(h.stick.position.y, 0.5)],
		"dev_on": ui.dev_on, "dev_grid": ui.grid.is_visible_in_tree(), "bench_running": ui.bench_sys.running,
		"bench_done": ui.panel.visible, "grass_on": ui.grass_sys.is_on(), "hud_visible": h.visible,
		"safe": [h.safe.x, h.safe.y, h.safe.z, h.safe.w],
		"pause_btn": _rect(h.pause_btn), "perf_btn": _rect(h.dev_btn), "resume_btn": _rect(h.resume_btn),
		"trail_btn": _rect(h.btn.autoWalk), "sit_btn": _rect(h.btn.sit), "compass": _rect(h.compass) if h.get("compass") is Control else [],
		"lever_grass": _rect(ui.btn.grass), "lever_bench": _rect(ui.btn.bench), "panel_close": _rect(ui.btn.panel_close),
	}
	JavaScriptBridge.eval("window.__ui = %s;" % JSON.stringify(s))


static func _rect(c: Control) -> Array:
	var r := c.get_global_rect()
	return [r.position.x, r.position.y, r.size.x, r.size.y] if c.is_visible_in_tree() else []


func _in_shot() -> bool:
	if not OS.has_feature("web"):
		return false
	return bool(JavaScriptBridge.eval("!!window.__shooting || performance.now() - (window.__shotEnd || -1e9) < 400"))


func _avg() -> Dictionary:
	var o := {}
	for k in sums:
		o[k] = snappedf(sums[k] / 1000.0 / maxf(frames, 1), 0.001)
	return o


static func _ms(d: Dictionary) -> Dictionary:
	var o := {}
	for k in d:
		o[k] = snappedf(d[k] / 1000.0, 0.01)
	return o
