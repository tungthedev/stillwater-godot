extends SceneTree

# Whole-frame budget at Stillwater's `low` tier for what the scene draws (terrain + trees + grass
# and flowers + clouds + sky + the post passes) at the bench poses, on the slice 2-4 view
# (675 x 1130) and the iPhone's real low-tier internal size (1170 x 2532 at 0.6 capped to 0.9 MP = 644 x 1393):
# 1.0 M triangles, 250 draw calls.
# Terrain node selection, tree LOD / frustum counts and grass tile rings are CPU-side, so this runs
# headless (grass tiles count as baked; the bake itself needs a GPU); the
# Web measurement (tools/measure_web.mjs) reports what the GPU actually got.
# Run: godot --headless --path . -s tests/frame_budget.gd   (exit code 1 over budget)

const CompactWorld := preload("res://world/compact_world.gd")
const TRIS := 1000000
const DRAWS := 250
const Post := preload("res://systems/post.gd")
const VIEWS: Array[Vector2i] = [Vector2i(675, 1130)]
# Sky dome, 5 bloom passes, the composite.
const OTHER_DRAWS := 7
const OTHER_TRIS := 12


func _init() -> void:
	var world := CompactWorld.new()
	if not world.load_dir():
		quit(1)
		return
	var phone := Post.internal_size(1170, 2532, Post.cap_scale(1170, 2532, Post.TIER_SCALE, Post.TIER_MAX_PIXELS))
	var views := VIEWS.duplicate()
	views.append(phone)
	var vp := SubViewport.new()
	vp.size = views[0]
	root.add_child(vp)
	var terrain := Node3D.new()
	terrain.set_script(load("res://systems/terrain.gd"))
	terrain.setup(world)
	vp.add_child(terrain)
	var water := Node3D.new()
	water.set_script(load("res://systems/water.gd"))
	water.setup(world)
	vp.add_child(water)
	var props := Node3D.new()
	props.set_script(load("res://systems/props.gd"))
	props.setup(world)
	vp.add_child(props)
	var trees := Node3D.new()
	trees.set_script(load("res://systems/trees.gd"))
	trees.setup(world)
	vp.add_child(trees)
	var grass := Node3D.new()
	grass.set_script(load("res://systems/grass.gd"))
	grass.setup(world)
	vp.add_child(grass)
	grass.set_process(false)
	var clouds := Node3D.new()
	clouds.set_script(load("res://systems/clouds.gd"))
	clouds.setup(world)
	vp.add_child(clouds)
	var cam := Camera3D.new()
	vp.add_child(cam)
	await process_frame
	cam.fov = float(world.meta.poses.fovVerticalDeg)
	cam.near = float(world.meta.poses.near)
	cam.far = float(world.meta.poses.far)
	cam.keep_aspect = Camera3D.KEEP_HEIGHT
	var ok := phone == Vector2i(644, 1393)
	print("phone internal size %s (capScaleForPixels gives 644 x 1393, %d px <= 900000)" % [phone, phone.x * phone.y])
	for view in views:
		vp.size = view
		await process_frame
		for stop in ["trailhead", "forest", "lake", "cottage"]:
			var s: Dictionary = world.pose(stop)
			cam.position = Vector3(s.position[0], s.position[1], s.position[2])
			cam.rotation = Vector3(float(s.pitch), float(s.yaw), 0.0)
			var nodes: int = terrain.select(cam)
			trees.update_lod(cam.position, true)
			trees.count_drawn(cam)
			props.update_cull(cam, true)
			props.count_drawn(cam)
			grass.update_rings(cam, true)
			var tris: int = nodes * terrain.tris_per_node + water.last_tris + props.last_tris + trees.last_tris + grass.last_tris + clouds.tris + OTHER_TRIS
			var draws: int = terrain.last_draws + water.last_draws + props.last_draws + trees.last_draws + grass.last_draws + clouds.last_draws + OTHER_DRAWS
			var props_ok: bool = props.last_draws <= 8 and (props.last_tris > 0 if stop != "forest" else true)
			var pass_: bool = tris <= TRIS and draws <= DRAWS and water.last_draws <= 3 and water.last_tris > 0 and props_ok and trees.last_tris > 0 and grass.grass.last_tris > 0 and grass.flowers.last_tris > 0
			ok = ok and pass_
			print("budget %s %dx%d: terrain %d + water %d (%d draws) + props %d (%d draws) + trees %d + grass %d + clouds %d = %d triangles, %d draws (trees %d, grass %d; hero %d, mid %d, impostor %d trees; grass tiles %d near + %d far, flower tiles %d) %s" % [
				stop, view.x, view.y, nodes * terrain.tris_per_node, water.last_tris, water.last_draws, props.last_tris, props.last_draws, trees.last_tris, grass.last_tris, clouds.tris, tris, draws, trees.last_draws, grass.last_draws,
				trees.stats.hero, trees.stats.mid, trees.stats.impostor, grass.grass.near_vis, grass.grass.far_vis, grass.flowers.near_vis, "ok" if pass_ else "OVER"])
	print("FRAME_BUDGET %s (budget %d triangles, %d draws)" % ["PASS" if ok else "FAIL", TRIS, DRAWS])
	quit(0 if ok else 1)
