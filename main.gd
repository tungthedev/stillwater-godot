extends Node

# Wires the systems together. The 3D world lives inside the post chain's scene viewport
# (systems/post.gd), rendered at the internal size; the composite and the UI draw on the screen.
# Each system builds itself in _ready, so add_child order is build order.

const CompactWorld := preload("res://world/compact_world.gd")
const Flags := preload("res://systems/flags.gd")
# Bumped with every behaviour change, so a measurement can prove which build it ran.
const BUILD := "s1-1"


func _ready() -> void:
	# One UI unit = one CSS pixel, so the game's interface uses Stillwater's CSS sizes on any screen.
	get_window().content_scale_factor = Flags.device_pixel_ratio()
	var t0 := Time.get_ticks_msec()
	var world := CompactWorld.new()
	if not world.load_dir("res://data/valley/web"):
		_fatal("world data failed to load (see log)")
		return
	var t_load := Time.get_ticks_msec() - t0
	var env_sys := Node3D.new()
	env_sys.name = "environment"
	env_sys.set_script(load("res://systems/environment.gd"))
	var post := Node.new()
	post.name = "post"
	post.set_script(load("res://systems/post.gd"))
	post.setup(env_sys, Flags.float_targets() and not Flags.has("ldr"))
	add_child(post)
	var scene: SubViewport = post.scene_vp
	scene.add_child(env_sys)
	env_sys.set_sky(world.sky_lut_tex, world.noise_tex)
	var terrain_sys := _add(scene, "terrain", world)
	env_sys.apply_to(terrain_sys.mat)
	var clouds_sys := _add(scene, "clouds", world)
	for m in clouds_sys.materials():
		env_sys.apply_to(m)
	var trees_sys := _add(scene, "trees", world)
	for m in trees_sys.materials():
		env_sys.apply_to(m)
	if Flags.has("notrees") or Flags.has("no-trees"):
		trees_sys.set_on(false)
	var grass_sys := _add(scene, "grass", world)
	for m in grass_sys.materials():
		env_sys.apply_to(m)
	if Flags.has("nograss") or Flags.has("no-grass"):
		grass_sys.set_on(false)
	var cam := Camera3D.new()
	cam.name = "camera"
	cam.set_script(load("res://systems/walk_camera.gd"))
	cam.setup(world)
	scene.add_child(cam)
	# The game is the default page; bench, pose and shot pages keep the fixed camera poses.
	var game := not (Flags.has("bench") or Flags.has("pose") or Flags.has("shot") or Flags.has("bench-shot"))
	var ui := CanvasLayer.new()
	var bench_sys := Node.new()
	bench_sys.name = "bench"
	bench_sys.set_script(load("res://systems/bench.gd"))
	add_child(bench_sys)
	if not game:
		cam.mode_changed.connect(bench_sys.restart)
		bench_sys.restart(cam.mode())
	else:
		bench_sys.reported = true
	ui.name = "ui"
	ui.set_script(load("res://systems/ui.gd"))
	ui.setup({"env": env_sys, "grass": grass_sys, "bench": bench_sys, "cam": cam, "terrain": terrain_sys, "trees": trees_sys, "post": post, "build": BUILD, "game": game})
	bench_sys.setup(terrain_sys, trees_sys, grass_sys, clouds_sys, cam, ui.settings)
	bench_sys.profiled = {"terrain": terrain_sys, "grass": grass_sys, "trees": trees_sys, "camera": cam, "sky": env_sys, "post": post, "ui": ui, "bench": bench_sys}
	add_child(ui)
	if game:
		_add_game(world, scene, cam, bench_sys, ui, env_sys)
	print("BUILD %s game=%s style=%s load_ms=%d scene_ms=%d trees_ms=%d trees=%s grass=%s pose=%s screen=%dx%d internal=%dx%d dpr=%s target=%s post=%s clouds=%d puffs cloud_tris=%d renderer=%s" % [
		BUILD, "on" if game else "off", env_sys.style, t_load, Time.get_ticks_msec() - t0, trees_sys.load_ms, "on" if trees_sys.is_on() else "off", "on" if grass_sys.is_on() else "off", cam.mode(),
		post.screen.x, post.screen.y, post.internal.x, post.internal.y, str(Flags.device_pixel_ratio()), post.target_format(), "on" if post.is_on() else "off",
		clouds_sys.puffs, clouds_sys.tris, Flags.gpu_name()])
	var bench_shot := Flags.value("bench-shot")
	if bench_shot != "":
		bench_sys.finished.connect(func(_r: Dictionary) -> void: _shot(bench_shot), CONNECT_ONE_SHOT)
	var shot := Flags.value("shot")
	if shot != "":
		_shot(shot)


# Input, walker, HUD and session. Created only on the game page, so ?bench and ?pose run exactly
# the systems they ran before.
func _add_game(world: RefCounted, scene: SubViewport, cam: Camera3D, bench_sys: Node, ui: CanvasLayer, env_sys: Node) -> void:
	var input := Node.new()
	input.name = "input"
	input.set_script(load("res://systems/game_input.gd"))
	add_child(input)
	var player := Node.new()
	player.name = "player"
	player.set_script(load("res://systems/player.gd"))
	player.setup(world, input, cam)
	scene.add_child(player)
	var hud := CanvasLayer.new()
	hud.name = "hud"
	hud.set_script(load("res://systems/hud.gd"))
	hud.visible = not (Flags.has("noui") or Flags.has("no-ui"))
	add_child(hud)
	var session := Node.new()
	session.name = "session"
	session.set_script(load("res://systems/session.gd"))
	session.setup({"world": world, "input": input, "player": player, "hud": hud, "cam": cam, "walk_cam": cam,
		"bench": bench_sys, "dev_toggle": ui.toggle_dev, "hours": env_sys.HOURS})
	add_child(session)
	bench_sys.profiled.merge({"player": player, "session": session})
	if Flags.has("walklog"):
		var log := Node.new()
		log.name = "walk_log"
		log.set_script(load("res://systems/walk_log.gd"))
		log.systems = bench_sys.profiled
		log.session = session
		log.player = player
		log.ui = ui
		add_child(log)


# Look checks: `godot --path . -- --pose=forest --no-ui --shot=out.png` saves one frame and quits.
func _shot(path: String) -> void:
	for i in 20:
		await get_tree().process_frame
	await RenderingServer.frame_post_draw
	var err := get_viewport().get_texture().get_image().save_png(path)
	print("SHOT %s %s" % [path, error_string(err)])
	get_tree().quit(0 if err == OK else 1)


func _add(parent: Node, sys_name: String, w: RefCounted = null) -> Node3D:
	var n := Node3D.new()
	n.name = sys_name
	n.set_script(load("res://systems/%s.gd" % sys_name))
	if w != null:
		n.setup(w)
	parent.add_child(n)
	return n


func _fatal(msg: String) -> void:
	push_error(msg)
	var l := Label.new()
	l.text = msg
	l.add_theme_font_size_override("font_size", 32)
	var layer := CanvasLayer.new()
	layer.add_child(l)
	add_child(layer)
