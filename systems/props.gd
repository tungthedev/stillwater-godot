extends Node3D

# Slice W3: Chunky painted rocks, storybook cottage, village fences & lanterns, trailhead signpost,
# scenic benches, lakeside pier & rowboat, summit prayer flags, and Mika fake decal lights helper.
#
# Perf contract (iPhone 13 mini WebGL2):
#   - <= 8 draw calls total in any view (typically 2-6 draws):
#       1. Rocks Kind 0 (chunky 80-tri faceted boulders & cairn stones, SwapMultiMesh)
#       2. Rocks Kind 1 (chunky 320-tri crags & glacial erratics, SwapMultiMesh)
#       3. Storybook Cottage + yard + flagstones + bushes + glass (1 static MeshInstance3D)
#       4. Trailhead Signpost (post + 3 cedar lettering boards, 1 static MeshInstance3D)
#       5. Scenic Benches (3 benches, SwapMultiMesh)
#       6. Village Fences & Trail Lantern Posts (1 static MeshInstance3D)
#       7. Lake Pier + Rowboat + Driftwood (1 static MeshInstance3D, culled off-lake)
#       8. Summit Prayer Flags + Poles (culled off-summit)
#       + FakeLights (SwapMultiMesh helper, 0 draws by day unless ?fakelights)
#   - All opaque, zero-discard materials with render_priority = -1 (Apple TBDR HSR).
#   - Distance culling runs only when camera moves >= CULL_STEP m (0.000 ms stationary GDScript).

const SwapMultiMesh := preload("res://systems/swap_multimesh.gd")
const FakeLights := preload("res://systems/fake_lights.gd")
const Flags := preload("res://systems/flags.gd")

const CULL_STEP := 6.0
const SMALL_ROCK_DIST := 280.0
const BIG_ROCK_DIST := 950.0
const PROP_STONE_DIST := 260.0
const BENCH_DIST := 260.0
const CULL_PAD := 24.0

var world: RefCounted
var rock_mat: ShaderMaterial
var prop_mat: ShaderMaterial
var sign_mat: ShaderMaterial
var flag_mat: ShaderMaterial
var fake_lights: Node3D

var _rock_small_swap: RefCounted
var _rock_crag_swap: RefCounted
var _bench_swap: RefCounted
var _rock_small_buf := PackedFloat32Array()
var _rock_crag_buf := PackedFloat32Array()
var _bench_buf := PackedFloat32Array()
var _rock_small_tris := 0
var _rock_crag_tris := 0
var _bench_tris := 0

# Rock instance arrays split into small/boulder (kind 0..2 + prop stones) and crag (kind 3).
var _small_rocks: Array = []
var _crag_rocks: Array = []
var _bench_list: Array = []

# Static region meshes with tight AABBs and visibility_range_end for automatic frustum/distance cull.
var _static_meshes: Array[Dictionary] = []

# Canonical rock colliders (s > 0.9, matching worldData.js) + static circle colliders.
var _rock_colliders: Array = []
var _prop_colliders: Array = []
var benches: Array[Dictionary] = []

var _cull_pos := Vector3(1e9, 0.0, 1e9)
var _dist_scale := 1.0
var _dirty := true
var _on := true
var frozen := false

var _small_vis := 0
var _crag_vis := 0
var _bench_vis := 0
var _small_aabb := AABB()
var _crag_aabb := AABB()
var _bench_aabb := AABB()

var total_rocks := 0
var last_draws := 0
var last_tris := 0
var load_ms := 0
var prof_us := 0


func setup(w: RefCounted) -> void:
	world = w


func _ready() -> void:
	var t0 := Time.get_ticks_msec()
	process_priority = 100
	_build_materials()
	_build_rocks()
	_build_benches()
	_build_cottage_and_yard()
	_build_signpost()
	_build_fences_and_lanterns()
	_build_lake_props()
	_build_summit_flags()
	_build_fake_lights()
	_load_colliders()
	load_ms = Time.get_ticks_msec() - t0
	print("PROPS built in %d ms: rocks=%d (small=%d, crag=%d), benches=%d, static=%d meshes, fake_lights=%s" % [
		load_ms, total_rocks, _small_rocks.size(), _crag_rocks.size(), _bench_list.size(),
		_static_meshes.size(), "on" if Flags.has("fakelights") else "off(day)"])


func materials() -> Array[ShaderMaterial]:
	var out: Array[ShaderMaterial] = [rock_mat, prop_mat, sign_mat, flag_mat]
	if fake_lights != null:
		out.append_array(fake_lights.materials())
	return out


func set_on(v: bool) -> void:
	_on = v
	visible = v
	if _rock_small_swap != null:
		_rock_small_swap.set_visible(v and _small_vis > 0)
	if _rock_crag_swap != null:
		_rock_crag_swap.set_visible(v and _crag_vis > 0)
	if _bench_swap != null:
		_bench_swap.set_visible(v and _bench_vis > 0)
	for sm in _static_meshes:
		(sm.mi as MeshInstance3D).visible = v
	if fake_lights != null:
		fake_lights.set_on(v)
	if not v:
		last_draws = 0
		last_tris = 0
	else:
		_dirty = true


func is_on() -> bool:
	return _on


func set_frozen(v: bool) -> void:
	frozen = v


func set_dist_scale(s: float) -> void:
	var clamped := clampf(s, 0.35, 1.0)
	if absf(clamped - _dist_scale) < 1e-4:
		return
	_dist_scale = clamped
	if rock_mat != null:
		rock_mat.set_shader_parameter("dist_scale", _dist_scale)
	_dirty = true


func set_night_glow(v: float) -> void:
	var g := clampf(v, 0.0, 1.0)
	if prop_mat != null:
		prop_mat.set_shader_parameter("night_glow", g)
	if fake_lights != null:
		fake_lights.set_intensity(g)


func _process(_delta: float) -> void:
	var t0 := Time.get_ticks_usec()
	if not frozen and _on:
		var cam := get_viewport().get_camera_3d()
		if cam != null:
			update_cull(cam, false)
	prof_us = Time.get_ticks_usec() - t0


func update_cull(cam: Camera3D, force: bool = false) -> void:
	if not _on:
		return
	var cp := cam.global_position
	if not force and not _dirty and cp.distance_squared_to(_cull_pos) < CULL_STEP * CULL_STEP:
		return
	_cull_pos = cp
	_dirty = false
	_cull_rock_group(_small_rocks, _rock_small_swap, _rock_small_buf, cp, true)
	_cull_rock_group(_crag_rocks, _rock_crag_swap, _rock_crag_buf, cp, false)
	_cull_benches(cp)


func count_drawn(cam: Camera3D) -> void:
	if not _on:
		last_draws = 0
		last_tris = 0
		return
	var planes := cam.get_frustum()
	var cp := cam.global_position
	var draws := 0
	var tris := 0
	if _small_vis > 0 and _aabb_in_frustum(_small_aabb, planes):
		draws += 1
		tris += _small_vis * _rock_small_tris
	if _crag_vis > 0 and _aabb_in_frustum(_crag_aabb, planes):
		draws += 1
		tris += _crag_vis * _rock_crag_tris
	if _bench_vis > 0 and _aabb_in_frustum(_bench_aabb, planes):
		draws += 1
		tris += _bench_vis * _bench_tris
	for sm in _static_meshes:
		var aabb: AABB = sm.aabb
		var max_r: float = float(sm.max_dist) * _dist_scale
		if max_r > 0.0 and aabb.get_center().distance_to(cp) > max_r + aabb.size.length() * 0.5:
			continue
		if _aabb_in_frustum(aabb, planes):
			draws += 1
			tris += int(sm.tris)
	if fake_lights != null:
		draws += fake_lights.last_draws
		tris += fake_lights.last_tris
	last_draws = draws
	last_tris = tris


static func _aabb_in_frustum(aabb: AABB, planes: Array[Plane]) -> bool:
	var p0 := aabb.position
	var p1 := aabb.position + aabb.size
	for pl in planes:
		var n := pl.normal
		var px := p0.x if n.x >= 0.0 else p1.x
		var py := p0.y if n.y >= 0.0 else p1.y
		var pz := p0.z if n.z >= 0.0 else p1.z
		if pl.distance_to(Vector3(px, py, pz)) > 0.0:
			return false
	return true


# Player collision against canonical rocks (s > 0.9, matching worldData.js) + cottage & props.
func collide(pos: Vector2, ground_y: float) -> Vector2:
	const RADIUS := 0.35
	for c in _rock_colliders:
		var dx := pos.x - float(c[0])
		var dz := pos.y - float(c[1])
		var rr := float(c[2]) + RADIUS
		if absf(dx) > rr or absf(dz) > rr:
			continue
		if float(c[3]) <= ground_y + 0.6:
			continue
		var d2 := dx * dx + dz * dz
		if d2 < rr * rr and d2 > 1e-8:
			var inv_d := rr / sqrt(d2)
			pos = Vector2(float(c[0]) + dx * inv_d, float(c[1]) + dz * inv_d)
	for c in _prop_colliders:
		var dx := pos.x - float(c[0])
		var dz := pos.y - float(c[1])
		var rr := float(c[2]) + RADIUS
		if absf(dx) > rr or absf(dz) > rr:
			continue
		var d2 := dx * dx + dz * dz
		if d2 < rr * rr and d2 > 1e-8:
			var inv_d := rr / sqrt(d2)
			pos = Vector2(float(c[0]) + dx * inv_d, float(c[1]) + dz * inv_d)
	return pos


# ---------- Materials (all opaque no-discard render_priority = -1) ----------
func _build_materials() -> void:
	rock_mat = ShaderMaterial.new()
	rock_mat.shader = load("res://shaders/rock_painted.gdshader")
	rock_mat.render_priority = -1
	rock_mat.set_shader_parameter("sky_lut", world.sky_lut_tex)
	rock_mat.set_shader_parameter("noise_tex", world.noise_tex)
	rock_mat.set_shader_parameter("water_level", world.water_level)
	rock_mat.set_shader_parameter("dist_scale", _dist_scale)
	var wf: Dictionary = world.waterfall_info()
	if not wf.is_empty():
		var pc: Array = wf.poolCenter
		rock_mat.set_shader_parameter("waterfall", Vector4(float(pc[0]), float(pc[1]), float(pc[2]), 58.0))

	prop_mat = ShaderMaterial.new()
	prop_mat.shader = load("res://shaders/prop_painted.gdshader")
	prop_mat.render_priority = -1
	prop_mat.set_shader_parameter("sky_lut", world.sky_lut_tex)
	prop_mat.set_shader_parameter("noise_tex", world.noise_tex)
	prop_mat.set_shader_parameter("water_level", world.water_level)
	prop_mat.set_shader_parameter("night_glow", 0.0)

	sign_mat = ShaderMaterial.new()
	sign_mat.shader = load("res://shaders/signpost_painted.gdshader")
	sign_mat.render_priority = -1
	sign_mat.set_shader_parameter("sky_lut", world.sky_lut_tex)
	sign_mat.set_shader_parameter("noise_tex", world.noise_tex)
	sign_mat.set_shader_parameter("water_level", world.water_level)
	var stex: ImageTexture = world.load_signpost_tex()
	if stex != null:
		sign_mat.set_shader_parameter("signpost_tex", stex)

	flag_mat = ShaderMaterial.new()
	flag_mat.shader = load("res://shaders/prayer_flags.gdshader")
	flag_mat.render_priority = -1
	flag_mat.set_shader_parameter("sky_lut", world.sky_lut_tex)
	flag_mat.set_shader_parameter("noise_tex", world.noise_tex)
	flag_mat.set_shader_parameter("water_level", world.water_level)


