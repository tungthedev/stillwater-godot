extends Node3D

# Lightweight Mika-style fake decal lights & shadows helper (W3).
# Uses additive glow spheres (blend_add, zero OmniLight3D, zero depth-texture copy) and
# multiplicative contact shadow discs (blend_mul, zero shadow map) packed into SwapMultiMeshes.
# Kept off by default during daytime (0 draws, 0 tris, 0 ms) and ready to be driven by
# time-of-day glow in W5 (or forced on via ?fakelights for visual verification).

const SwapMultiMesh := preload("res://systems/swap_multimesh.gd")

var add_mat: ShaderMaterial
var mul_mat: ShaderMaterial
var _light_swap: RefCounted
var _shadow_swap: RefCounted
var _lights: Array[Dictionary] = []
var _shadows: Array[Dictionary] = []
var _light_mesh: ArrayMesh
var _shadow_mesh: ArrayMesh
var _intensity := 0.0
var _shadows_on := false
var _lights_enabled := false
var _on := true

var last_draws := 0
var last_tris := 0
var _light_tris := 0
var _shadow_tris := 0


func _ready() -> void:
	add_mat = ShaderMaterial.new()
	add_mat.shader = load("res://shaders/fake_light_add.gdshader")
	add_mat.render_priority = 2
	add_mat.set_shader_parameter("global_intensity", _intensity)

	mul_mat = ShaderMaterial.new()
	mul_mat.shader = load("res://shaders/fake_shadow_mul.gdshader")
	mul_mat.render_priority = 1
	mul_mat.set_shader_parameter("global_strength", 1.0)

	_light_mesh = _build_sphere_mesh(1)
	_light_mesh.surface_set_material(0, add_mat)
	_shadow_mesh = _build_disc_mesh()
	_shadow_mesh.surface_set_material(0, mul_mat)


func materials() -> Array[ShaderMaterial]:
	var out: Array[ShaderMaterial] = []
	if add_mat != null:
		out.append(add_mat)
	if mul_mat != null:
		out.append(mul_mat)
	return out


func add_light(pos: Vector3, radius: float, color: Color, intensity: float = 1.0) -> void:
	_lights.append({"pos": pos, "r": radius, "col": color, "i": intensity})


func add_shadow(pos: Vector3, radius_xz: Vector2, strength: float = 0.45, tint: Color = Color(0.48, 0.52, 0.72)) -> void:
	_shadows.append({"pos": pos, "r": radius_xz, "s": strength, "col": tint})


func rebuild() -> void:
	if not _lights.is_empty():
		var cap := maxi(1, _lights.size())
		var aabb := AABB(_lights[0].pos, Vector3.ONE)
		var buf := PackedFloat32Array()
		buf.resize(cap * 16)
		for i in _lights.size():
			var L: Dictionary = _lights[i]
			var p: Vector3 = L.pos
			var r: float = float(L.r)
			var c: Color = L.col
			var o := i * 16
			buf[o + 0] = r; buf[o + 1] = 0.0; buf[o + 2] = 0.0; buf[o + 3] = p.x
			buf[o + 4] = 0.0; buf[o + 5] = r; buf[o + 6] = 0.0; buf[o + 7] = p.y
			buf[o + 8] = 0.0; buf[o + 9] = 0.0; buf[o + 10] = r; buf[o + 11] = p.z
			buf[o + 12] = c.r; buf[o + 13] = c.g; buf[o + 14] = c.b; buf[o + 15] = float(L.i)
			aabb = aabb.merge(AABB(p - Vector3(r, r, r), Vector3(r * 2.0, r * 2.0, r * 2.0)))
		if _light_swap == null:
			_light_swap = SwapMultiMesh.new(self, _light_mesh, cap, aabb)
		_light_swap.push(buf, _lights.size())
	if not _shadows.is_empty():
		var cap := maxi(1, _shadows.size())
		var aabb := AABB(_shadows[0].pos, Vector3.ONE)
		var buf := PackedFloat32Array()
		buf.resize(cap * 16)
		for i in _shadows.size():
			var S: Dictionary = _shadows[i]
			var p: Vector3 = S.pos
			var r: Vector2 = S.r
			var c: Color = S.col
			var o := i * 16
			buf[o + 0] = r.x; buf[o + 1] = 0.0; buf[o + 2] = 0.0; buf[o + 3] = p.x
			buf[o + 4] = 0.0; buf[o + 5] = 1.0; buf[o + 6] = 0.0; buf[o + 7] = p.y + 0.04
			buf[o + 8] = 0.0; buf[o + 9] = 0.0; buf[o + 10] = r.y; buf[o + 11] = p.z
			buf[o + 12] = c.r; buf[o + 13] = c.g; buf[o + 14] = c.b; buf[o + 15] = float(S.s)
			aabb = aabb.merge(AABB(p - Vector3(r.x, 1.0, r.y), Vector3(r.x * 2.0, 2.0, r.y * 2.0)))
		if _shadow_swap == null:
			_shadow_swap = SwapMultiMesh.new(self, _shadow_mesh, cap, aabb)
		_shadow_swap.push(buf, _shadows.size())
	_sync_visibility()


