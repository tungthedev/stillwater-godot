extends Node

# Samples frame times over a fixed window after warmup and prints one BENCH line per pose.
# On Web the line is also put on window.__bench so a driver page can read it. A pose change
# restarts the window, so a driver can pick the pose with ?pose= and just wait.

const WARMUP := 3.0
const WINDOW := 20.0

var terrain_sys: Node
var trees_sys: Node
var pose_name := ""
var t := 0.0
var frame_ms: Array[float] = []
var draws_max := 0
var prims_max := 0
var terrain_tris_max := 0
var terrain_nodes_max := 0
var tree_tris_max := 0
var tree_draws_max := 0
var reported := false
var last_draws := 0
var last_prims := 0


func setup(terrain_node: Node, trees_node: Node) -> void:
	terrain_sys = terrain_node
	trees_sys = trees_node


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
	reported = false


func _process(delta: float) -> void:
	t += delta
	last_draws = RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_DRAW_CALLS_IN_FRAME)
	last_prims = RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_PRIMITIVES_IN_FRAME)
	if t > WARMUP and t < WARMUP + WINDOW:
		frame_ms.append(delta * 1000.0)
		draws_max = maxi(draws_max, last_draws)
		prims_max = maxi(prims_max, last_prims)
		terrain_tris_max = maxi(terrain_tris_max, terrain_sys.last_tris)
		terrain_nodes_max = maxi(terrain_nodes_max, terrain_sys.last_nodes)
		tree_tris_max = maxi(tree_tris_max, trees_sys.last_tris)
		tree_draws_max = maxi(tree_draws_max, trees_sys.last_draws)
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
	var size := DisplayServer.window_get_size()
	var line := "BENCH pose=%s size=%dx%d frames=%d avg_fps=%.1f p50_ms=%.1f p95_ms=%.1f max_draws=%d max_tris=%d terrain_tris=%d terrain_nodes=%d trees=%s tree_tris=%d tree_draws=%d" % [
		pose_name, size.x, size.y, frame_ms.size(), 1000.0 / avg, p50, p95, draws_max, prims_max, terrain_tris_max, terrain_nodes_max, "on" if trees_sys.is_on() else "off", tree_tris_max, tree_draws_max]
	print(line)
	if OS.has_feature("web"):
		JavaScriptBridge.eval("window.__bench = %s;" % JSON.stringify(line))