# ---------- 1. Chunky Faceted Painted Rocks (2 SwapMultiMeshes) ----------
func _build_rocks() -> void:
	var rdata: Dictionary = world.load_rocks()
	if rdata.is_empty():
		return
	total_rocks = int(rdata.count)
	var rx: PackedFloat32Array = rdata.x
	var ry: PackedFloat32Array = rdata.y
	var rz: PackedFloat32Array = rdata.z
	var rsx: PackedFloat32Array = rdata.sx
	var rsy: PackedFloat32Array = rdata.sy
	var rsz: PackedFloat32Array = rdata.sz
	var rrot: PackedFloat32Array = rdata.rot
	var rtx: PackedFloat32Array = rdata.tilt_x
	var rtz: PackedFloat32Array = rdata.tilt_z
	var rkind: PackedByteArray = rdata.kind
	var rprop: PackedByteArray = rdata.is_prop
	var canon_n := int(rdata.canonical_count)

	# Aspect variation per canonical kind 0, 1, 2, 3 (matching rocks.js flat = 0.65, 0.72, 0.80, 0.62).
	var flat_y := [0.65, 0.72, 0.80, 0.62]
	var aspect_xz := [Vector2(1.06, 0.94), Vector2(0.95, 1.08), Vector2(1.02, 0.98), Vector2(1.05, 1.02)]

	for i in total_rocks:
		var k := int(rkind[i])
		var is_p := int(rprop[i]) != 0
		var sx := rsx[i]
		var sy := rsy[i]
		var sz := rsz[i]
		if not is_p:
			sx *= aspect_xz[k].x
			sy *= flat_y[k]
			sz *= aspect_xz[k].y
		var basis := Basis.from_euler(Vector3(rtz[i] * 0.45, rrot[i], -rtx[i] * 0.45), EULER_ORDER_XYZ)
		basis = basis.scaled(Vector3(sx, sy, sz))
		var s_max := maxf(sx, maxf(sy, sz))
		var max_d := BIG_ROCK_DIST if s_max >= 3.0 else (PROP_STONE_DIST if is_p else SMALL_ROCK_DIST)
		var hue_seed := fposmod(absf(rx[i] * 0.137 + rz[i] * 0.293 + float(k) * 0.31), 1.0)
		var entry := [
			rx[i], ry[i], rz[i],
			basis.x.x, basis.y.x, basis.z.x,
			basis.x.y, basis.y.y, basis.z.y,
			basis.x.z, basis.y.z, basis.z.z,
			max_d, hue_seed, s_max,
		]
		if k == 3 and not is_p:
			_crag_rocks.append(entry)
		else:
			_small_rocks.append(entry)
		# Canonical rock colliders (s > 0.9, matching worldData.js line 776).
		if i < canon_n and rsx[i] > 0.9:
			_rock_colliders.append([rx[i], rz[i], rsx[i] * 0.85, ry[i] + rsx[i] * 0.6])

	var small_mesh := _build_rock_mesh(11, 1)
	small_mesh.surface_set_material(0, rock_mat)
	_rock_small_tris = small_mesh.surface_get_array_index_len(0) / 3

	var crag_mesh := _build_rock_mesh(47, 2)
	crag_mesh.surface_set_material(0, rock_mat)
	_rock_crag_tris = crag_mesh.surface_get_array_index_len(0) / 3

	var small_cap := maxi(1, _small_rocks.size())
	var crag_cap := maxi(1, _crag_rocks.size())
	_rock_small_buf.resize(small_cap * 16)
	_rock_crag_buf.resize(crag_cap * 16)
	var big_box := AABB(Vector3(-2500.0, -200.0, -2500.0), Vector3(5000.0, 2600.0, 5000.0))
	_rock_small_swap = SwapMultiMesh.new(self, small_mesh, small_cap, big_box)
	_rock_crag_swap = SwapMultiMesh.new(self, crag_mesh, crag_cap, big_box)


func _cull_rock_group(list: Array, swap: RefCounted, buf: PackedFloat32Array, cp: Vector3, is_small: bool) -> void:
	if swap == null or list.is_empty():
		return
	var vis := 0
	var aabb := AABB()
	var has_box := false
	for e in list:
		var ex := float(e[0])
		var ey := float(e[1])
		var ez := float(e[2])
		var max_d := float(e[12]) * _dist_scale + CULL_PAD
		var dx := ex - cp.x
		var dy := ey - cp.y
		var dz := ez - cp.z
		if dx * dx + dy * dy + dz * dz > max_d * max_d:
			continue
		var o := vis * 16
		buf[o + 0] = float(e[3]);  buf[o + 1] = float(e[4]);  buf[o + 2] = float(e[5]);  buf[o + 3] = ex
		buf[o + 4] = float(e[6]);  buf[o + 5] = float(e[7]);  buf[o + 6] = float(e[8]);  buf[o + 7] = ey
		buf[o + 8] = float(e[9]);  buf[o + 9] = float(e[10]); buf[o + 10] = float(e[11]); buf[o + 11] = ez
		buf[o + 12] = float(e[12]); buf[o + 13] = float(e[13]); buf[o + 14] = 0.0; buf[o + 15] = 0.0
		var r := float(e[14]) * 1.35
		var b := AABB(Vector3(ex - r, ey - r, ez - r), Vector3(r * 2.0, r * 2.0, r * 2.0))
		aabb = b if not has_box else aabb.merge(b)
		has_box = true
		vis += 1
	if is_small:
		_small_vis = vis
		_small_aabb = aabb
	else:
		_crag_vis = vis
		_crag_aabb = aabb
	if vis > 0:
		swap.push(buf, vis)
		swap.set_visible(_on)
		for mmi: MultiMeshInstance3D in swap.mmis:
			mmi.custom_aabb = aabb
	else:
		swap.set_visible(false)


func _build_rock_mesh(seed_val: int, subdiv: int) -> ArrayMesh:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_val
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
			var id := verts.size()
			verts.append((verts[a] + verts[b]).normalized())
			cache[key] = id
			return id
		for f in tris:
			var ab: int = mid.call(f.x, f.y)
			var bc: int = mid.call(f.y, f.z)
			var ca: int = mid.call(f.z, f.x)
			next_tris.append(Vector3i(f.x, ab, ca))
			next_tris.append(Vector3i(f.y, bc, ab))
			next_tris.append(Vector3i(f.z, ca, bc))
			next_tris.append(Vector3i(ab, bc, ca))
		tris = next_tris

	# Sculpt chunky planar-cut alpine boulder (rocks.js rockGeometry recipe).
	var planes: Array[Dictionary] = []
	for _i in 10:
		var pn := Vector3(rng.randf() - 0.5, rng.randf() - 0.22, rng.randf() - 0.5).normalized()
		planes.append({"n": pn, "d": 0.64 + rng.randf() * 0.22})
	var ox := rng.randf() * 100.0
	var oy := rng.randf() * 100.0
	var oz := rng.randf() * 100.0
	var cav := PackedFloat32Array()
	cav.resize(verts.size())
	for i in verts.size():
		var v := verts[i]
		var n1 := sin(v.x * 2.7 + ox) * cos(v.y * 2.5 + oy) * sin(v.z * 2.9 + oz)
		var n2 := sin(v.x * 5.4 - oz) * sin(v.y * 4.8 + ox) * cos(v.z * 5.1 - oy)
		v *= 1.0 + n1 * 0.20 + n2 * 0.08
		var cut_sum := 0.0
		for pl in planes:
			var dd := v.dot(pl.n)
			if dd > float(pl.d):
				var cut := (dd - float(pl.d)) * 0.86
				v -= pl.n * cut
				cut_sum += cut
		# Flattened bottom skirt extends solidly into sloped terrain so boulders never float.
		if v.y < -0.25:
			v.y = -0.25 + (v.y + 0.25) * 0.45
		verts[i] = v
		# Cavity AO: bottom faces slightly darker, sharp cut bevels subtly brighter.
		cav[i] = clampf(0.76 + clampf((v.y + 0.45) * 0.32, 0.0, 0.28) + clampf(cut_sum * 0.14, 0.0, 0.12), 0.55, 1.0)

	# Compute smooth vertex normals, then blend 65% flat face normal + 35% smooth for crisp facets.
	var smooth_n: Array[Vector3] = []
	smooth_n.resize(verts.size())
	for i in verts.size():
		smooth_n[i] = Vector3.ZERO
	var face_n: Array[Vector3] = []
	face_n.resize(tris.size())
	for ti in tris.size():
		var f := tris[ti]
		var v0 := verts[f.x]
		var v1 := verts[f.y]
		var v2 := verts[f.z]
		var fn := (v2 - v0).cross(v1 - v0)
		var cavg := (v0 + v1 + v2)
		if fn.dot(cavg) < 0.0:
			tris[ti] = Vector3i(f.x, f.z, f.y)
			fn = -fn
		fn = fn.normalized()
		face_n[ti] = fn
		var tf := tris[ti]
		smooth_n[tf.x] += fn
		smooth_n[tf.y] += fn
		smooth_n[tf.z] += fn
	for i in smooth_n.size():
		smooth_n[i] = smooth_n[i].normalized() if smooth_n[i].length_squared() > 1e-8 else Vector3.UP

	var pv := PackedVector3Array()
	var pn := PackedVector3Array()
	var pc := PackedFloat32Array()
	var idx := PackedInt32Array()
	for ti in tris.size():
		var f := tris[ti]
		var fn := face_n[ti]
		var base := pv.size()
		for vi: int in [f.x, f.y, f.z]:
			pv.append(verts[vi])
			pn.append((fn * 0.68 + smooth_n[vi] * 0.32).normalized())
			var a := cav[vi]
			pc.append_array([a, a, a, 1.0])
		idx.append_array([base, base + 1, base + 2])

	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = pv
	arrays[Mesh.ARRAY_NORMAL] = pn
	arrays[Mesh.ARRAY_CUSTOM0] = pc
	arrays[Mesh.ARRAY_INDEX] = idx
	var m := ArrayMesh.new()
	m.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays, [], {}, Mesh.ARRAY_CUSTOM_RGBA_FLOAT << Mesh.ARRAY_FORMAT_CUSTOM0_SHIFT)
	return m


