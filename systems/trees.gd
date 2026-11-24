extends Node3D

const SIZE := 1024.0
const WATER_Y := -6.0
const TREE_COUNT := 20000
const TREE_TILE := 128.0
const TREE_NEAR := 160.0
const TREE_FAR := 600.0

var ground: RefCounted


func setup(g: RefCounted) -> void:
	ground = g


func _tree_mesh(segments: int, rings: int) -> CylinderMesh:
	var cone := CylinderMesh.new()
	cone.top_radius = 0.0
	cone.bottom_radius = 2.4
	cone.height = 10.0
	cone.radial_segments = segments
	cone.rings = rings
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.13, 0.26, 0.12)
	mat.roughness = 0.9
	cone.material = mat
	return cone


func _ready() -> void:
	var near_mesh := _tree_mesh(10, 2)
	var far_mesh := _tree_mesh(5, 0)
	var rng := RandomNumberGenerator.new()
	rng.seed = 23
	var tiles := int(SIZE / TREE_TILE)
	var per_tile := TREE_COUNT / (tiles * tiles)
	for tj in tiles:
		for ti in tiles:
			var x0 := -SIZE * 0.5 + ti * TREE_TILE
			var z0 := -SIZE * 0.5 + tj * TREE_TILE
			var xforms: Array[Transform3D] = []
			for k in per_tile:
				var x := x0 + rng.randf() * TREE_TILE
				var z := z0 + rng.randf() * TREE_TILE
				var y: float = ground.height_at(x, z)
				if y < WATER_Y + 2.0:
					continue
				var s := rng.randf_range(0.7, 1.5)
				var basis := Basis(Vector3.UP, rng.randf() * TAU).scaled(Vector3(s, s, s))
				xforms.append(Transform3D(basis, Vector3(x, y + 5.0 * s, z)))
			_add_layer(near_mesh, xforms, 0.0, TREE_NEAR, true)
			_add_layer(far_mesh, xforms, TREE_NEAR, TREE_FAR, false)


func _add_layer(mesh: Mesh, xforms: Array[Transform3D], begin: float, end: float, shadows: bool) -> void:
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.mesh = mesh
	mm.instance_count = xforms.size()
	for k in xforms.size():
		mm.set_instance_transform(k, xforms[k])
	var mmi := MultiMeshInstance3D.new()
	mmi.multimesh = mm
	mmi.visibility_range_begin = begin
	mmi.visibility_range_end = end
	mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON if shadows else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(mmi)
