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
const INIT_NODES := 256
const MAX_NODES := 1024
const BOX_MIN_Y := -200.0
const BOX_MAX_Y := 4400.0
const SKIRT := true
# Live walk/turn skip thresholds and strictly wider frustum padding so edge nodes never pop.
const MOVE_THRESH_SQ := 0.8 * 0.8
const ROT_COS := 0.999928  # cos(0.012 rad)
const PAD_M := 0.85
const PAD_ANG := 0.013
const SwapMultiMesh := preload("res://systems/swap_multimesh.gd")
const Flags := preload("res://systems/flags.gd")

var world: RefCounted
var mat: ShaderMaterial
var flat_mat: ShaderMaterial
var flat_on := false
var on := true
var frozen := false
var _patch: ArrayMesh
var _bounds: AABB
var draw: SwapMultiMesh
var _cap := INIT_NODES
var buf := PackedFloat32Array()
var tris_per_node := 0
var last_nodes := 0
var last_tris := 0
# Script time of this frame's _process and sub-parts, for the bench and perf panel.
var prof_us := 0
var select_us := 0
var push_us := 0
var uniform_us := 0
# Per frustum plane: nx, nz, ny * (the box y deepest along the normal) - d, so a node's test reads
# no Plane objects.
var _pl := PackedFloat64Array()
# Iterative traversal stack (max depth for 32768 -> 64 is 9, max stack height 28).
var _st_x := PackedFloat32Array()
var _st_z := PackedFloat32Array()
var _st_s := PackedFloat32Array()
var _cam_pos := Vector3.ZERO
var _dy := 0.0
var _last_dy := -1.0
var _last_flat_dy := -1.0
var _count := 0
var _pushed_count := -1
var _force_push := true
var _cam_valid := false
var _prev_xform := Transform3D.IDENTITY
var _still_frames := 2
var _last_xform := Transform3D.IDENTITY
var _last_pos := Vector3.ZERO
var _last_fwd := Vector3.FORWARD
var _last_up := Vector3.UP
var _last_fov := -1.0
var _last_far := -1.0
var _last_vp := Vector2.ZERO
var _last_pad := false


func setup(w: RefCounted) -> void:
	world = w


func _ready() -> void:
	# After the camera has moved this frame.
	process_priority = 100
	mat = ShaderMaterial.new()
	mat.shader = load("res://shaders/terrain.gdshader")
	mat.set_shader_parameter("near_tex", world.texture("near"))
	mat.set_shader_parameter("far_tex", world.texture("far"))
	mat.set_shader_parameter("biome_tex", world.texture("biome"))
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
	# ?dbg_terrain=<bits>: the ?probe=terrain switches in the real game, to confirm a probe finding.
	mat.set_shader_parameter("dbg_terrain", int(Flags.value("dbg_terrain", "0")))

	_patch = _patch_mesh(N)
	_patch.surface_set_material(0, mat)
	_st_x.resize(64)
	_st_z.resize(64)
	_st_s.resize(64)
	# Nodes are culled here on the CPU; Godot must never cull the whole terrain.
	_bounds = AABB(Vector3(-ROOT * 0.5, BOX_MIN_Y, -ROOT * 0.5), Vector3(ROOT, BOX_MAX_Y - BOX_MIN_Y, ROOT))
	_init_draw(INIT_NODES)


func _init_draw(cap: int) -> void:
	_cap = cap
	var old_n := buf.size() / 16
	buf.resize(_cap * 16)
	for i in range(old_n, _cap):
		# Identity transform; the shader reads the node from custom data.
		buf[i * 16] = 1.0
		buf[i * 16 + 5] = 1.0
		buf[i * 16 + 10] = 1.0
	if draw != null:
		for mmi in draw.mmis:
			remove_child(mmi)
			mmi.queue_free()
	draw = SwapMultiMesh.new(self, _patch, _cap, _bounds)
	draw.set_visible(on)
	if flat_on and flat_mat != null:
		for mmi in draw.mmis:
			mmi.material_override = flat_mat
	_pushed_count = -1
	_force_push = true