# ---------- 2. Scenic Benches (1 SwapMultiMesh) ----------
func _build_benches() -> void:
	var pinfo: Dictionary = world.props_info()
	if not pinfo.has("benches"):
		return
	var blist: Array = pinfo.benches
	if blist.is_empty():
		return
	var mb := _MB.new()
	var wood := Color(0.42, 0.27, 0.15)
	var leg := Color(0.28, 0.17, 0.10)
	for k in 3:
		mb.box(Vector3(1.9, 0.06, 0.14), Vector3(0.0, 0.46, -0.16 + float(k) * 0.16), Vector3.ZERO, wood, 1.0)
	mb.box(Vector3(1.9, 0.14, 0.05), Vector3(0.0, 0.75, -0.27), Vector3.ZERO, wood, 1.0)
	mb.box(Vector3(1.9, 0.14, 0.05), Vector3(0.0, 0.95, -0.29), Vector3.ZERO, wood, 1.0)
	for sx in [-0.8, 0.8]:
		# Legs extend 0.18 m below y=0 so benches never float on uneven slopes.
		mb.box(Vector3(0.10, 0.66, 0.10), Vector3(sx, 0.15, -0.15), Vector3.ZERO, leg, 0.85)
		mb.box(Vector3(0.10, 0.66, 0.10), Vector3(sx, 0.15, 0.17), Vector3.ZERO, leg, 0.85)
		mb.box(Vector3(0.08, 0.60, 0.08), Vector3(sx, 0.75, -0.30), Vector3.ZERO, leg, 0.92)
		mb.box(Vector3(0.10, 0.08, 0.50), Vector3(sx, 0.40, 0.0), Vector3.ZERO, leg, 0.90)
	var mesh := mb.finish(prop_mat)
	_bench_tris = mb.tri_count

	for b in blist:
		var bx := float(b.x)
		var by := float(b.baseY)
		var bz := float(b.z)
		var ry := float(b.ry)
		var basis := Basis.from_euler(Vector3(0.0, ry, 0.0))
		_bench_list.append([
			bx, by, bz,
			basis.x.x, basis.y.x, basis.z.x,
			basis.x.y, basis.y.y, basis.z.y,
			basis.x.z, basis.y.z, basis.z.z,
		])
		benches.append({"kind": "bench", "x": bx, "y": float(b.y), "z": bz, "ry": ry})

	var cap := maxi(1, _bench_list.size())
	_bench_buf.resize(cap * 16)
	var big_box := AABB(Vector3(-2000.0, -100.0, -2000.0), Vector3(4000.0, 1200.0, 4000.0))
	_bench_swap = SwapMultiMesh.new(self, mesh, cap, big_box)


func _cull_benches(cp: Vector3) -> void:
	if _bench_swap == null or _bench_list.is_empty():
		return
	var vis := 0
	var aabb := AABB()
	var has_box := false
	var max_d := BENCH_DIST * _dist_scale + CULL_PAD
	var max_d2 := max_d * max_d
	for e in _bench_list:
		var ex := float(e[0])
		var ey := float(e[1])
		var ez := float(e[2])
		var dx := ex - cp.x
		var dy := ey - cp.y
		var dz := ez - cp.z
		if dx * dx + dy * dy + dz * dz > max_d2:
			continue
		var o := vis * 16
		_bench_buf[o + 0] = float(e[3]); _bench_buf[o + 1] = float(e[4]); _bench_buf[o + 2] = float(e[5]); _bench_buf[o + 3] = ex
		_bench_buf[o + 4] = float(e[6]); _bench_buf[o + 5] = float(e[7]); _bench_buf[o + 6] = float(e[8]); _bench_buf[o + 7] = ey
		_bench_buf[o + 8] = float(e[9]); _bench_buf[o + 9] = float(e[10]); _bench_buf[o + 10] = float(e[11]); _bench_buf[o + 11] = ez
		_bench_buf[o + 12] = 0.0; _bench_buf[o + 13] = 0.0; _bench_buf[o + 14] = 0.0; _bench_buf[o + 15] = 0.0
		var b := AABB(Vector3(ex - 1.4, ey - 0.5, ez - 1.4), Vector3(2.8, 2.0, 2.8))
		aabb = b if not has_box else aabb.merge(b)
		has_box = true
		vis += 1
	_bench_vis = vis
	_bench_aabb = aabb
	if vis > 0:
		_bench_swap.push(_bench_buf, vis)
		_bench_swap.set_visible(_on)
		for mmi: MultiMeshInstance3D in _bench_swap.mmis:
			mmi.custom_aabb = aabb
	else:
		_bench_swap.set_visible(false)


# ---------- 3. Storybook Cottage, Yard, Flagstones & Bushes (1 opaque draw call) ----------
var _cottage_glows: Array[Vector3] = []
var _cottage_lantern := Vector3.ZERO