func set_intensity(v: float) -> void:
	_intensity = maxf(v, 0.0)
	_lights_enabled = _intensity > 0.001
	if add_mat != null:
		add_mat.set_shader_parameter("global_intensity", _intensity)
	_sync_visibility()


func set_shadows_on(v: bool) -> void:
	_shadows_on = v
	_sync_visibility()


func set_on(v: bool) -> void:
	_on = v
	_sync_visibility()


func _sync_visibility() -> void:
	var l_vis := _on and _lights_enabled and _light_swap != null and not _lights.is_empty()
	var s_vis := _on and _shadows_on and _shadow_swap != null and not _shadows.is_empty()
	if _light_swap != null:
		_light_swap.set_visible(l_vis)
	if _shadow_swap != null:
		_shadow_swap.set_visible(s_vis)
	last_draws = (1 if l_vis else 0) + (1 if s_vis else 0)
	last_tris = (_lights.size() * _light_tris if l_vis else 0) + (_shadows.size() * _shadow_tris if s_vis else 0)


func _build_sphere_mesh(subdiv: int) -> ArrayMesh:
	var t := (1.0 + sqrt(5.0)) * 0.5
	var verts: Array[Vector3] = [
		Vector3(-1, t, 0).normalized(), Vector3(1, t, 0).normalized(),
		Vector3(-1, -t, 0).normalized(), Vector3(1, -t, 0).normalized(),
		Vector3(0, -1, t).normalized(), Vector3(0, 1, t).normalized(),
		Vector3(0, -1, -t).normalized(), Vector3(0, 1, -t).normalized(),
		Vector3(t, 0, -1).normalized(), Vector3(t, 0, 1).normalized(),
		Vector3(-t, 0, -1).normalized(), Vector3(-t, 0, 1).normalized(),
	]
	var tris: Array[Vector3i] = [
		Vector3i(0, 11, 5), Vector3i(0, 5, 1), Vector3i(0, 1, 7), Vector3i(0, 7, 10), Vector3i(0, 10, 11),
		Vector3i(1, 5, 9), Vector3i(5, 11, 4), Vector3i(11, 10, 2), Vector3i(10, 7, 6), Vector3i(7, 1, 8),
		Vector3i(3, 9, 4), Vector3i(3, 4, 2), Vector3i(3, 2, 6), Vector3i(3, 6, 8), Vector3i(3, 8, 9),
		Vector3i(4, 9, 5), Vector3i(2, 4, 11), Vector3i(6, 2, 10), Vector3i(8, 6, 7), Vector3i(9, 8, 1),
	]
	for _s in subdiv:
		var cache := {}
		var next_tris: Array[Vector3i] = []
		var mid := func(a: int, b: int) -> int:
			var lo := mini(a, b)
			var hi := maxi(a, b)
			var key := (lo << 16) | hi
			if cache.has(key):
				return int(cache[key])
			var idx := verts.size()
			verts.append((verts[a] + verts[b]).normalized())
			cache[key] = idx
			return idx
		for f in tris:
			var ab: int = mid.call(f.x, f.y)
			var bc: int = mid.call(f.y, f.z)
			var ca: int = mid.call(f.z, f.x)
			next_tris.append(Vector3i(f.x, ab, ca))
			next_tris.append(Vector3i(f.y, bc, ab))
			next_tris.append(Vector3i(f.z, ca, bc))
			next_tris.append(Vector3i(ab, bc, ca))
		tris = next_tris
	var pv := PackedVector3Array()
	var pn := PackedVector3Array()
	var idx := PackedInt32Array()
	for v in verts:
		pv.append(v)
		pn.append(v)
	for f in tris:
		var v0 := verts[f.x]
		var v1 := verts[f.y]
		var v2 := verts[f.z]
		var navg := v0 + v1 + v2
		if (v2 - v0).cross(v1 - v0).dot(navg) >= 0.0:
			idx.append_array([f.x, f.y, f.z])
		else:
			idx.append_array([f.x, f.z, f.y])
	_light_tris = idx.size() / 3
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = pv
	arrays[Mesh.ARRAY_NORMAL] = pn
	arrays[Mesh.ARRAY_INDEX] = idx
	var m := ArrayMesh.new()
	m.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return m


func _build_disc_mesh() -> ArrayMesh:
	var pv := PackedVector3Array([
		Vector3(-1.0, 0.0, -1.0), Vector3(1.0, 0.0, -1.0),
		Vector3(1.0, 0.0, 1.0), Vector3(-1.0, 0.0, 1.0),
	])
	var pn := PackedVector3Array([Vector3.UP, Vector3.UP, Vector3.UP, Vector3.UP])
	var puv := PackedVector2Array([Vector2(0, 0), Vector2(1, 0), Vector2(1, 1), Vector2(0, 1)])
	# CW viewed from +Y.
	var idx := PackedInt32Array([0, 1, 2, 0, 2, 3])
	_shadow_tris = 2
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = pv
	arrays[Mesh.ARRAY_NORMAL] = pn
	arrays[Mesh.ARRAY_TEX_UV] = puv
	arrays[Mesh.ARRAY_INDEX] = idx
	var m := ArrayMesh.new()
	m.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return m