func set_skirt(on: bool) -> void:
	mat.set_shader_parameter("skirt_on", 1.0 if on else 0.0)
	if flat_mat != null:
		flat_mat.set_shader_parameter("skirt_on", 1.0 if on else 0.0)


# Sweep helper: swap terrain fragments to a flat colour while keeping identical CDLOD vertices and depth.
func set_flat(on: bool) -> void:
	if on == flat_on:
		return
	flat_on = on
	if on and flat_mat == null:
		flat_mat = ShaderMaterial.new()
		flat_mat.shader = load("res://shaders/terrain_flat.gdshader")
		flat_mat.set_shader_parameter("near_tex", world.texture("near"))
		flat_mat.set_shader_parameter("far_tex", world.texture("far"))
		flat_mat.set_shader_parameter("biome_tex", world.texture("biome"))
		flat_mat.set_shader_parameter("noise_tex", world.noise_tex)
		flat_mat.set_shader_parameter("near_size", world.near_size)
		flat_mat.set_shader_parameter("near_min", world.near_min)
		flat_mat.set_shader_parameter("near_step", world.near_step)
		flat_mat.set_shader_parameter("far_size", world.far_size)
		flat_mat.set_shader_parameter("far_min", world.far_min)
		flat_mat.set_shader_parameter("far_step", world.far_step)
		flat_mat.set_shader_parameter("grid_n", float(N))
		flat_mat.set_shader_parameter("lod_k", LOD_K)
		flat_mat.set_shader_parameter("skirt_on", mat.get_shader_parameter("skirt_on"))
		flat_mat.set_shader_parameter("cam_dy", _dy)
		_last_flat_dy = _dy
	elif on and flat_mat != null and absf(_dy - _last_flat_dy) > 0.005:
		flat_mat.set_shader_parameter("cam_dy", _dy)
		_last_flat_dy = _dy
	for mmi in draw.mmis:
		mmi.material_override = flat_mat if on else null


func set_on(v: bool) -> void:
	on = v
	draw.set_visible(v)
	if not v:
		last_nodes = 0
		last_tris = 0
	else:
		_cam_valid = false


func is_on() -> bool:
	return on


func set_frozen(v: bool) -> void:
	frozen = v


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
	var t0 := Time.get_ticks_usec()
	select_us = 0
	push_us = 0
	uniform_us = 0
	var cam := get_viewport().get_camera_3d()
	if on and not frozen and cam != null:
		select(cam, true)
	prof_us = Time.get_ticks_usec() - t0