func _build_cottage_and_yard() -> void:
	var pinfo: Dictionary = world.props_info()
	if not pinfo.has("house"):
		return
	var H: Dictionary = pinfo.house
	var hx := float(H.x)
	var hy := float(H.y)
	var hz := float(H.z)
	var hry := float(H.ry)
	var hscale := float(H.scale)
	var house_xf := Transform3D(Basis.from_euler(Vector3(0.0, hry, 0.0)).scaled(Vector3.ONE * hscale), Vector3(hx, hy, hz))

	var rng := RandomNumberGenerator.new()
	rng.seed = 7
	var vary := func(c: Color, k: float = 0.12) -> Color:
		var f := 1.0 - k * 0.5 + rng.randf() * k
		return Color(c.r * f, c.g * f, c.b * f, 1.0)

	# Palette matching cottage.js with crisp warm accents against the green valley.
	var STONE := Color(0.62, 0.56, 0.49)
	var STONE_D := Color(0.43, 0.39, 0.35)
	var PLASTER := Color(0.96, 0.85, 0.62)
	var BEAM := Color(0.28, 0.17, 0.10)
	var WOOD := Color(0.46, 0.30, 0.17)
	var SHUTTER := Color(0.16, 0.46, 0.54)
	var DOOR := Color(0.40, 0.22, 0.12)
	var TILE0 := Color(0.23, 0.35, 0.60)
	var TILE1 := Color(0.29, 0.43, 0.68)
	var TILE2 := Color(0.19, 0.30, 0.52)
	var IRON := Color(0.12, 0.12, 0.13)
	var FLOWERS: Array[Color] = [Color(0.92, 0.22, 0.18), Color(0.96, 0.78, 0.20), Color(0.90, 0.48, 0.68), Color(0.96, 0.95, 0.90)]

	var mb := _MB.new()
	mb.xf = house_xf

	const W := 10.0
	const D := 7.5
	const g0 := 0.6
	const H1 := 3.4
	const H2 := 2.9
	const y1 := g0 + H1
	const y2 := y1 + H2

	# Deep stone plinth (sinks 2.2 m into hillside so foundation never floats) & ground floor.
	mb.box(Vector3(W + 0.9, 2.8, D + 0.9), Vector3(0.0, g0 - 1.3, 0.0), Vector3.ZERO, STONE_D, 0.86)
	mb.box(Vector3(W, H1, D), Vector3(0.0, g0 + H1 * 0.5, 0.0), Vector3.ZERO, STONE, 0.96)
	# Selected chunky masonry stones on walls (streamlined for mobile tris while keeping rich cobbled relief).
	for _i in 64:
		var side := rng.randi() % 4
		var sw := 0.44 + rng.randf() * 0.46
		var sh := 0.24 + rng.randf() * 0.18
		var sy := g0 + 0.20 + rng.randf() * (H1 - 0.45)
		var sc: Color = vary.call(STONE_D if rng.randf() < 0.38 else STONE, 0.24)
		if side < 2:
			var sz := (1.0 if side == 1 else -1.0) * (D * 0.5 + 0.04)
			var sx := (rng.randf() - 0.5) * (W - 0.8)
			if side == 1 and absf(sx) < 1.15 and sy < g0 + 2.75:
				continue
			mb.box(Vector3(sw, sh, 0.10), Vector3(sx, sy, sz), Vector3.ZERO, sc, 0.95)
		else:
			var sx := (1.0 if side == 2 else -1.0) * (W * 0.5 + 0.04)
			mb.box(Vector3(0.10, sh, sw), Vector3(sx, sy, (rng.randf() - 0.5) * (D - 0.8)), Vector3.ZERO, sc, 0.95)
	# Chunky stone corner quoins.
	for sx in [-1.0, 1.0]:
		for sz in [-1.0, 1.0]:
			for k in 6:
				var big := (k % 2) == 0
				mb.box(Vector3(0.75 if big else 0.48, 0.44, 0.48 if big else 0.75),
					Vector3(sx * (W * 0.5 - 0.14), g0 + 0.30 + float(k) * 0.55, sz * (D * 0.5 - 0.14)),
					Vector3.ZERO, vary.call(Color(0.70, 0.66, 0.60), 0.12), 0.96)

	# Jettied upper storey, timber corbels & half-timber framing.
	const W2 := W + 0.7
	const D2 := D + 0.7
	mb.box(Vector3(W2 + 0.24, 0.34, D2 + 0.24), Vector3(0.0, y1 + 0.05, 0.0), Vector3.ZERO, BEAM, 0.88)
	for x in [-4.2, -1.8, 1.8, 4.2]:
		mb.box(Vector3(0.26, 0.55, 0.42), Vector3(x, y1 - 0.25, D * 0.5 + 0.18), Vector3(-0.35, 0.0, 0.0), BEAM, 0.85)
	mb.box(Vector3(W2, H2, D2), Vector3(0.0, y1 + H2 * 0.5 + 0.1, 0.0), Vector3.ZERO, PLASTER, 1.0)
	for z: float in [-D2 * 0.5 - 0.04, D2 * 0.5 + 0.04]:
		for x: float in [-W2 * 0.5, -W2 * 0.25, 0.0, W2 * 0.25, W2 * 0.5]:
			mb.box(Vector3(0.28, H2, 0.14), Vector3(x, y1 + H2 * 0.5 + 0.1, z), Vector3(0.0, 0.0, (rng.randf() - 0.5) * 0.018), BEAM, 0.94)
		mb.box(Vector3(W2 + 0.1, 0.24, 0.14), Vector3(0.0, y2 + 0.05, z), Vector3.ZERO, BEAM, 0.92)
		mb.box(Vector3(W2 + 0.1, 0.18, 0.14), Vector3(0.0, y1 + 1.0, z), Vector3.ZERO, BEAM, 0.94)
		for s: float in [-1.0, 1.0]:
			for k in 2:
				var off_x := s * (W2 * (0.125 if k == 1 else 0.375))
				mb.box(Vector3(0.18, 1.95, 0.12), Vector3(off_x, y1 + 1.6, z), Vector3(0.0, 0.0, s * (-0.6 if k == 1 else 0.6)), BEAM, 0.94)
	for x: float in [-W2 * 0.5 - 0.04, W2 * 0.5 + 0.04]:
		for z: float in [-D2 * 0.5, 0.0, D2 * 0.5]:
			mb.box(Vector3(0.14, H2, 0.28), Vector3(x, y1 + H2 * 0.5 + 0.1, z), Vector3.ZERO, BEAM, 0.94)
		mb.box(Vector3(0.14, 0.24, D2 + 0.1), Vector3(x, y2 + 0.05, 0.0), Vector3.ZERO, BEAM, 0.92)

	# Windows with teal shutters, mullions, flower boxes & dusk glow anchors.
	var add_window := func(wx: float, wy: float, wz: float, is_x: bool, ww: float, wh: float, shutters: bool, flowers: bool, add_glow: bool) -> void:
		var n := signf(wx) if is_x else signf(wz)
		var gpos := Vector3(wx + n * 0.02, wy, wz) if is_x else Vector3(wx, wy, wz + n * 0.02)
		mb.box(Vector3(0.06, wh, ww) if is_x else Vector3(ww, wh, 0.06), gpos, Vector3.ZERO, Color.WHITE, 1.0, 1.0)
		if add_glow:
			var gp := Vector3(wx + n * 0.45, wy, wz) if is_x else Vector3(wx, wy, wz + n * 0.45)
			_cottage_glows.append(house_xf * gp)
		var foff := 0.09
		var add_fr := func(fw: float, fh: float, dx: float, dy: float) -> void:
			if is_x:
				mb.box(Vector3(0.14, fh, fw), Vector3(wx + n * foff, wy + dy, wz + dx), Vector3.ZERO, BEAM, 0.95)
			else:
				mb.box(Vector3(fw, fh, 0.14), Vector3(wx + dx, wy + dy, wz + n * foff), Vector3.ZERO, BEAM, 0.95)
		add_fr.call(ww + 0.34, 0.18, 0.0, wh * 0.5 + 0.08)
		add_fr.call(ww + 0.44, 0.20, 0.0, -wh * 0.5 - 0.08)
		add_fr.call(0.14, wh, -ww * 0.5 - 0.06, 0.0)
		add_fr.call(0.14, wh, ww * 0.5 + 0.06, 0.0)
		add_fr.call(0.08, wh, 0.0, 0.0)
		add_fr.call(ww, 0.07, 0.0, 0.0)
		if shutters:
			for s: float in [-1.0, 1.0]:
				var lat := s * (ww * 0.5 + 0.38)
				if is_x:
					mb.box(Vector3(0.08, wh + 0.12, 0.64), Vector3(wx + n * 0.24, wy, wz + lat), Vector3(0.0, s * 0.42 * n, 0.0), SHUTTER, 0.98)
				else:
					mb.box(Vector3(0.64, wh + 0.12, 0.08), Vector3(wx + lat, wy, wz + n * 0.24), Vector3(0.0, s * 0.42 * n, 0.0), SHUTTER, 0.98)
		if flowers:
			if is_x:
				mb.box(Vector3(0.36, 0.30, ww + 0.24), Vector3(wx + n * 0.32, wy - wh * 0.5 - 0.30, wz), Vector3.ZERO, WOOD, 0.92)
			else:
				mb.box(Vector3(ww + 0.24, 0.30, 0.36), Vector3(wx, wy - wh * 0.5 - 0.30, wz + n * 0.32), Vector3.ZERO, WOOD, 0.92)
			for k in 5:
				var ft := (float(k) / 4.0 - 0.5) * (ww + 0.02)
				var fp := Vector3(wx + n * 0.35, wy - wh * 0.5 - 0.12, wz + ft) if is_x else Vector3(wx + ft, wy - wh * 0.5 - 0.12, wz + n * 0.35)
				mb.ico(fp, Vector3(0.18, 0.11, 0.15), Color(0.11, 0.36, 0.08), 0.96)
				if k % 2 == 0:
					mb.ico(fp + Vector3(0.0, 0.09, 0.0), Vector3(0.09, 0.07, 0.09), FLOWERS[k % FLOWERS.size()], 1.0)

	add_window.call(-2.8, g0 + 1.9, D * 0.5 + 0.05, false, 1.15, 1.25, true, true, true)
	add_window.call(2.8, g0 + 1.9, D * 0.5 + 0.05, false, 1.15, 1.25, true, true, true)
	add_window.call(-3.2, y1 + 1.5, D2 * 0.5 + 0.05, false, 1.05, 1.15, true, true, true)
	add_window.call(0.0, y1 + 1.5, D2 * 0.5 + 0.05, false, 0.92, 1.15, false, false, true)
	add_window.call(3.2, y1 + 1.5, D2 * 0.5 + 0.05, false, 1.05, 1.15, true, true, true)
	add_window.call(W * 0.5 + 0.05, g0 + 1.9, 0.0, true, 1.1, 1.2, true, true, true)
	add_window.call(W2 * 0.5 + 0.05, y1 + 1.5, -1.2, true, 1.0, 1.1, true, false, false)
	add_window.call(-W * 0.5 - 0.05, g0 + 1.9, 1.5, true, 1.0, 1.1, true, true, false)
	add_window.call(-2.8, g0 + 1.9, -D * 0.5 - 0.05, false, 1.0, 1.1, false, false, false)

	# Arched front door, timber awning, steps & hanging wooden inn sign.
	const dz := D * 0.5 + 0.06
	mb.box(Vector3(1.55, 2.35, 0.18), Vector3(0.0, g0 + 1.17, dz), Vector3.ZERO, DOOR, 0.94)
	mb.cyl(0.77, 0.77, 0.18, 10, Vector3(0.0, g0 + 2.35, dz), Vector3(PI * 0.5, 0.0, 0.0), DOOR, 0.94)
	for x in [-0.42, 0.0, 0.42]:
		mb.box(Vector3(0.06, 2.25, 0.05), Vector3(x, g0 + 1.15, dz + 0.10), Vector3.ZERO, Color(0.28, 0.15, 0.08), 0.92)
	for y in [0.5, 1.75]:
		mb.box(Vector3(1.35, 0.11, 0.05), Vector3(0.0, g0 + y, dz + 0.12), Vector3.ZERO, IRON, 0.95)
	mb.box(Vector3(0.11, 0.11, 0.13), Vector3(0.52, g0 + 1.15, dz + 0.17), Vector3.ZERO, Color(0.85, 0.68, 0.25), 1.0)
	mb.box(Vector3(2.75, 0.14, 1.50), Vector3(0.0, g0 + 3.05, dz + 0.62), Vector3(0.45, 0.0, 0.0), TILE0, 0.96)
	for s in [-1.0, 1.0]:
		mb.box(Vector3(0.14, 0.95, 0.14), Vector3(s * 1.22, g0 + 2.60, dz + 0.55), Vector3.ZERO, BEAM, 0.92)
	mb.box(Vector3(2.3, 0.55, 1.25), Vector3(0.0, g0 - 0.18, dz + 0.72), Vector3.ZERO, STONE_D, 0.90)
	mb.box(Vector3(1.7, 0.55, 0.85), Vector3(0.0, g0 - 0.42, dz + 1.35), Vector3.ZERO, STONE_D, 0.90)
	mb.box(Vector3(0.08, 0.08, 1.05), Vector3(1.6, g0 + 3.12, dz + 0.50), Vector3.ZERO, IRON, 0.95)
	mb.box(Vector3(0.92, 0.62, 0.06), Vector3(1.6, g0 + 2.72, dz + 0.92), Vector3.ZERO, Color(0.55, 0.36, 0.20), 0.98)

	# Steep storybook blue-slate roof with organic ridge sag, wood soffit, chunky bargeboards & eave moss.
	const rh := 4.9
	const eave := 0.95
	const over := 0.56
	const hd := D2 * 0.5 + eave
	var slope := atan2(rh, hd)
	var slen := sqrt(rh * rh + hd * hd)
	const RW := W2 + over * 2.0
	const rows := 7
	const cols := 6
	for s: float in [-1.0, 1.0]:
		# Solid warm-wood soffit tucked under tiles.
		mb.box(Vector3(RW - 0.08, 0.16, slen + 0.16), Vector3(0.0, y2 + rh * 0.5 - 0.34, s * hd * 0.5), Vector3(s * slope, 0.0, 0.0), WOOD, 0.86)
		for r in rows:
			var f := (float(r) + 0.5) / float(rows)
			var zc := s * (hd - f * hd)
			var yc := y2 + 0.12 + f * rh
			var xw := RW / float(cols)
			for c in cols:
				var xc := -RW * 0.5 + (float(c) + 0.5) * xw + (xw * 0.14 if (r % 2) == 1 else -xw * 0.14)
				var x0 := maxf(-RW * 0.5 + 0.06, xc - xw * 0.51)
				var x1 := minf(RW * 0.5 - 0.06, xc + xw * 0.51)
				var cxm := (x0 + x1) * 0.5
				var sag := -0.26 * cos((cxm / RW) * PI) * (0.35 + 0.65 * f) + 0.14 * pow(maxf(1.0 - f, 0.0), 2.2)
				var tcol: Color = vary.call(TILE0 if (r % 2) == 1 else TILE1, 0.10)
				mb.box(Vector3(x1 - x0, 0.22, slen / float(rows) * 1.24), Vector3(cxm, yc + sag, zc), Vector3(s * slope, 0.0, 0.0), tcol, 0.98)
				# Clustered velvety moss cushions seated cleanly on top of shaded lower eave tiles.
				if r <= 1 and (c <= 2 or rng.randf() < 0.25) and rng.randf() < 0.45:
					var roof_n := Vector3(0.0, cos(slope), s * sin(slope))
					var base_p := Vector3(cxm, yc + sag, zc) + roof_n * 0.14
					for _mb in 2:
						var oxm := (rng.randf() - 0.5) * 0.58
						var ozm := (rng.randf() - 0.5) * 0.22
						mb.ico(base_p + Vector3(oxm, -s * ozm * sin(slope), ozm),
							Vector3(0.32, 0.11, 0.26), vary.call(Color(0.11, 0.29, 0.068), 0.20), 0.98)
		for sx: float in [-1.0, 1.0]:
			mb.box(Vector3(0.28, 0.44, slen + 0.45), Vector3(sx * (RW * 0.5 + 0.06), y2 + rh * 0.5 + 0.12, s * hd * 0.5), Vector3(s * slope, 0.0, 0.0), BEAM, 0.92)
	for s: float in [-1.0, 1.0]:
		mb.box(Vector3(RW + 0.25, 0.46, 0.24), Vector3(0.0, y2 - 0.18, s * (hd + 0.05)), Vector3.ZERO, BEAM, 0.88)
	for i in 6:
		var xm := ((float(i) + 0.5) / 6.0 - 0.5) * (RW + 0.35)
		var sag := -0.26 * cos((xm / RW) * PI)
		mb.box(Vector3((RW + 0.45) / 6.0 + 0.08, 0.38, 0.58), Vector3(xm, y2 + rh + 0.18 + sag, 0.0), Vector3.ZERO, Color(0.18, 0.26, 0.44), 0.96)

	# Solid plaster gables, half-timber trusses & attic windows.
	for x: float in [-W2 * 0.5, W2 * 0.5]:
		var ghz := D2 * 0.5 + 0.05
		var nsign := signf(x)
		mb.tri_double(
			Vector3(x, y2 + 0.06, -ghz), Vector3(x, y2 + 0.06, ghz), Vector3(x, y2 + rh + 0.08, 0.0),
			Vector3(nsign, 0.0, 0.0), PLASTER, 1.0)
		var sx := x + nsign * 0.05
		mb.box(Vector3(0.14, rh * 0.88, 0.24), Vector3(sx, y2 + rh * 0.44, 0.0), Vector3.ZERO, BEAM, 0.94)
		mb.box(Vector3(0.14, 0.22, D2 * 0.68), Vector3(sx, y2 + rh * 0.36, 0.0), Vector3.ZERO, BEAM, 0.94)
		for s: float in [-1.0, 1.0]:
			mb.box(Vector3(0.12, 2.35, 0.18), Vector3(sx, y2 + rh * 0.26, s * D2 * 0.22), Vector3(s * 0.55, 0.0, 0.0), BEAM, 0.94)
		add_window.call(sx + nsign * 0.02, y2 + 1.45, 0.0, true, 0.72, 0.82, false, false, false)

	# Cozy front dormer.
	var dx := -2.2
	var dzz := hd * 0.45
	var dy := y2 + rh * 0.54
	mb.box(Vector3(1.85, 1.65, 1.85), Vector3(dx, dy + 0.30, dzz + 0.30), Vector3.ZERO, PLASTER, 0.98)
	mb.box(Vector3(1.98, 0.14, 1.98), Vector3(dx, dy + 1.15, dzz + 0.30), Vector3.ZERO, BEAM, 0.94)
	for s in [-1.0, 1.0]:
		mb.box(Vector3(1.32, 0.14, 2.28), Vector3(dx + s * 0.56, dy + 1.52, dzz + 0.40), Vector3(0.0, 0.0, -s * 0.75), TILE1, 0.98)
	add_window.call(dx, dy + 0.40, dzz + 1.28, false, 0.82, 0.82, false, false, true)

	# Cobbled stone chimney.
	mb.box(Vector3(1.3, 6.6, 1.3), Vector3(3.0, y2 + 2.6, -1.6), Vector3.ZERO, STONE, 0.96)
	mb.box(Vector3(1.55, 0.28, 1.55), Vector3(3.0, y2 + 5.95, -1.6), Vector3.ZERO, STONE_D, 0.92)
	mb.box(Vector3(0.55, 0.52, 0.55), Vector3(3.0, y2 + 6.30, -1.6), Vector3.ZERO, Color(0.24, 0.21, 0.19), 0.90)

	# Woodshed lean-to, firewood stack & chopping stump.
	mb.box(Vector3(2.7, 0.15, D - 0.4), Vector3(-W * 0.5 - 1.35, 2.85, 0.0), Vector3(0.0, 0.0, 0.35), TILE2, 0.94)
	for z in [-D * 0.5 + 0.6, D * 0.5 - 0.6]:
		mb.box(Vector3(0.20, 4.2, 0.20), Vector3(-W * 0.5 - 2.45, 0.35, z), Vector3.ZERO, BEAM, 0.90)
	mb.box(Vector3(1.25, 1.45, 3.6), Vector3(-W * 0.5 - 0.95, 0.80, 0.0), Vector3.ZERO, Color(0.58, 0.41, 0.24), 0.88)
	mb.cyl(0.32, 0.38, 1.6, 8, Vector3(-W * 0.5 - 1.8, -0.22, D * 0.5 + 1.2), Vector3.ZERO, Color(0.42, 0.28, 0.16), 0.92)
	mb.cyl(0.30, 0.30, 0.05, 8, Vector3(-W * 0.5 - 1.8, 0.59, D * 0.5 + 1.2), Vector3.ZERO, Color(0.76, 0.62, 0.42), 1.0)

	# Cozy stone wishing well to the right of the cottage (deep stone foundation into slope).
	var well_x := W * 0.5 + 3.4
	var well_z := D * 0.5 - 0.6
	mb.cyl(0.95, 1.08, 2.6, 10, Vector3(well_x, -0.36, well_z), Vector3.ZERO, STONE, 0.94)
	mb.cyl(1.06, 1.06, 0.16, 10, Vector3(well_x, 0.96, well_z), Vector3.ZERO, STONE_D, 0.95)
	mb.cyl(0.75, 0.75, 0.05, 8, Vector3(well_x, 0.84, well_z), Vector3.ZERO, Color(0.08, 0.22, 0.30), 0.90)
	for s in [-1.0, 1.0]:
		mb.box(Vector3(0.14, 1.62, 0.14), Vector3(well_x + s * 0.85, 1.72, well_z), Vector3.ZERO, BEAM, 0.94)
	mb.cyl(0.06, 0.06, 1.8, 6, Vector3(well_x, 1.84, well_z), Vector3(0.0, 0.0, PI * 0.5), WOOD, 0.95)
	mb.cyl(0.18, 0.14, 0.30, 8, Vector3(well_x, 1.38, well_z), Vector3.ZERO, Color(0.48, 0.30, 0.16), 0.94)
	for s in [-1.0, 1.0]:
		mb.box(Vector3(2.35, 0.12, 1.26), Vector3(well_x, 2.74, well_z + s * 0.46), Vector3(s * 0.68, 0.0, 0.0), TILE0, 0.98)
	mb.box(Vector3(2.42, 0.16, 0.22), Vector3(well_x, 3.12, well_z), Vector3.ZERO, BEAM, 0.96)

	# Sunny terraced garden bed beside front-left corner (deep retaining wall into slope) with pumpkins & sunflowers.
	var gx := -W * 0.5 - 1.55
	var gz := D * 0.5 + 2.35
	mb.box(Vector3(3.35, 2.45, 2.15), Vector3(gx, -1.10, gz), Vector3.ZERO, STONE_D, 0.88)
	mb.box(Vector3(3.16, 0.22, 1.96), Vector3(gx, 0.12, gz), Vector3.ZERO, Color(0.24, 0.16, 0.10), 0.92)
	mb.box(Vector3(3.38, 0.22, 0.14), Vector3(gx, 0.18, gz + 1.0), Vector3.ZERO, WOOD, 0.96)
	mb.box(Vector3(3.38, 0.22, 0.14), Vector3(gx, 0.18, gz - 1.0), Vector3.ZERO, WOOD, 0.96)
	mb.box(Vector3(0.14, 0.22, 2.12), Vector3(gx - 1.62, 0.18, gz), Vector3.ZERO, WOOD, 0.96)
	mb.box(Vector3(0.14, 0.22, 2.12), Vector3(gx + 1.62, 0.18, gz), Vector3.ZERO, WOOD, 0.96)
	for pm in [[-0.88, 0.35, 0.32], [-0.18, 0.48, 0.26], [0.62, 0.32, 0.35]]:
		var pr := float(pm[2])
		mb.ico(Vector3(gx + float(pm[0]), 0.24 + pr * 0.62, gz + float(pm[1])), Vector3(pr * 1.15, pr * 0.78, pr * 1.15), Color(0.92, 0.42, 0.08), 1.0)
	for sf in [[-1.08, -0.42, 1.38, -0.09], [-0.36, -0.52, 1.72, 0.06], [0.34, -0.45, 1.54, -0.05], [0.98, -0.50, 1.24, 0.10]]:
		var sfx := gx + float(sf[0])
		var sfz := gz + float(sf[1])
		var sfh := float(sf[2])
		var sft := float(sf[3])
		mb.cyl(0.04, 0.055, sfh, 6, Vector3(sfx + sft * sfh * 0.3, 0.22 + sfh * 0.5, sfz), Vector3(0.0, 0.0, -sft), Color(0.16, 0.42, 0.10), 0.96)
		mb.cyl(0.24, 0.24, 0.07, 8, Vector3(sfx + sft * sfh * 0.65, 0.22 + sfh, sfz + 0.05), Vector3(PI * 0.5 - 0.30, sft * 2.0, 0.0), Color(0.98, 0.78, 0.08), 1.0)
		mb.cyl(0.11, 0.11, 0.09, 6, Vector3(sfx + sft * sfh * 0.65, 0.22 + sfh, sfz + 0.07), Vector3(PI * 0.5 - 0.30, sft * 2.0, 0.0), Color(0.22, 0.14, 0.07), 0.95)

	# Barrels, crates, cottage front bench & porch lantern post.
	for bp in [[3.9, D * 0.5 + 1.0], [4.7, D * 0.5 + 0.6]]:
		mb.cyl(0.38, 0.38, 1.15, 8, Vector3(float(bp[0]), 0.38, float(bp[1])), Vector3.ZERO, Color(0.50, 0.32, 0.18), 0.94)
		for y in [0.18, 0.78]:
			mb.cyl(0.41, 0.41, 0.07, 8, Vector3(float(bp[0]), y, float(bp[1])), Vector3.ZERO, IRON, 0.95)
	for cr in [[-4.0, D * 0.5 + 0.9, 0.80, 0.2], [-4.2, D * 0.5 + 1.9, 0.60, -0.3], [-4.1, D * 0.5 + 0.95, 0.55, 0.5]]:
		var cs := float(cr[2])
		var cy := 1.08 if absf(float(cr[0]) + 4.1) < 0.01 else cs * 0.5
		mb.box(Vector3(cs, cs, cs), Vector3(float(cr[0]), cy, float(cr[1])), Vector3(0.0, float(cr[3]), 0.0), Color(0.62, 0.45, 0.26), 0.95)
	mb.box(Vector3(2.0, 0.10, 0.45), Vector3(1.9, 0.55, D * 0.5 + 0.75), Vector3.ZERO, WOOD, 0.96)
	for x in [1.1, 2.7]:
		mb.box(Vector3(0.10, 0.75, 0.40), Vector3(x, 0.18, D * 0.5 + 0.75), Vector3.ZERO, BEAM, 0.90)

	# Porch lantern post.
	var lp := Vector3(3.6, 0.0, D * 0.5 + 1.8)
	mb.box(Vector3(0.18, 3.1, 0.18), Vector3(lp.x, 1.10, lp.z), Vector3.ZERO, BEAM, 0.94)
	mb.box(Vector3(0.75, 0.11, 0.11), Vector3(lp.x + 0.32, 2.52, lp.z), Vector3.ZERO, BEAM, 0.95)
	mb.box(Vector3(0.36, 0.09, 0.36), Vector3(lp.x + 0.62, 2.40, lp.z), Vector3.ZERO, IRON, 0.95)
	mb.box(Vector3(0.38, 0.09, 0.38), Vector3(lp.x + 0.62, 1.98, lp.z), Vector3.ZERO, IRON, 0.95)
	mb.box(Vector3(0.28, 0.38, 0.28), Vector3(lp.x + 0.62, 2.19, lp.z), Vector3.ZERO, Color.WHITE, 1.0, 1.0)
	_cottage_lantern = house_xf * Vector3(lp.x + 0.62, 2.19, lp.z)
	_cottage_glows.append(_cottage_lantern)

	# Switch to world-space coordinates for flagstones & foundation bushes (merged into same draw call).
	mb.xf = Transform3D.IDENTITY
	if pinfo.has("flagstones"):
		for fs in pinfo.flagstones:
			var tone := float(fs[5])
			mb.cyl(float(fs[3]), float(fs[3]) * 1.08, 0.18, 7,
				Vector3(float(fs[0]), float(fs[1]), float(fs[2])),
				Vector3(0.0, float(fs[4]), 0.0), Color(tone, tone * 0.95, tone * 0.88), 0.96)
	if pinfo.has("cottageBushes"):
		var bush_rng := RandomNumberGenerator.new()
		bush_rng.seed = 97
		for cb in pinfo.cottageBushes:
			var bp := Vector3(float(cb[0]), float(cb[1]), float(cb[2]))
			var bs := float(cb[3])
			var bcol := Color(0.11 + bush_rng.randf() * 0.05, 0.33 + bush_rng.randf() * 0.08, 0.065 + bush_rng.randf() * 0.025)
			mb.ico(bp + Vector3(0.0, bs * 0.42, 0.0), Vector3(bs * 0.88, bs * 0.62, bs * 0.88), bcol, 0.95)
			mb.ico(bp + Vector3(bs * 0.38, bs * 0.34, bs * 0.22), Vector3(bs * 0.62, bs * 0.48, bs * 0.62), bcol * Color(1.08, 1.06, 0.92), 0.98)
			mb.ico(bp + Vector3(-bs * 0.32, bs * 0.36, -bs * 0.26), Vector3(bs * 0.58, bs * 0.46, bs * 0.58), bcol * Color(0.88, 0.96, 1.04), 0.94)

	_add_static_mesh("cottage", mb.finish(prop_mat), mb.aabb, mb.tri_count, 1800.0)


