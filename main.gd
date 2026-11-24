extends Node3D

# Wires the systems together. Each system builds itself in _ready, so add_child order is build order.
# The test trees and test water are not added: they would cover the real terrain, and the real
# ones come in later slices.

const CompactWorld := preload("res://world/compact_world.gd")


func _ready() -> void:
	var t0 := Time.get_ticks_msec()
	var world := CompactWorld.new()
	if not world.load_dir("res://data/valley/web"):
		_fatal("world data failed to load (see log)")
		return
	var t_load := Time.get_ticks_msec() - t0
	var env_sys := _add("environment")
	env_sys.set_sky_lut(world.sky_lut_tex)
	var terrain_sys := _add("terrain", world)
	env_sys.apply_to(terrain_sys.mat)
	var grass_sys := _add("grass", world)
	if OS.get_cmdline_user_args().has("--no-grass"):
		grass_sys.set_on(false)
	var bench_sys := Node.new()
	bench_sys.name = "bench"
	bench_sys.set_script(load("res://systems/bench.gd"))
	bench_sys.setup(terrain_sys)
	add_child(bench_sys)
	var cam := Camera3D.new()
	cam.name = "camera"
	cam.set_script(load("res://systems/walk_camera.gd"))
	cam.setup(world)
	cam.mode_changed.connect(bench_sys.restart)
	add_child(cam)
	bench_sys.restart(cam.mode())
	var ui := CanvasLayer.new()
	ui.name = "ui"
	ui.set_script(load("res://systems/ui.gd"))
	ui.setup(env_sys, grass_sys, bench_sys, cam, terrain_sys)
	add_child(ui)
	print("BUILD load_ms=%d scene_ms=%d pose=%s" % [t_load, Time.get_ticks_msec() - t0, cam.mode()])
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--shot="):
			_shot(a.substr(7))


# Look checks: `godot --path . -- --pose=forest --no-ui --shot=out.png` saves one frame and quits.
func _shot(path: String) -> void:
	for i in 20:
		await get_tree().process_frame
	await RenderingServer.frame_post_draw
	var err := get_viewport().get_texture().get_image().save_png(path)
	print("SHOT %s %s" % [path, error_string(err)])
	get_tree().quit(0 if err == OK else 1)


func _add(sys_name: String, w: RefCounted = null) -> Node3D:
	var n := Node3D.new()
	n.name = sys_name
	n.set_script(load("res://systems/%s.gd" % sys_name))
	if w != null:
		n.setup(w)
	add_child(n)
	return n


func _fatal(msg: String) -> void:
	push_error(msg)
	var l := Label.new()
	l.text = msg
	l.add_theme_font_size_override("font_size", 32)
	var layer := CanvasLayer.new()
	layer.add_child(l)
	add_child(layer)