func select(cam: Camera3D, allow_pad: bool = false) -> int:
	var ts := Time.get_ticks_usec()
	var xform := cam.global_transform
	var pos := xform.origin
	var fwd := -xform.basis.z
	var up := xform.basis.y
	var vp_sz := cam.get_viewport().get_visible_rect().size
	if not _cam_valid:
		_still_frames = 2
	elif xform == _prev_xform:
		_still_frames = mini(_still_frames + 1, 2)
	else:
		_still_frames = 0
	_prev_xform = xform
	var pad := allow_pad and _still_frames < 2
	if _cam_valid and _last_pad == pad and cam.fov == _last_fov and cam.far == _last_far and vp_sz == _last_vp:
		if pad:
			if pos.distance_squared_to(_last_pos) < MOVE_THRESH_SQ and fwd.dot(_last_fwd) >= ROT_COS and up.dot(_last_up) >= ROT_COS:
				select_us = Time.get_ticks_usec() - ts
				return last_nodes
		elif xform == _last_xform:
			select_us = Time.get_ticks_usec() - ts
			return last_nodes
	_cam_valid = true
	_last_pad = pad
	_last_xform = xform
	_last_pos = pos
	_last_fwd = fwd
	_last_up = up
	_last_fov = cam.fov
	_last_far = cam.far
	_last_vp = vp_sz

	_cam_pos = pos
	var cam_x := pos.x
	var cam_z := pos.z
	var planes := cam.get_frustum()
	var pn := planes.size()
	if _pl.size() != pn * 3:
		_pl.resize(pn * 3)
	for i in pn:
		var pl := planes[i]
		var n := pl.normal
		var d := pl.d
		if pad:
			if absf(n.dot(fwd)) < 0.85:
				n = (n - fwd * PAD_ANG).normalized()
				d = n.dot(pos) + PAD_M
			else:
				d += PAD_M
		var j := i * 3
		_pl[j] = n.x
		_pl[j + 1] = n.z
		_pl[j + 2] = n.y * (BOX_MIN_Y if n.y > 0.0 else BOX_MAX_Y) - d
	_dy = maxf(0.0, _cam_pos.y - world.height(cam_x, cam_z))
	var dy2 := _dy * _dy
	var pl_len := pn * 3

	_count = 0
	var changed := false
	_st_x[0] = -ROOT * 0.5
	_st_z[0] = -ROOT * 0.5
	_st_s[0] = ROOT
	var sp := 1
	while sp > 0:
		sp -= 1
		var x0 := _st_x[sp]
		var z0 := _st_z[sp]
		var size := _st_s[sp]
		if _count >= MAX_NODES:
			break
		var x1 := x0 + size
		var z1 := z0 + size
		var vis := true
		var pi := 0
		while pi < pl_len:
			var nx := _pl[pi]
			var nz := _pl[pi + 1]
			if nx * (x0 if nx > 0.0 else x1) + nz * (z0 if nz > 0.0 else z1) + _pl[pi + 2] > 0.0:
				vis = false
				break
			pi += 3
		if not vis:
			continue
		var ddx := x0 - cam_x if cam_x < x0 else (cam_x - x1 if cam_x > x1 else 0.0)
		var ddz := z0 - cam_z if cam_z < z0 else (cam_z - z1 if cam_z > z1 else 0.0)
		var lim := LOD_K * size
		if size > MIN_SIZE and ddx * ddx + ddz * ddz + dy2 < lim * lim:
			var h := size * 0.5
			_st_x[sp] = x0 + h; _st_z[sp] = z0 + h; _st_s[sp] = h; sp += 1
			_st_x[sp] = x0;     _st_z[sp] = z0 + h; _st_s[sp] = h; sp += 1
			_st_x[sp] = x0 + h; _st_z[sp] = z0;     _st_s[sp] = h; sp += 1
			_st_x[sp] = x0;     _st_z[sp] = z0;     _st_s[sp] = h; sp += 1
		else:
			if _count >= _cap:
				_init_draw(mini(MAX_NODES, _cap * 2))
				changed = true
			var k := _count * 16 + 12
			if buf[k] != x0 or buf[k + 1] != z0 or buf[k + 2] != size:
				buf[k] = x0
				buf[k + 1] = z0
				buf[k + 2] = size
				buf[k + 3] = 0.0
				changed = true
			_count += 1

	var tp := Time.get_ticks_usec()
	select_us = tp - ts
	if changed or _count != _pushed_count or _force_push:
		draw.push(buf, _count)
		_pushed_count = _count
		_force_push = false
	var tu := Time.get_ticks_usec()
	push_us = tu - tp
	if absf(_dy - _last_dy) > 0.005:
		mat.set_shader_parameter("cam_dy", _dy)
		_last_dy = _dy
	if flat_on and flat_mat != null and absf(_dy - _last_flat_dy) > 0.005:
		flat_mat.set_shader_parameter("cam_dy", _dy)
		_last_flat_dy = _dy
	uniform_us = Time.get_ticks_usec() - tu
	last_nodes = _count
	last_tris = _count * tris_per_node
	return _count