# ---------- 4. Trailhead Signpost (1 opaque draw call, crisp 3-board lettering) ----------
func _build_signpost() -> void:
	var pinfo: Dictionary = world.props_info()
	if not pinfo.has("signpost") or pinfo.signpost == null:
		return
	var S: Dictionary = pinfo.signpost
	var xf := Transform3D(Basis.from_euler(Vector3(0.0, float(S.ry), 0.0)), Vector3(float(S.x), float(S.y), float(S.z)))
	var mb := _MB.new()
	mb.xf = xf
	var wood := Color(0.42, 0.28, 0.16)
	# Post & weather cap use UV.x = 2.0 -> weathered wood branch in signpost_painted.gdshader.
	mb.box(Vector3(0.18, 3.0, 0.18), Vector3(0.0, 1.30, 0.0), Vector3.ZERO, wood, 1.0, 2.0)
	mb.box(Vector3(0.26, 0.08, 0.26), Vector3(0.0, 2.82, 0.0), Vector3.ZERO, wood, 1.0, 2.0)
	# 3 fanned cedar lettering boards (matching props.js lines 330-346).
	for i in 3:
		var side := 1.0 if (i % 2) == 0 else -1.0
		var pos := Vector3(0.80 * side, 2.38 - float(i) * 0.50, 0.0)
		var rot := Vector3(0.0, (float(i) - 1.0) * 0.11, 0.0)
		var v0 := float(i) / 3.0 + 0.004
		var v1 := float(i + 1) / 3.0 - 0.004
		mb.sign_board(Vector3(1.78, 0.44, 0.06), pos, rot, v0, v1, Color(0.46, 0.30, 0.17))
	_add_static_mesh("signpost", mb.finish(sign_mat), mb.aabb, mb.tri_count, 160.0)


