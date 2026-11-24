extends Node3D

const SIZE := 1024.0
const RES := 256
const WATER_Y := -6.0

var ground: RefCounted


func setup(g: RefCounted) -> void:
	ground = g


func _ready() -> void:
	var n := RES + 1
	var step := SIZE / RES
	var verts := PackedVector3Array()
	var norms := PackedVector3Array()
	var cols := PackedColorArray()
	verts.resize(n * n)
	norms.resize(n * n)
	cols.resize(n * n)
	for j in n:
		for i in n:
			var x := -SIZE * 0.5 + i * step
			var z := -SIZE * 0.5 + j * step
			var y: float = ground.height_at(x, z)
			var nx: float = ground.height_at(x - step, z) - ground.height_at(x + step, z)
			var nz: float = ground.height_at(x, z - step) - ground.height_at(x, z + step)
			var nrm := Vector3(nx, 2.0 * step, nz).normalized()
			var k := j * n + i
			verts[k] = Vector3(x, y, z)
			norms[k] = nrm
			var grass := Color(0.24, 0.38, 0.13)
			var rock := Color(0.45, 0.42, 0.38)
			var shore := Color(0.55, 0.5, 0.38)
			var c := grass.lerp(rock, clampf((1.0 - nrm.y) * 4.0, 0.0, 1.0))
			if y < WATER_Y + 1.5:
				c = shore
			cols[k] = c
	var idx := PackedInt32Array()
	idx.resize(RES * RES * 6)
	var w := 0
	for j in RES:
		for i in RES:
			var a := j * n + i
			idx[w] = a; idx[w + 1] = a + 1; idx[w + 2] = a + n
			idx[w + 3] = a + 1; idx[w + 4] = a + n + 1; idx[w + 5] = a + n
			w += 6
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = norms
	arrays[Mesh.ARRAY_COLOR] = cols
	arrays[Mesh.ARRAY_INDEX] = idx
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	var mat := StandardMaterial3D.new()
	mat.vertex_color_use_as_albedo = true
	mat.roughness = 0.95
	mesh.surface_set_material(0, mat)
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	add_child(mi)
