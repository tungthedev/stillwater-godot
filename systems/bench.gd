extends Node

# Samples frame times over a fixed window after warmup and prints one BENCH line.
# On Web the line is also put on window.__bench so a driver page can read it.

const WARMUP := 3.0
const WINDOW := 20.0

var t := 0.0
var frame_ms: Array[float] = []
var draws_max := 0
var prims_max := 0
var reported := false
var last_draws := 0
var last_prims := 0


func _process(delta: float) -> void:
	t += delta
	last_draws = RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_DRAW_CALLS_IN_FRAME)
	last_prims = RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_PRIMITIVES_IN_FRAME)
	if t > WARMUP and t < WARMUP + WINDOW:
		frame_ms.append(delta * 1000.0)
		draws_max = maxi(draws_max, last_draws)
		prims_max = maxi(prims_max, last_prims)
	elif t >= WARMUP + WINDOW and not reported:
		reported = true
		_report()


func _report() -> void:
	var sorted := frame_ms.duplicate()
	sorted.sort()
	var total := 0.0
	for v in frame_ms:
		total += v
	var avg := total / maxf(1.0, frame_ms.size())
	var p50: float = sorted[int(sorted.size() * 0.5)]
	var p95: float = sorted[int(sorted.size() * 0.95)]
	var line := "BENCH frames=%d avg_fps=%.1f p50_ms=%.1f p95_ms=%.1f max_draws=%d max_tris=%d" % [
		frame_ms.size(), 1000.0 / avg, p50, p95, draws_max, prims_max]
	print(line)
	if OS.has_feature("web"):
		JavaScriptBridge.eval("window.__bench = %s;" % JSON.stringify(line))
