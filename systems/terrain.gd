extends Node3D

# Stillwater's quadtree terrain: every frame the CPU walks a quadtree over the 32 km far map,
# keeps the nodes in the camera frustum, splits a node while the camera is closer than
# LOD_K * size, and draws one N x N grid patch per kept node in a single instanced draw.
# The vertex shader places, morphs (CDLOD) and lifts each vertex (shaders/terrain.gdshader).
#
# Budget: Stillwater `low` allows 0.35 M terrain triangles. Stillwater itself uses N = 32,
# LOD_K = 3.6 and double-sided skirts (2560 triangles a node), about 0.37-0.44 M at the bench
# poses on a phone-shaped view. Here the skirt is one-sided (faces outward, which is the side a
# crack shows) and LOD_K is 3.0, keeping 2 m vertex spacing near the camera.

const ROOT := 32768.0
const MIN_SIZE := 64.0
const N := 32
const LOD_K := 3.0
const MAX_NODES := 1024
const BOX_MIN_Y := -200.0
const BOX_MAX_Y := 4400.0
const SKIRT := true

var world: RefCounted
var mat: ShaderMaterial
var mm: MultiMesh
var mmi: MultiMeshInstance3D
var buf := PackedFloat32Array()
var tris_per_node := 0
var last_nodes := 0
var last_tris := 0
var _planes: Array[Plane] = []
var _cam_pos := Vector3.ZERO
var _dy := 0.0
var _count := 0


func setup(w: RefCounted) -> void:
	world = w


func _ready() -> void:
	# After the camera has moved this frame.
	process_priority = 100
	mat = ShaderMaterial.new()
	mat.shader = load("res://shaders/terrain.gdshader")
	mat.set_shader_parameter("near_tex", ImageTexture.create_from_image(world.near_img))
	mat.set_shader_parameter("far_tex", ImageTexture.create_from_image(world.far_img))
	mat.set_shader_parameter("biome_tex", ImageTexture.create_from_image(world.biome_img))
	mat.set_shader_parameter("noise_tex", world.noise_tex)
	mat.set_shader_parameter("sky_lut", world.sky_lut_tex)
	mat.set_shader_parameter("near_size", world.near_size)
	mat.set_shader_parameter("near_min", world.near_min)
	mat.set_shader_parameter("near_step", world.near_step)
	mat.set_shader_parameter("far_size", world.far_size)
	mat.set_shader_parameter("far_min", world.far_min)
	mat.set_shader_parameter("far_step", world.far_step)
	mat.set_shader_parameter("water_level", world.water_level)
	mat.set_shader_parameter("grid_n", float(N))
	mat.set_shader_parameter("lod_k", LOD_K)
	mat.set_shader_parameter("skirt_on", 1.0 if SKIRT else 0.0)

	var patch := _patch_mesh(N)
	patch.surface_set_material(0, mat)
	mm = MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_custom_data = true
	mm.mesh = patch
	mm.instance_count = MAX_NODES
	mm.visible_instance_count = 0
	buf.resize(MAX_NODES * 16)
	for i in MAX_NODES:
		# Identity transform; the shader reads the node from custom data.
		buf[i * 16] = 1.0
		buf[i * 16 + 5] = 1.0
		buf[i * 16 + 10] = 1.0
	mmi = MultiMeshInstance3D.new()
	mmi.multimesh = mm
	mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	# Nodes are culled here on the CPU; Godot must never cull the whole terrain.
	mmi.custom_aabb = AABB(Vector3(-ROOT * 0.5, BOX_MIN_Y, -ROOT * 0.5), Vector3(ROOT, BOX_MAX_Y - BOX_MIN_Y, ROOT))
	add_child(mmi)


func set_skirt(on: bool) -> void:
	mat.set_shader_parameter("skirt_on", 1.0 if on else 0.0)