# ---------- 5. Village Fences & Trail Lantern Posts (1 opaque draw call) ----------
func _build_fences_and_lanterns() -> void:
	var pinfo: Dictionary = world.props_info()
	var mb := _MB.new()
	var rng := RandomNumberGenerator.new()
	rng.seed = 31
	var WOOD := Color(0.38, 0.24, 0.14)
	var WOOD_LOW := Color(0.33, 0.21, 0.13)
	var WOOD_D := Color(0.22, 0.14, 0.09)
	var IRON := Color(0.12, 0.12, 0.13)

	if pinfo.has("fences"):
		for seg in pinfo.fences:
			for i in seg.size():
				var p := Vector3(float(seg[i][0]), float(seg[i][1]), float(seg[i][2]))
				var tilt := (rng.randf() - 0.5) * 0.08
				mb.box(Vector3(0.14, 1.38, 0.14), p + Vector3(0.0, 0.39, 0.0), Vector3(tilt, rng.randf() * 3.0, tilt), WOOD, 0.94)
				if i > 0:
					var prev := Vector3(float(seg[i - 1][0]), float(seg[i - 1][1]), float(seg[i - 1][2]))
					var diff := p - prev
					var seg_len := diff.length()
					var horiz := Vector2(diff.x, diff.z).length()
					if seg_len > 0.1 and horiz > 0.05:
						var yaw := -atan2(diff.z, diff.x)
						var slope_z := atan2(diff.y, horiz)
						for hgt: float in [0.48, 0.90]:
							var mid := (p + prev) * 0.5 + Vector3(0.0, hgt + (rng.randf() - 0.5) * 0.03, 0.0)
							mb.box_yz(Vector3(seg_len + 0.18, 0.09, 0.07), mid, yaw, slope_z, WOOD if hgt > 0.6 else WOOD_LOW, 0.96)

	if pinfo.has("lanterns"):
		for L in pinfo.lanterns:
			var x := float(L[0])
			var y := float(L[1])
			var z := float(L[2])
			var ax := float(L[3])
			var az := float(L[4])
			mb.box(Vector3(0.14, 2.25, 0.14), Vector3(x, y + 0.82, z), Vector3.ZERO, WOOD_D, 0.92)
			mb.box(Vector3(0.55, 0.09, 0.09), Vector3(x + ax * 0.22, y + 1.88, z + az * 0.22), Vector3(0.0, -atan2(az, ax), 0.0), WOOD_D, 0.94)
			var gx := x + ax * 0.45
			var gz := z + az * 0.45
			mb.box(Vector3(0.28, 0.07, 0.28), Vector3(gx, y + 1.72, gz), Vector3.ZERO, IRON, 0.95)
			mb.box(Vector3(0.22, 0.28, 0.22), Vector3(gx, y + 1.54, gz), Vector3.ZERO, Color.WHITE, 1.0, 1.0)

	if mb.tri_count > 0:
		# Do not set visibility_range_end on fences_lanterns: its AABB spans ~1 km of trail, so its
		# center is > 500 m from the cottage/trailhead and a 420 m range culls foreground fences.
		_add_static_mesh("fences_lanterns", mb.finish(prop_mat), mb.aabb, mb.tri_count, 0.0)


# ---------- 6. Lake Pier, Moored Rowboat & Driftwood (1 opaque draw call) ----------
func _build_lake_props() -> void:
	var pinfo: Dictionary = world.props_info()
	if not pinfo.has("pier") or pinfo.pier == null:
		return
	var P: Dictionary = pinfo.pier
	var mb := _MB.new()
	var WOOD := Color(0.44, 0.30, 0.19)
	var WOOD_D := Color(0.30, 0.20, 0.13)
	var IRON := Color(0.12, 0.12, 0.13)

	var jx := float(P.x)
	var jz := float(P.z)
	var deck_y := float(P.deckY)
	var to_lake := float(P.toLake)
	var plen := int(P.len)
	var pw := float(P.w)
	var fwx := sin(to_lake)
	var fwz := cos(to_lake)
	var rx := cos(to_lake)
	var rz := -sin(to_lake)

	# Pier planks (group every 2 planks with subtle seam color shift to keep tris lean & crisp).
	for k in range(-3, plen, 2):
		var px := jx + fwx * (float(k) + 1.0)
		var pz := jz + fwz * (float(k) + 1.0)
		var c := WOOD if ((k / 2) % 2) == 0 else Color(0.40, 0.27, 0.17)
		mb.box(Vector3(pw, 0.11, 1.88), Vector3(px, deck_y + (0.015 if (k % 4) == 0 else 0.0), pz), Vector3(0.0, to_lake, 0.0), c, 0.98)
	for pl in P.pilings:
		var gy := float(pl[1])
		var ty := float(pl[2])
		mb.box(Vector3(0.22, ty - gy, 0.22), Vector3(float(pl[0]), (ty + gy) * 0.5, float(pl[3])), Vector3(0.0, to_lake, 0.0), WOOD_D, 0.90)
	# Pier end lantern post.
	var lan: Array = P.lantern
	var lpx := float(lan[0])
	var lpz := float(lan[2])
	mb.box(Vector3(0.18, 2.3, 0.18), Vector3(lpx, deck_y + 1.15, lpz), Vector3.ZERO, WOOD_D, 0.94)
	mb.box(Vector3(0.70, 0.10, 0.10), Vector3(lpx + rx * 0.28, deck_y + 2.25, lpz + rz * 0.28), Vector3(0.0, to_lake, 0.0), WOOD_D, 0.94)
	mb.box(Vector3(0.32, 0.08, 0.32), Vector3(float(lan[3]), float(lan[4]) + 0.20, float(lan[5])), Vector3.ZERO, IRON, 0.95)
	mb.box(Vector3(0.26, 0.34, 0.26), Vector3(float(lan[3]), float(lan[4]), float(lan[5])), Vector3.ZERO, Color.WHITE, 1.0, 1.0)

	# Painted storybook rowboat moored beside the pier (terracotta hull, cream gunwale, seats & oars).
	if pinfo.has("boat") and pinfo.boat != null:
		var B: Dictionary = pinfo.boat
		mb.xf = Transform3D(Basis.from_euler(Vector3(0.0, float(B.ry), 0.04)), Vector3(float(B.x), float(B.y), float(B.z)))
		var hull_c := Color(0.72, 0.29, 0.21)
		var trim_c := Color(0.94, 0.89, 0.78)
		var inner_c := Color(0.54, 0.35, 0.21)
		mb.boat_hull(1.55, 0.82, 3.85, hull_c, inner_c, trim_c)
		mb.box(Vector3(2.1, 0.08, 0.42), Vector3(0.0, -0.18, -0.40), Vector3.ZERO, WOOD, 0.95)
		mb.box(Vector3(2.0, 0.08, 0.42), Vector3(0.0, -0.18, 1.15), Vector3.ZERO, WOOD, 0.95)
		mb.box(Vector3(1.3, 0.08, 0.65), Vector3(0.0, -0.14, 2.45), Vector3.ZERO, WOOD, 0.95)
		mb.box(Vector3(0.08, 0.06, 3.2), Vector3(0.35, -0.06, 0.40), Vector3(0.0, 0.18, 0.0), WOOD, 0.98)
		mb.box(Vector3(0.08, 0.06, 3.2), Vector3(-0.35, -0.06, 0.20), Vector3(0.0, -0.12, 0.0), WOOD, 0.98)
		mb.xf = Transform3D.IDENTITY

	# Weathered lakeside driftwood log pitched along the local shore slope so neither end floats.
	if pinfo.has("driftwood") and pinfo.driftwood != null:
		var DW: Dictionary = pinfo.driftwood
		var dw_ry := float(DW.ry)
		var dir_x := cos(dw_ry)
		var dir_z := -sin(dw_ry)
		var half_l := 2.45
		var ax := float(DW.x) - dir_x * half_l
		var az := float(DW.z) - dir_z * half_l
		var bx := float(DW.x) + dir_x * half_l
		var bz := float(DW.z) + dir_z * half_l
		var ay := float(world.height(ax, az)) + 0.14
		var by := float(world.height(bx, bz)) + 0.14
		var p_a := Vector3(ax, ay, az)
		var p_b := Vector3(bx, by, bz)
		var axis := p_b - p_a
		var log_len := axis.length()
		var y_ax := axis / maxf(log_len, 1e-4)
		var ref_up := Vector3.UP if absf(y_ax.y) < 0.95 else Vector3.RIGHT
		var x_ax := ref_up.cross(y_ax).normalized()
		var z_ax := x_ax.cross(y_ax).normalized()
		mb.xf = Transform3D(Basis(x_ax, y_ax, z_ax), (p_a + p_b) * 0.5)
		mb.cyl(0.20, 0.30, log_len, 8, Vector3.ZERO, Vector3.ZERO, Color(0.36, 0.27, 0.19), 0.90)
		mb.xf = Transform3D.IDENTITY

	_add_static_mesh("lake_pier_boat", mb.finish(prop_mat), mb.aabb, mb.tri_count, 900.0)


