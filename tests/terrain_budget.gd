extends SceneTree

# Terrain triangle budget at the bench poses on the iPhone's low-tier view (675 x 1130).
# Node selection is CPU-only, so this runs headless.
# Run: godot --headless --path . -s tests/terrain_budget.gd   (exit code 1 over budget)

const CompactWorld := preload("res://world/compact_world.gd")
const BUDGET := 350000
const VIEW := Vector2i(675, 1130)


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
	var cam := Camera3D.new()
	vp.add_child(cam)
	# Children get _ready (the terrain builds its mesh there) once the main loop runs.
	await process_frame
	cam.fov = float(world.meta.poses.fovVerticalDeg)
	cam.near = float(world.meta.poses.near)
	cam.far = float(world.meta.poses.far)
	var worst := 0
	for stop in ["trailhead", "forest"]:
		var s: Dictionary = world.pose(stop)
		cam.position = Vector3(s.position[0], s.position[1], s.position[2])
		cam.rotation = Vector3(float(s.pitch), float(s.yaw), 0.0)
		var nodes: int = terrain.select(cam)
		var tris: int = nodes * terrain.tris_per_node
		worst = maxi(worst, tris)
		if nodes == 0:
			worst = BUDGET + 1
		print("budget %s: %d nodes x %d tris = %d terrain triangles (%s)" % [
			stop, nodes, terrain.tris_per_node, tris, "ok" if tris <= BUDGET else "OVER"])
	print("TERRAIN_BUDGET %s (worst %d, budget %d)" % ["PASS" if worst <= BUDGET else "FAIL", worst, BUDGET])
	quit(0 if worst <= BUDGET else 1)
