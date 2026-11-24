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
	var env_sys := Node3D.new()
	env_sys.set_script(load("res://systems/environment.gd"))
	vp.add_child(env_sys)
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
	var undergrowth := Node3D.new()
	undergrowth.set_script(load("res://systems/undergrowth.gd"))
	undergrowth.setup(world)
	vp.add_child(undergrowth)
	var trees := Node3D.new()
	trees.set_script(load("res://systems/trees.gd"))
	trees.setup(world)
	vp.add_child(trees)
	var grass := Node3D.new()
	grass.set_script(load("res://systems/grass.gd"))
	grass.setup(world)
	vp.add_child(grass)
	grass.set_process(false)
	var air := Node3D.new()
	air.set_script(load("res://systems/air.gd"))
	air.setup(world)
	vp.add_child(air)
	var fauna := Node3D.new()
	fauna.set_script(load("res://systems/fauna.gd"))
	fauna.setup(world)
	vp.add_child(fauna)
	env_sys.add_tod_listener(func(e: Node) -> void: props.set_night_glow(e.night_glow))
	env_sys.add_tod_listener(fauna.apply_tod)
	var clouds := Node3D.new()
	clouds.set_script(load("res://systems/clouds.gd"))
	clouds.setup(world)
	vp.add_child(clouds)
	var cam := Camera3D.new()
	vp.add_child(cam)
	await process_frame
	env_sys.set_sky(world.sky_lut_tex, world.noise_tex)
	cam.fov = float(world.meta.poses.fovVerticalDeg)
	cam.near = float(world.meta.poses.near)
	cam.far = float(world.meta.poses.far)
	cam.keep_aspect = Camera3D.KEEP_HEIGHT
	var ok := phone == Vector2i(644, 1393)
	print("phone internal size %s (capScaleForPixels gives 644 x 1393, %d px <= 900000)" % [phone, phone.x * phone.y])
	for view in views:
		vp.size = view
		await process_frame
		var checks: Array[Array] = [
			["trailhead", "noon"], ["forest", "noon"], ["lake", "noon"], ["cottage", "noon"],
		]
		if view == phone and grass.is_painted():
			checks.append(["waterfall", "noon"])
			checks.append(["sheep", "noon"])
			checks.append(["trailhead", "night"])
			checks.append(["cottage", "night"])
		for item in checks:
			var stop: String = item[0]
			var tod: String = item[1]
			env_sys.set_tod(tod)
			var s: Dictionary = world.pose(stop)
			cam.position = Vector3(s.position[0], s.position[1], s.position[2])
			cam.rotation = Vector3(float(s.pitch), float(s.yaw), 0.0)
			var nodes: int = terrain.select(cam)
			trees.update_lod(cam.position, true)
			trees.count_drawn(cam)
			props.update_cull(cam, true)
			props.count_drawn(cam)
			undergrowth.update_cull(cam, true)
			undergrowth.count_drawn(cam)
			air.update_cull(cam, true)
			air.count_drawn(cam)
			fauna.update_cull(cam, true)
			fauna.count_drawn(cam)
			grass.update_rings(cam, true)
			var tris: int = nodes * terrain.tris_per_node + water.last_tris + props.last_tris + undergrowth.last_tris + air.last_tris + fauna.last_tris + trees.last_tris + grass.last_tris + clouds.tris + OTHER_TRIS
			var draws: int = terrain.last_draws + water.last_draws + props.last_draws + undergrowth.last_draws + air.last_draws + fauna.last_draws + trees.last_draws + grass.last_draws + clouds.last_draws + OTHER_DRAWS
			var props_lim := 10 if tod == "night" else 8
			var props_ok: bool = props.last_draws <= props_lim and (props.last_tris > 0 if (stop != "forest" and stop != "waterfall" and stop != "sheep") else true)
			var w4_draws: int = undergrowth.last_draws + air.last_draws
			var w4_ok: bool = w4_draws <= 6 and (undergrowth.last_tris > 0 if stop == "forest" else true) and air.last_tris > 0
			var w5_ok: bool = fauna.last_draws <= 4 and (fauna.last_tris > 0 if (stop == "sheep" or tod == "night") else true)
			var pass_: bool = tris <= TRIS and draws <= DRAWS and water.last_draws <= 3 and water.last_tris > 0 and props_ok and w4_ok and w5_ok and trees.last_tris > 0 and grass.grass.last_tris > 0 and grass.flowers.last_tris > 0
			ok = ok and pass_
			print("budget %s(%s) %dx%d: terrain %d + water %d (%d draws) + props %d (%d draws) + undergrowth %d (%d draws) + air %d (%d draws) + fauna %d (%d draws) + trees %d + grass %d + clouds %d = %d triangles, %d draws (w4 %d, w5 %d; trees %d, grass %d) %s" % [
				stop, tod, view.x, view.y, nodes * terrain.tris_per_node, water.last_tris, water.last_draws, props.last_tris, props.last_draws, undergrowth.last_tris, undergrowth.last_draws, air.last_tris, air.last_draws, fauna.last_tris, fauna.last_draws, trees.last_tris, grass.last_tris, clouds.tris, tris, draws, w4_draws, fauna.last_draws, trees.last_draws, grass.last_draws, "ok" if pass_ else "OVER"])
	print("FRAME_BUDGET %s (budget %d triangles, %d draws)" % ["PASS" if ok else "FAIL", TRIS, DRAWS])
	quit(0 if ok else 1)