# ---------- 7. Summit Prayer Flags & Poles (only visible near summit) ----------
func _build_summit_flags() -> void:
	var pinfo: Dictionary = world.props_info()
	if not pinfo.has("prayerFlags") or pinfo.prayerFlags.is_empty():
		return
	var pole_mb := _MB.new()
	var pole_col := Color(0.34, 0.23, 0.14)
	var f_pos := PackedVector3Array()
	var f_nrm := PackedVector3Array()
	var f_uv := PackedVector2Array()
	var f_col := PackedColorArray()
	var f_idx := PackedInt32Array()
	var f_aabb := AABB()
	var has_f := false
	var cols: Array[Color] = [
		Color(0.14, 0.34, 0.80), Color(0.94, 0.92, 0.86), Color(0.84, 0.19, 0.14),
		Color(0.12, 0.55, 0.26), Color(0.95, 0.74, 0.14),
	]
	var added_poles := {}
	for span_i in pinfo.prayerFlags.size():
		var sp: Dictionary = pinfo.prayerFlags[span_i]
		var pa := Vector3(float(sp.ax), float(sp.ay), float(sp.az))
		var pb := Vector3(float(sp.bx), float(sp.by), float(sp.bz))
		var pole_a := float(sp.poleA)
		var pole_b := float(sp.poleB)
		var ka := "%d,%d" % [roundi(pa.x * 10.0), roundi(pa.z * 10.0)]
		if not added_poles.has(ka):
			added_poles[ka] = true
			pole_mb.cyl(0.085, 0.145, pole_a, 7, pa + Vector3(0.0, pole_a * 0.5 - 0.30, 0.0), Vector3.ZERO, pole_col, 0.94)
		var kb := "%d,%d" % [roundi(pb.x * 10.0), roundi(pb.z * 10.0)]
		if not added_poles.has(kb):
			added_poles[kb] = true
			pole_mb.cyl(0.085, 0.145, pole_b, 7, pb + Vector3(0.0, pole_b * 0.5 - 0.30, 0.0), Vector3.ZERO, pole_col, 0.94)

		var A := Vector3(pa.x, pa.y + pole_a - 0.35, pa.z)
		var B := Vector3(pb.x, pb.y + pole_b - 0.35, pb.z)
		var d := B - A
		var slen := d.length()
		var dir := d / maxf(slen, 1e-4)
		var perp := Vector3(-dir.z, 0.0, dir.x).normalized()
		var nflags := int(sp.nFlags)
		var sag := float(sp.sag)
		var fh0 := float(sp.fh0)
		var fw0 := slen / float(nflags) * 0.84
		const SU := 3
		const SV := 2
		for f in nflags:
			var t0 := (float(f) + 0.08) / float(nflags)
			var fw := fw0 * (0.82 + 0.28 * float((f * 7) % 3) * 0.5)
			var fh := fh0 * (0.82 + 0.42 * float((f * 5) % 4) / 3.0)
			var col := cols[f % 5]
			var ph := fposmod(float(f) * 0.19 + float(span_i) * 0.37, 1.0)
			var base := f_pos.size()
			for j in SV + 1:
				for i in SU + 1:
					var u := float(i) / float(SU)
					var v := float(j) / float(SV)
					var tt := t0 + u * (fw / slen)
					var p := A + dir * (tt * slen)
					p.y -= sin(tt * PI) * sag + v * fh
					f_pos.append(p)
					f_nrm.append(perp)
					f_uv.append(Vector2(u, v))
					f_col.append(Color(col.r, col.g, col.b, ph))
					var b := AABB(p - Vector3(0.5, 0.5, 0.5), Vector3.ONE)
					f_aabb = b if not has_f else f_aabb.merge(b)
					has_f = true
			for j in SV:
				for i in SU:
					var k := base + j * (SU + 1) + i
					f_idx.append_array([k, k + 1, k + SU + 1, k + 1, k + SU + 2, k + SU + 1])

	if pole_mb.tri_count > 0:
		_add_static_mesh("summit_poles", pole_mb.finish(prop_mat), pole_mb.aabb, pole_mb.tri_count, 500.0)
	if not f_idx.is_empty():
		var arrays := []
		arrays.resize(Mesh.ARRAY_MAX)
		arrays[Mesh.ARRAY_VERTEX] = f_pos
		arrays[Mesh.ARRAY_NORMAL] = f_nrm
		arrays[Mesh.ARRAY_TEX_UV] = f_uv
		arrays[Mesh.ARRAY_COLOR] = f_col
		arrays[Mesh.ARRAY_INDEX] = f_idx
		var fm := ArrayMesh.new()
		fm.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
		fm.surface_set_material(0, flag_mat)
		_add_static_mesh("summit_flags", fm, f_aabb, f_idx.size() / 3, 500.0)


# ---------- 8. Mika Fake Decal Lights & Shadows Helper (0 draws by day) ----------
func _build_fake_lights() -> void:
	fake_lights = FakeLights.new()
	fake_lights.name = "fake_lights"
	add_child(fake_lights)

	var warm_win := Color(1.0, 0.68, 0.28)
	var warm_lan := Color(1.0, 0.62, 0.22)
	for gp in _cottage_glows:
		var is_lan := gp.distance_squared_to(_cottage_lantern) < 0.01
		fake_lights.add_light(gp, 2.6 if is_lan else 2.2, warm_lan if is_lan else warm_win, 1.15 if is_lan else 0.85)

	var pinfo: Dictionary = world.props_info()
	if pinfo.has("lanterns"):
		for L in pinfo.lanterns:
			var gx := float(L[0]) + float(L[3]) * 0.45
			var gy := float(L[1]) + 1.54
			var gz := float(L[2]) + float(L[4]) * 0.45
			fake_lights.add_light(Vector3(gx, gy, gz), 2.5, warm_lan, 1.0)
	if pinfo.has("pier") and pinfo.pier != null:
		var lan: Array = pinfo.pier.lantern
		fake_lights.add_light(Vector3(float(lan[3]), float(lan[4]), float(lan[5])), 2.8, warm_lan, 1.0)

	# Soft multiplicative contact shadow pools for benches & wishing well (ready for W5 or ?fakelights).
	for b in benches:
		fake_lights.add_shadow(Vector3(float(b.x), float(b.y) - 0.44, float(b.z)), Vector2(1.4, 0.85), 0.36)
	if pinfo.has("house"):
		var H: Dictionary = pinfo.house
		var xf := Transform3D(Basis.from_euler(Vector3(0.0, float(H.ry), 0.0)).scaled(Vector3.ONE * float(H.scale)), Vector3(float(H.x), float(H.y), float(H.z)))
		var well_w := xf * Vector3(8.4, 0.0, 3.15)
		fake_lights.add_shadow(Vector3(well_w.x, world.height(well_w.x, well_w.z), well_w.z), Vector2(1.8, 1.8), 0.34)

	fake_lights.rebuild()
	# Off by day (0 draws, 0 tris, 0 ms) unless ?fakelights is passed for verification.
	if Flags.has("fakelights"):
		set_night_glow(0.85)
		fake_lights.set_shadows_on(true)
	else:
		fake_lights.set_intensity(0.0)
		fake_lights.set_shadows_on(false)


func _load_colliders() -> void:
	var pinfo: Dictionary = world.props_info()
	if not pinfo.has("colliders"):
		return
	for c in pinfo.colliders:
		_prop_colliders.append([float(c.x), float(c.z), float(c.r)])


func _add_static_mesh(mesh_name: String, mesh: ArrayMesh, aabb: AABB, tris: int, max_dist: float) -> void:
	var mi := MeshInstance3D.new()
	mi.name = mesh_name
	mi.mesh = mesh
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mi.custom_aabb = aabb
	if max_dist > 0.0:
		mi.visibility_range_end = max_dist
		mi.visibility_range_end_margin = 16.0
	add_child(mi)
	_static_meshes.append({"name": mesh_name, "mi": mi, "aabb": aabb, "tris": tris, "max_dist": max_dist})


