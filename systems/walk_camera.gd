extends Camera3D

# Walks a fixed circle so every run sees the same frames.

const WATER_Y := -6.0
const PATH_R := 150.0
const SPEED := 3.0

var ground: RefCounted
var t := 0.0


func setup(g: RefCounted) -> void:
	ground = g


func _ready() -> void:
	far = 1500.0
	fov = 70.0


func _process(delta: float) -> void:
	t += delta
	var a := t * SPEED / PATH_R
	var p := Vector3(cos(a) * PATH_R, 0.0, sin(a) * PATH_R)
	p.y = maxf(ground.height_at(p.x, p.z), WATER_Y) + 1.7
	var ahead := Vector3(cos(a + 0.05) * PATH_R, 0.0, sin(a + 0.05) * PATH_R)
	ahead.y = p.y - 0.4
	look_at_from_position(p, ahead, Vector3.UP)
