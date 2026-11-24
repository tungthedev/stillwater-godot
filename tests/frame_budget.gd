extends SceneTree

# Whole-frame budget at Stillwater's `low` tier for what the scene draws (terrain + trees + sky)
# at the bench poses on the iPhone's low-tier view (675 x 1130): 1.0 M triangles, 250 draw calls.
# Terrain node selection and tree LOD / frustum counts are CPU-side, so this runs headless; the
# Web measurement (tools/measure_web.mjs) reports what the GPU actually got.
# Run: godot --headless --path . -s tests/frame_budget.gd   (exit code 1 over budget)

const CompactWorld := preload("res://world/compact_world.gd")
const TRIS := 1000000
const DRAWS := 250
const VIEW := Vector2i(675, 1130)
# Sky dome.
const OTHER_DRAWS := 1


func _init() -> void:
	var world := CompactWorld.new()
	if not world.load_dir():
		quit(1)
		return
	var vp := SubViewport.new()
	vp.size = VIEW
	root.add_child(vp)
	var terrain := Node3D.new()
	terrain.set_script(load("res://systems/terrain.gd"))
	terrain.setup(world)
	vp.add_child(terrain)
	var trees := Node3D.new()
	trees.set_script(load("res://systems/trees.gd"))
	trees.setup(world)
	vp.add_child(trees)
	var cam := Camera3D.new()
	vp.add_child(cam)
	await process_frame
	cam.fov = float(world.meta.poses.fovVerticalDeg)
	cam.near = float(world.meta.poses.near)
	cam.far = float(world.meta.poses.far)
	cam.keep_aspect = Camera3D.KEEP_HEIGHT
	var ok := true
	for stop in ["trailhead", "forest"]:
		var s: Dictionary = world.pose(stop)
		cam.position = Vector3(s.position[0], s.position[1], s.position[2])
		cam.rotation = Vector3(float(s.pitch), float(s.yaw), 0.0)
		var nodes: int = terrain.select(cam)
		trees.update_lod(cam.position, true)
		trees.count_drawn(cam)
		var tris: int = nodes * terrain.tris_per_node + trees.last_tris
		var draws: int = 1 + trees.last_draws + OTHER_DRAWS
		var pass_: bool = tris <= TRIS and draws <= DRAWS and trees.last_tris > 0
		ok = ok and pass_
		print("budget %s: terrain %d + trees %d = %d triangles, %d draws (trees %d; hero %d, mid %d, impostor %d trees) %s" % [
			stop, nodes * terrain.tris_per_node, trees.last_tris, tris, draws, trees.last_draws,
			trees.stats.hero, trees.stats.mid, trees.stats.impostor, "ok" if pass_ else "OVER"])
	print("FRAME_BUDGET %s (budget %d triangles, %d draws)" % ["PASS" if ok else "FAIL", TRIS, DRAWS])
	quit(0 if ok else 1)
