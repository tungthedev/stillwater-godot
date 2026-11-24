extends Node3D

const SIZE := 1024.0
const WATER_Y := -6.0


func _ready() -> void:
	var plane := PlaneMesh.new()
	plane.size = Vector2(SIZE, SIZE)
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.16, 0.32, 0.4, 0.82)
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.roughness = 0.08
	mat.metallic = 0.3
	plane.material = mat
	var mi := MeshInstance3D.new()
	mi.mesh = plane
	mi.position.y = WATER_Y
	add_child(mi)