# ---------- Winding-verified vertex-colored procedural mesh builder ----------
class _MB:
	var pos := PackedVector3Array()
	var nrm := PackedVector3Array()
	var uv := PackedVector2Array()
	var col := PackedColorArray()
	var idx := PackedInt32Array()
	var xf := Transform3D.IDENTITY
	var aabb := AABB()
	var has_aabb := false
	var tri_count := 0

	func _push_tri(v0: Vector3, v1: Vector3, v2: Vector3, n: Vector3, c: Color, u0: Vector2, u1: Vector2, u2: Vector2) -> void:
		var w0 := xf * v0
		var w1 := xf * v1
		var w2 := xf * v2
		var wn := (xf.basis * n).normalized()
		# Guarantee Godot CW front-face winding relative to outward normal wn.
		var flip := (w2 - w0).cross(w1 - w0).dot(wn) < 0.0
		var base := pos.size()
		if flip:
			pos.append_array([w0, w2, w1])
			nrm.append_array([wn, wn, wn])
			uv.append_array([u0, u2, u1])
		else:
			pos.append_array([w0, w1, w2])
			nrm.append_array([wn, wn, wn])
			uv.append_array([u0, u1, u2])
		col.append_array([c, c, c])
		idx.append_array([base, base + 1, base + 2])
		tri_count += 1
		for wp in [w0, w1, w2]:
			if not has_aabb:
				aabb = AABB(wp, Vector3(0.01, 0.01, 0.01))
				has_aabb = true
			else:
				aabb = aabb.expand(wp)

	func _push_quad(a: Vector3, b: Vector3, c_pt: Vector3, d: Vector3, n: Vector3, c: Color, ua: Vector2, ub: Vector2, uc: Vector2, ud: Vector2) -> void:
		_push_tri(a, b, c_pt, n, c, ua, ub, uc)
		_push_tri(a, c_pt, d, n, c, ua, uc, ud)

	func tri_double(v0: Vector3, v1: Vector3, v2: Vector3, n: Vector3, rgb: Color, ao: float = 1.0) -> void:
		var c := Color(rgb.r, rgb.g, rgb.b, ao)
		var z := Vector2.ZERO
		_push_tri(v0, v1, v2, n, c, z, z, z)
		_push_tri(v0, v2, v1, -n, c, z, z, z)

	func box(size: Vector3, center: Vector3, euler: Vector3, rgb: Color, ao: float = 1.0, uv_x: float = 0.0) -> void:
		var b := Basis.from_euler(euler, EULER_ORDER_YXZ)
		_box_basis(size, center, b, rgb, ao, uv_x)

	func box_yz(size: Vector3, center: Vector3, rot_y: float, rot_z: float, rgb: Color, ao: float = 1.0) -> void:
		var b := Basis(Vector3.UP, rot_y) * Basis(Vector3.BACK, rot_z)
		_box_basis(size, center, b, rgb, ao, 0.0)

	func _box_basis(size: Vector3, center: Vector3, b: Basis, rgb: Color, ao: float, uv_x: float) -> void:
		var hx := size.x * 0.5
		var hy := size.y * 0.5
		var hz := size.z * 0.5
		var c := Color(rgb.r, rgb.g, rgb.b, ao)
		var u := Vector2(uv_x, 0.0)
		var corners: Array[Vector3] = [
			center + b * Vector3(-hx, -hy, -hz), center + b * Vector3(hx, -hy, -hz),
			center + b * Vector3(hx, hy, -hz),   center + b * Vector3(-hx, hy, -hz),
			center + b * Vector3(-hx, -hy, hz),  center + b * Vector3(hx, -hy, hz),
			center + b * Vector3(hx, hy, hz),    center + b * Vector3(-hx, hy, hz),
		]
		var faces := [
			[4, 5, 6, 7, b * Vector3(0, 0, 1)],
			[1, 0, 3, 2, b * Vector3(0, 0, -1)],
			[5, 1, 2, 6, b * Vector3(1, 0, 0)],
			[0, 4, 7, 3, b * Vector3(-1, 0, 0)],
			[7, 6, 2, 3, b * Vector3(0, 1, 0)],
			[0, 1, 5, 4, b * Vector3(0, -1, 0)],
		]
		for f in faces:
			_push_quad(corners[f[0]], corners[f[1]], corners[f[2]], corners[f[3]], f[4], c, u, u, u, u)

	func sign_board(size: Vector3, center: Vector3, euler: Vector3, v0: float, v1: float, edge_col: Color) -> void:
		var b := Basis.from_euler(euler, EULER_ORDER_YXZ)
		var hx := size.x * 0.5
		var hy := size.y * 0.5
		var hz := size.z * 0.5
		var c := Color(1.0, 1.0, 1.0, 1.0)
		var ce := Color(edge_col.r, edge_col.g, edge_col.b, 1.0)
		var eu := Vector2(2.0, 0.0)
		var p: Array[Vector3] = [
			center + b * Vector3(-hx, -hy, -hz), center + b * Vector3(hx, -hy, -hz),
			center + b * Vector3(hx, hy, -hz),   center + b * Vector3(-hx, hy, -hz),
			center + b * Vector3(-hx, -hy, hz),  center + b * Vector3(hx, -hy, hz),
			center + b * Vector3(hx, hy, hz),    center + b * Vector3(-hx, hy, hz),
		]
		# Front (+Z) and Back (-Z) both read left-to-right!
		_push_quad(p[4], p[5], p[6], p[7], b * Vector3(0, 0, 1), c, Vector2(0.0, v1), Vector2(1.0, v1), Vector2(1.0, v0), Vector2(0.0, v0))
		_push_quad(p[1], p[0], p[3], p[2], b * Vector3(0, 0, -1), c, Vector2(0.0, v1), Vector2(1.0, v1), Vector2(1.0, v0), Vector2(0.0, v0))
		# Thin wooden edges use UV.x = 2.0 solid cedar wood.
		_push_quad(p[5], p[1], p[2], p[6], b * Vector3(1, 0, 0), ce, eu, eu, eu, eu)
		_push_quad(p[0], p[4], p[7], p[3], b * Vector3(-1, 0, 0), ce, eu, eu, eu, eu)
		_push_quad(p[7], p[6], p[2], p[3], b * Vector3(0, 1, 0), ce, eu, eu, eu, eu)
		_push_quad(p[0], p[1], p[5], p[4], b * Vector3(0, -1, 0), ce, eu, eu, eu, eu)

	func cyl(r_top: float, r_bot: float, h: float, segs: int, center: Vector3, euler: Vector3, rgb: Color, ao: float = 1.0) -> void:
		var b := Basis.from_euler(euler, EULER_ORDER_YXZ)
		var hy := h * 0.5
		var c := Color(rgb.r, rgb.g, rgb.b, ao)
		var u := Vector2.ZERO
		var top_c := center + b * Vector3(0.0, hy, 0.0)
		var bot_c := center + b * Vector3(0.0, -hy, 0.0)
		var nt := b * Vector3.UP
		var nb := b * Vector3.DOWN
		for i in segs:
			var a0 := float(i) / float(segs) * TAU
			var a1 := float(i + 1) / float(segs) * TAU
			var c0 := cos(a0); var s0 := sin(a0)
			var c1 := cos(a1); var s1 := sin(a1)
			var t0 := center + b * Vector3(c0 * r_top, hy, s0 * r_top)
			var t1 := center + b * Vector3(c1 * r_top, hy, s1 * r_top)
			var b0 := center + b * Vector3(c0 * r_bot, -hy, s0 * r_bot)
			var b1 := center + b * Vector3(c1 * r_bot, -hy, s1 * r_bot)
			var ns := (b * Vector3(c0 + c1, 0.0, s0 + s1)).normalized()
			_push_quad(b0, b1, t1, t0, ns, c, u, u, u, u)
			_push_tri(top_c, t0, t1, nt, c, u, u, u)
			_push_tri(bot_c, b1, b0, nb, c, u, u, u)

	func ico(center: Vector3, scale: Vector3, rgb: Color, ao: float = 1.0) -> void:
		var t := (1.0 + sqrt(5.0)) * 0.5
		var v: Array[Vector3] = [
			Vector3(-1, t, 0).normalized(), Vector3(1, t, 0).normalized(),
			Vector3(-1, -t, 0).normalized(), Vector3(1, -t, 0).normalized(),
			Vector3(0, -1, t).normalized(), Vector3(0, 1, t).normalized(),
			Vector3(0, -1, -t).normalized(), Vector3(0, 1, -t).normalized(),
			Vector3(t, 0, -1).normalized(), Vector3(t, 0, 1).normalized(),
			Vector3(-t, 0, -1).normalized(), Vector3(-t, 0, 1).normalized(),
		]
		var faces := [
			[0, 11, 5], [0, 5, 1], [0, 1, 7], [0, 7, 10], [0, 10, 11],
			[1, 5, 9], [5, 11, 4], [11, 10, 2], [10, 7, 6], [7, 1, 8],
			[3, 9, 4], [3, 4, 2], [3, 2, 6], [3, 6, 8], [3, 8, 9],
			[4, 9, 5], [2, 4, 11], [6, 2, 10], [8, 6, 7], [9, 8, 1],
		]
		var c := Color(rgb.r, rgb.g, rgb.b, ao)
		var u := Vector2.ZERO
		for f in faces:
			var p0 := center + v[f[0]] * scale
			var p1 := center + v[f[1]] * scale
			var p2 := center + v[f[2]] * scale
			var fn := (v[f[0]] + v[f[1]] + v[f[2]]).normalized()
			_push_tri(p0, p1, p2, fn, c, u, u, u)

	func boat_hull(rx: float, ry: float, rz: float, outer_c: Color, inner_c: Color, rim_c: Color) -> void:
		const SEG_U := 14
		const SEG_V := 4
		var co := Color(outer_c.r, outer_c.g, outer_c.b, 0.98)
		var ci := Color(inner_c.r, inner_c.g, inner_c.b, 0.90)
		var cr := Color(rim_c.r, rim_c.g, rim_c.b, 1.0)
		var u := Vector2.ZERO
		for j in SEG_V:
			var p0 := PI * 0.5 + float(j) / float(SEG_V) * (PI * 0.5)
			var p1 := PI * 0.5 + float(j + 1) / float(SEG_V) * (PI * 0.5)
			var sp0 := sin(p0); var cp0 := cos(p0)
			var sp1 := sin(p1); var cp1 := cos(p1)
			for i in SEG_U:
				var a0 := float(i) / float(SEG_U) * TAU
				var a1 := float(i + 1) / float(SEG_U) * TAU
				var c0 := cos(a0); var s0 := sin(a0)
				var c1 := cos(a1); var s1 := sin(a1)
				var q00 := Vector3(c0 * sp0 * rx, cp0 * ry, s0 * sp0 * rz)
				var q10 := Vector3(c1 * sp0 * rx, cp0 * ry, s1 * sp0 * rz)
				var q11 := Vector3(c1 * sp1 * rx, cp1 * ry, s1 * sp1 * rz)
				var q01 := Vector3(c0 * sp1 * rx, cp1 * ry, s0 * sp1 * rz)
				var n_out := Vector3((c0 + c1) * 0.5 * sp0, (cp0 + cp1) * 0.5, (s0 + s1) * 0.5 * sp0).normalized()
				_push_quad(q00, q10, q11, q01, n_out, co, u, u, u, u)
				var r_in := 0.91
				var i00 := q00 * r_in + Vector3(0.0, 0.05, 0.0)
				var i10 := q10 * r_in + Vector3(0.0, 0.05, 0.0)
				var i11 := q11 * r_in + Vector3(0.0, 0.05, 0.0)
				var i01 := q01 * r_in + Vector3(0.0, 0.05, 0.0)
				_push_quad(i00, i01, i11, i10, -n_out, ci, u, u, u, u)
				if j == 0:
					# Cream gunwale rim connecting outer & inner top edges.
					_push_quad(q00, q10, i10, i00, Vector3.UP, cr, u, u, u, u)

	func finish(mat: Material) -> ArrayMesh:
		var custom0 := PackedFloat32Array()
		custom0.resize(col.size() * 4)
		for i in col.size():
			var c := col[i]
			var o := i * 4
			custom0[o] = c.r
			custom0[o + 1] = c.g
			custom0[o + 2] = c.b
			custom0[o + 3] = c.a
		var arrays := []
		arrays.resize(Mesh.ARRAY_MAX)
		arrays[Mesh.ARRAY_VERTEX] = pos
		arrays[Mesh.ARRAY_NORMAL] = nrm
		arrays[Mesh.ARRAY_TEX_UV] = uv
		arrays[Mesh.ARRAY_CUSTOM0] = custom0
		arrays[Mesh.ARRAY_INDEX] = idx
		var m := ArrayMesh.new()
		m.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays, [], {}, Mesh.ARRAY_CUSTOM_RGBA_FLOAT << Mesh.ARRAY_FORMAT_CUSTOM0_SHIFT)
		m.surface_set_material(0, mat)
		return m
