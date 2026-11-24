extends Node3D

const WATER_Y := -6.0
const GRASS_AREA := 384.0
const GRASS_CHUNK := 32.0
const GRASS_PER_CHUNK := 2500
const GRASS_RANGE := 70.0

var ground: RefCounted
var chunks: Array[MultiMeshInstance3D] = []


func setup(g: RefCounted) -> void:
	ground = g


func is_on() -> bool:
	return chunks[0].visible


func set_on(on: bool) -> void:
	for c in chunks:
		c.visible = on


func _blade_mesh() -> ArrayMesh:
	var w := 0.05
	var verts := PackedVector3Array([
		Vector3(-w, 0, 0), Vector3(w, 0, 0),
		Vector3(-w * 0.6, 0.35, 0), Vector3(w * 0.6, 0.35, 0),
		Vector3(0, 0.7, 0)])
	var idx := PackedInt32Array([0, 2, 1, 1, 2, 3, 2, 4, 3])
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_INDEX] = idx
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	var mat := ShaderMaterial.new()
	mat.shader = load("res://grass.gdshader")
	mesh.surface_set_material(0, mat)
	return mesh


func _ready() -> void:
	var blade := _blade_mesh()
	var rng := RandomNumberGenerator.new()
	rng.seed = 11
	var n := int(GRASS_AREA / GRASS_CHUNK)
	for cj in n:
		for ci in n:
			var x0 := -GRASS_AREA * 0.5 + ci * GRASS_CHUNK
			var z0 := -GRASS_AREA * 0.5 + cj * GRASS_CHUNK
			var mm := MultiMesh.new()
			mm.transform_format = MultiMesh.TRANSFORM_3D
			mm.mesh = blade
			mm.instance_count = GRASS_PER_CHUNK
			var used := 0
			for k in GRASS_PER_CHUNK:
				var x := x0 + rng.randf() * GRASS_CHUNK
				var z := z0 + rng.randf() * GRASS_CHUNK
				var y: float = ground.height_at(x, z)
				if y < WATER_Y + 1.0:
					continue
				var s := rng.randf_range(0.7, 1.4)
				var basis := Basis(Vector3.UP, rng.randf() * TAU).scaled(Vector3(s, s, s))
				mm.set_instance_transform(used, Transform3D(basis, Vector3(x, y, z)))
				used += 1
			mm.visible_instance_count = used
			var mmi := MultiMeshInstance3D.new()
			mmi.multimesh = mm
			mmi.visibility_range_end = GRASS_RANGE
			mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			add_child(mmi)
			chunks.append(mmi)