# Grid of (N + 1)^2 vertices in [0, 1]^2 with alternating diagonals, plus a ring of skirt
# vertices (UV.x = 1) that the shader drops below the edge.
func _patch_mesh(n: int) -> ArrayMesh:
	var verts := PackedVector3Array()
	var uvs := PackedVector2Array()
	var idx := PackedInt32Array()
	var v := n + 1
	for z in v:
		for x in v:
			verts.append(Vector3(float(x) / n, 0.0, float(z) / n))
			uvs.append(Vector2.ZERO)
	# Godot treats clockwise triangles (seen from the front) as front faces; seen from +Y,
	# (a, b, c) with a = (x, z), b = (x + 1, z), c = (x, z + 1) is clockwise.
	for z in n:
		for x in n:
			var a := z * v + x
			var b := a + 1
			var c := a + v
			var d := c + 1
			if (x + z) % 2 == 0:
				idx.append_array([a, b, c, b, d, c])
			else:
				idx.append_array([a, b, d, a, d, c])
	if SKIRT:
		var border: Array[Vector2i] = []
		for x in n:
			border.append(Vector2i(x, 0))
		for z in n:
			border.append(Vector2i(n, z))
		for x in range(n, 0, -1):
			border.append(Vector2i(x, n))
		for z in range(n, 0, -1):
			border.append(Vector2i(0, z))
		border.append(border[0])
		var base := verts.size()
		for p in border:
			verts.append(Vector3(float(p.x) / n, 0.0, float(p.y) / n))
			uvs.append(Vector2(1.0, 0.0))
		# The border runs clockwise seen from +Y; these windings face out of the patch.
		for i in border.size() - 1:
			var a0 := border[i].y * v + border[i].x
			var b0 := border[i + 1].y * v + border[i + 1].x
			var c0 := base + i
			var d0 := base + i + 1
			idx.append_array([a0, c0, b0, b0, c0, d0])
	tris_per_node = idx.size() / 3
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_INDEX] = idx
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	mesh.custom_aabb = AABB(Vector3(-ROOT, BOX_MIN_Y, -ROOT), Vector3(ROOT * 2.0, BOX_MAX_Y - BOX_MIN_Y, ROOT * 2.0))
	return mesh


func _process(_delta: float) -> void:
	var cam := get_viewport().get_camera_3d()
	if cam == null:
		return
	select(cam)


func select(cam: Camera3D) -> int:
	_cam_pos = cam.global_position
	_planes = cam.get_frustum()
	_dy = maxf(0.0, _cam_pos.y - world.height(_cam_pos.x, _cam_pos.z))
	_count = 0
	_visit(-ROOT * 0.5, -ROOT * 0.5, ROOT)
	mm.buffer = buf
	mm.visible_instance_count = _count
	mat.set_shader_parameter("cam_xz", Vector2(_cam_pos.x, _cam_pos.z))
	mat.set_shader_parameter("cam_dy", _dy)
	last_nodes = _count
	last_tris = _count * tris_per_node
	return _count


func _visit(x0: float, z0: float, size: float) -> void:
	if _count >= MAX_NODES or not _box_visible(x0, z0, size):
		return
	var ddx := maxf(maxf(x0 - _cam_pos.x, 0.0), _cam_pos.x - (x0 + size))
	var ddz := maxf(maxf(z0 - _cam_pos.z, 0.0), _cam_pos.z - (z0 + size))
	var d := Vector2(Vector2(ddx, ddz).length(), _dy).length()
	if size > MIN_SIZE and d < LOD_K * size:
		var h := size * 0.5
		_visit(x0, z0, h)
		_visit(x0 + h, z0, h)
		_visit(x0, z0 + h, h)
		_visit(x0 + h, z0 + h, h)
	else:
		var k := _count * 16 + 12
		buf[k] = x0
		buf[k + 1] = z0
		buf[k + 2] = size
		buf[k + 3] = 0.0
		_count += 1


# Frustum planes point outward: a box is out when its corner deepest along a plane's normal
# is still in front of that plane.
func _box_visible(x0: float, z0: float, size: float) -> bool:
	for p in _planes:
		var n := p.normal
		var cx := x0 if n.x > 0.0 else x0 + size
		var cy := BOX_MIN_Y if n.y > 0.0 else BOX_MAX_Y
		var cz := z0 if n.z > 0.0 else z0 + size
		if n.x * cx + n.y * cy + n.z * cz - p.d > 0.0:
			return false
	return true
