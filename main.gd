extends Node3D

# Wires the systems together. Each system builds itself in _ready, so add_child order is build order.

const Ground := preload("res://systems/test_ground.gd")


func _ready() -> void:
	var t0 := Time.get_ticks_msec()
	var ground := Ground.new()
	var env_sys := _add("environment")
	_add("terrain", ground)
	_add("water")
	var grass_sys := _add("grass", ground)
	_add("trees", ground)
	var bench_sys := Node.new()
	bench_sys.name = "bench"
	bench_sys.set_script(load("res://systems/bench.gd"))
	add_child(bench_sys)
	var ui := CanvasLayer.new()
	ui.name = "ui"
	ui.set_script(load("res://systems/ui.gd"))
	ui.setup(env_sys, grass_sys, bench_sys)
	add_child(ui)
	var cam := Camera3D.new()
	cam.name = "camera"
	cam.set_script(load("res://systems/walk_camera.gd"))
	cam.setup(ground)
	add_child(cam)
	print("BUILD scene_ms=%d" % (Time.get_ticks_msec() - t0))


func _add(sys_name: String, ground: RefCounted = null) -> Node3D:
	var n := Node3D.new()
	n.name = sys_name
	n.set_script(load("res://systems/%s.gd" % sys_name))
	if ground != null:
		n.setup(ground)
	add_child(n)
	return n
