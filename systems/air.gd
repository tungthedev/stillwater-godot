extends Node3D

# Slice W4: Air & atmosphere effects — forest canopy light shafts, capped sunlit motes,
# waterfall plunge-pool mist/spray, and valley mist control (folded into atmosphere.gdshaderinc).
#
# Perf contract (iPhone 13 mini WebGL2):
#   - <= 2 draw calls in any view (shafts + motes in forest; spray + motes at waterfall;
#     only motes = 1 draw elsewhere; valley mist = 0 draws in atmosphere.gdshaderinc).
#   - Every blended effect is small, capped, and distance-culled; target < 0.5 ms each.
#   - Near-zero per-frame GDScript: motes & spray animate purely in vertex via TIME and
#     CAMERA_POSITION_WORLD; shaft culling & waterfall spray visibility only run when camera moves.

const SwapMultiMesh := preload("res://systems/swap_multimesh.gd")

const CULL_STEP := 6.0
const SHAFT_DIST := 96.0
const SHAFT_CAP := 10
const MOTE_COUNT := 160
const SPRAY_DIST := 440.0
const SMOKE_COUNT := 20
const SMOKE_DIST := 520.0

var world: RefCounted
var env_sys: Node
var shaft_mat: ShaderMaterial
var mote_mat: ShaderMaterial
var spray_mat: ShaderMaterial
var smoke_mat: ShaderMaterial

var _shaft_swap: RefCounted
var _mote_swap: RefCounted
var _spray_swap: RefCounted
var _smoke_swap: RefCounted

var _shaft_buf := PackedFloat32Array()
var _shafts: Array = []
var _shaft_vis := 0
var _shaft_aabb := AABB()
var _house_xz := Vector2(615.25, 796.96)
var _has_house := false

var _mote_active := MOTE_COUNT
var _spray_count := 0
var _spray_center := Vector3.ZERO
var _spray_aabb := AABB()
var _spray_vis := false
var _smoke_count := 0
var _smoke_center := Vector3.ZERO
var _smoke_aabb := AABB()
var _smoke_vis := false

var _cull_pos := Vector3(1e9, 0.0, 1e9)
var _dist_scale := 1.0
var _density := 1.0
var _dirty := true
var _on := true
var _shafts_on := true
var _motes_on := true
var _spray_on := true
var _smoke_on := true
var frozen := false

var last_draws := 0
var last_tris := 0
var load_ms := 0
var prof_us := 0


func setup(w: RefCounted) -> void:
	world = w


func set_env(e: Node) -> void:
	env_sys = e
	if env_sys != null:
		env_sys.set_valley_mist(_on)


func _ready() -> void:
	var t0 := Time.get_ticks_msec()
	process_priority = 100
	_build_materials()
	_build_shafts()
	_build_motes()
	_build_waterfall_spray()
	_build_chimney_smoke()
	load_ms = Time.get_ticks_msec() - t0
	print("AIR built in %d ms: shafts=%d (cap %d), motes=%d, waterfall_spray=%d puffs, chimney_smoke=%d puffs" % [
		load_ms, _shafts.size(), SHAFT_CAP, _mote_active, _spray_count, _smoke_count])


func materials() -> Array[ShaderMaterial]:
	return [shaft_mat, mote_mat, spray_mat, smoke_mat]


func set_on(v: bool) -> void:
	_on = v
	visible = v
	if env_sys != null:
		env_sys.set_valley_mist(v)
	_sync_visibility()
	if not v:
		last_draws = 0
		last_tris = 0
	else:
		_dirty = true


func is_on() -> bool:
	return _on


func set_shafts_on(v: bool) -> void:
	_shafts_on = v
	_sync_visibility()


func set_motes_on(v: bool) -> void:
	_motes_on = v
	_sync_visibility()


func set_spray_on(v: bool) -> void:
	_spray_on = v
	_sync_visibility()


func set_smoke_on(v: bool) -> void:
	_smoke_on = v
	_sync_visibility()


func set_frozen(v: bool) -> void:
	frozen = v


func set_dist_scale(s: float) -> void:
	var clamped := clampf(s, 0.35, 1.0)
	if absf(clamped - _dist_scale) < 1e-4:
		return
	_dist_scale = clamped
	_dirty = true


func set_density(d: float) -> void:
	var clamped := clampf(d, 0.25, 1.0)
	if absf(clamped - _density) < 1e-4:
		return
	_density = clamped
	_mote_active = maxi(24, int(round(float(MOTE_COUNT) * _density)))
	if _mote_swap != null:
		for mm in _mote_swap.mms:
			mm.visible_instance_count = _mote_active
	_dirty = true


func _sync_visibility() -> void:
	if _shaft_swap != null:
		_shaft_swap.set_visible(_on and _shafts_on and _shaft_vis > 0)
	if _mote_swap != null:
		_mote_swap.set_visible(_on and _motes_on and _mote_active > 0)
	if _spray_swap != null:
		_spray_swap.set_visible(_on and _spray_on and _spray_vis and _spray_count > 0)
	if _smoke_swap != null:
		_smoke_swap.set_visible(_on and _smoke_on and _smoke_vis and _smoke_count > 0)


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
	_cull_shafts(cp)
	if _spray_count > 0:
		var sd := SPRAY_DIST * _dist_scale
		_spray_vis = cp.distance_squared_to(_spray_center) <= sd * sd
	else:
		_spray_vis = false
	if _smoke_count > 0:
		var smd := SMOKE_DIST * _dist_scale
		_smoke_vis = cp.distance_squared_to(_smoke_center) <= smd * smd
	else:
		_smoke_vis = false
	_sync_visibility()


func count_drawn(cam: Camera3D) -> void:
	if not _on:
		last_draws = 0
		last_tris = 0
		return
	var planes := cam.get_frustum()
	var draws := 0
	var tris := 0
	if _shafts_on and _shaft_vis > 0 and _aabb_in_frustum(_shaft_aabb, planes):
		draws += 1
		tris += _shaft_vis * 2
	if _motes_on and _mote_active > 0:
		draws += 1
		tris += _mote_active * 2
	if _spray_on and _spray_vis and _spray_count > 0 and _aabb_in_frustum(_spray_aabb, planes):
		draws += 1
		tris += _spray_count * 2
	if _smoke_on and _smoke_vis and _smoke_count > 0 and _aabb_in_frustum(_smoke_aabb, planes):
		draws += 1
		tris += _smoke_count * 2
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


func _build_materials() -> void:
	var pi: Dictionary = world.props_info()
	var ao := Vector4(615.25, 796.96, 8.5, 0.0)
	if pi.has("house"):
		_house_xz = Vector2(float(pi.house.x), float(pi.house.z))
		_has_house = true
		ao = Vector4(_house_xz.x, _house_xz.y, 8.5, 0.0)

	shaft_mat = ShaderMaterial.new()
	shaft_mat.shader = load("res://shaders/light_shaft.gdshader")
	shaft_mat.render_priority = 2
	shaft_mat.set_shader_parameter("sky_lut", world.sky_lut_tex)
	shaft_mat.set_shader_parameter("noise_tex", world.noise_tex)
	shaft_mat.set_shader_parameter("water_level", world.water_level)
	shaft_mat.set_shader_parameter("ao_spot", ao)

	mote_mat = ShaderMaterial.new()
	mote_mat.shader = load("res://shaders/motes.gdshader")
	mote_mat.render_priority = 3
	mote_mat.set_shader_parameter("sky_lut", world.sky_lut_tex)
	mote_mat.set_shader_parameter("noise_tex", world.noise_tex)
	mote_mat.set_shader_parameter("near_tex", world.texture("near"))
	mote_mat.set_shader_parameter("biome_tex", world.texture("biome"))
	mote_mat.set_shader_parameter("near_size", world.near_size)
	mote_mat.set_shader_parameter("near_min", world.near_min)
	mote_mat.set_shader_parameter("near_step", world.near_step)
	mote_mat.set_shader_parameter("water_level", world.water_level)

	spray_mat = ShaderMaterial.new()
	spray_mat.shader = load("res://shaders/waterfall_spray.gdshader")
	spray_mat.render_priority = 2
	spray_mat.set_shader_parameter("sky_lut", world.sky_lut_tex)
	spray_mat.set_shader_parameter("noise_tex", world.noise_tex)
	spray_mat.set_shader_parameter("water_level", world.water_level)

	smoke_mat = ShaderMaterial.new()
	smoke_mat.shader = load("res://shaders/chimney_smoke.gdshader")
	smoke_mat.render_priority = 2
	smoke_mat.set_shader_parameter("sky_lut", world.sky_lut_tex)
	smoke_mat.set_shader_parameter("noise_tex", world.noise_tex)
	smoke_mat.set_shader_parameter("water_level", world.water_level)


func _build_quad(x0: float, x1: float, y0: float, y1: float, mat: Material) -> ArrayMesh:
	var pv := PackedVector3Array([
		Vector3(x0, y0, 0.0), Vector3(x1, y0, 0.0),
		Vector3(x0, y1, 0.0), Vector3(x1, y1, 0.0),
	])
	var idx := PackedInt32Array([0, 1, 2, 1, 3, 2])
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = pv
	arrays[Mesh.ARRAY_INDEX] = idx
	var m := ArrayMesh.new()
	m.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	m.surface_set_material(0, mat)
	return m


# ---------- 1. Forest Canopy Light Shafts ----------
func _build_shafts() -> void:
	var ug: Dictionary = world.undergrowth_info()
	if ug.has("shafts"):
		for s in ug.shafts:
			_shafts.append(s)
	var mesh := _build_quad(-0.5, 0.5, 0.0, 1.0, shaft_mat)
	_shaft_buf.resize(SHAFT_CAP * 16)
	_shaft_swap = SwapMultiMesh.new(self, mesh, SHAFT_CAP, AABB(Vector3(-4000, -500, -4000), Vector3(8000, 3000, 8000)))
	_shaft_swap.set_visible(false)


func _cull_shafts(cp: Vector3) -> void:
	if _shafts.is_empty():
		_shaft_vis = 0
		return
	var max_d := SHAFT_DIST * _dist_scale
	var max_d2 := max_d * max_d
	var cands: Array = []
	for i in _shafts.size():
		var s: Array = _shafts[i]
		var sx := float(s[0])
		var sz := float(s[2])
		if _has_house and Vector2(sx - _house_xz.x, sz - _house_xz.y).length_squared() < 82.0 * 82.0:
			continue
		var dx := sx - cp.x
		var dz := sz - cp.z
		var d2 := dx * dx + dz * dz
		if d2 <= max_d2:
			cands.append([d2, i])
	if cands.is_empty():
		_shaft_vis = 0
		return
	cands.sort_custom(func(a: Array, b: Array) -> bool: return float(a[0]) < float(b[0]))
	var limit := mini(SHAFT_CAP, maxi(2, int(round(float(SHAFT_CAP) * _density))))
	var n := mini(cands.size(), limit)
	var aabb := AABB()
	var has_aabb := false
	for k in n:
		var s: Array = _shafts[int(cands[k][1])]
		var x := float(s[0])
		var y := float(s[1])
		var z := float(s[2])
		var w := float(s[3])
		var seed := float(s[4])
		var o := k * 16
		_shaft_buf[o + 0] = 1.0; _shaft_buf[o + 1] = 0.0; _shaft_buf[o + 2] = 0.0; _shaft_buf[o + 3] = x
		_shaft_buf[o + 4] = 0.0; _shaft_buf[o + 5] = 1.0; _shaft_buf[o + 6] = 0.0; _shaft_buf[o + 7] = y
		_shaft_buf[o + 8] = 0.0; _shaft_buf[o + 9] = 0.0; _shaft_buf[o + 10] = 1.0; _shaft_buf[o + 11] = z
		_shaft_buf[o + 12] = w
		_shaft_buf[o + 13] = seed
		_shaft_buf[o + 14] = max_d
		_shaft_buf[o + 15] = 0.0
		var b := AABB(Vector3(x - 24.0, y - 2.0, z - 24.0), Vector3(48.0, 32.0, 48.0))
		aabb = b if not has_aabb else aabb.merge(b)
		has_aabb = true
	_shaft_vis = n
	_shaft_aabb = aabb
	_shaft_swap.push(_shaft_buf, n)
	for mmi in _shaft_swap.mmis:
		mmi.custom_aabb = aabb


# ---------- 2. Sunlit Drifting Motes (zero per-frame GDScript) ----------
func _build_motes() -> void:
	var mesh := _build_quad(-1.0, 1.0, -1.0, 1.0, mote_mat)
	# Huge AABB so the periodic camera-centered vertex shader is never frustum-culled.
	var huge := AABB(Vector3(-20000, -2000, -20000), Vector3(40000, 8000, 40000))
	_mote_swap = SwapMultiMesh.new(self, mesh, MOTE_COUNT, huge)
	var buf := PackedFloat32Array()
	buf.resize(MOTE_COUNT * 16)
	var rng := RandomNumberGenerator.new()
	rng.seed = 66
	for i in MOTE_COUNT:
		var o := i * 16
		buf[o + 0] = 1.0; buf[o + 1] = 0.0; buf[o + 2] = 0.0; buf[o + 3] = 0.0
		buf[o + 4] = 0.0; buf[o + 5] = 1.0; buf[o + 6] = 0.0; buf[o + 7] = 0.0
		buf[o + 8] = 0.0; buf[o + 9] = 0.0; buf[o + 10] = 1.0; buf[o + 11] = 0.0
		buf[o + 12] = rng.randf()
		buf[o + 13] = rng.randf()
		buf[o + 14] = rng.randf()
		buf[o + 15] = rng.randf()
	_mote_swap.push(buf, _mote_active)


# ---------- 3. Waterfall Plunge-Pool Mist & Crest-Lip Spray ----------
func _build_waterfall_spray() -> void:
	var wf: Dictionary = world.waterfall_info()
	if wf.is_empty():
		return
	var bx := float(wf.bx)
	var bz := float(wf.bz)
	var ux := float(wf.ux)
	var uz := float(wf.uz)
	var lx := -uz
	var lz := ux
	var y_top := float(wf.yTop)
	var d_lip := float(wf.dLip)
	var pc: Array = wf.poolCenter
	var pool_y := minf(float(pc[1]), world.height_near(float(pc[0]), float(pc[2])) + 0.95)
	var ip: Array = wf.impactPt
	var imp_x := float(ip[0])
	var imp_z := float(ip[2])

	# 22 flank mist puffs drifting sideways off the impact (leaves center turquoise pool open!)
	# + 6 subtle crest-lip spray puffs softening the top overflow notch = 28 puffs (56 tris).
	const TOTAL := 28
	var rng := RandomNumberGenerator.new()
	rng.seed = 711
	var buf := PackedFloat32Array()
	buf.resize(TOTAL * 16)
	var aabb := AABB()
	var has_aabb := false
	for i in TOTAL:
		var ox: float
		var oy: float
		var oz: float
		var dx: float
		var dy: float
		var dz: float
		var rad: float
		var alpha_s: float
		if i >= 22:
			var lat := (rng.randf() - 0.5) * 13.0
			ox = bx + ux * (d_lip - 0.2 + rng.randf() * 1.4) + lx * (lat + 0.6)
			oy = y_top - 2.4 + rng.randf() * 1.2
			oz = bz + uz * (d_lip - 0.2 + rng.randf() * 1.4) + lz * (lat + 0.6)
			dx = lx * (rng.randf() - 0.5) * 2.2
			dy = 2.0 + rng.randf() * 1.4
			dz = lz * (rng.randf() - 0.5) * 2.2
			rad = 2.2 + rng.randf() * 1.2
			alpha_s = 0.72
		else:
			var side_sign := 1.0 if (i % 2 == 0) else -1.0
			var lat := side_sign * (4.2 + rng.randf() * 10.5)
			var fwd := (rng.randf() - 0.25) * 4.8 + 1.4
			ox = imp_x + lx * lat + ux * fwd
			oy = pool_y + 0.8 + rng.randf() * 3.4
			oz = imp_z + lz * lat + uz * fwd
			dx = lx * side_sign * (4.0 + rng.randf() * 5.8) + ux * (1.2 + rng.randf() * 2.4)
			dy = 3.0 + rng.randf() * 4.2
			dz = lz * side_sign * (4.0 + rng.randf() * 5.8) + uz * (1.2 + rng.randf() * 2.4)
			rad = 2.4 + rng.randf() * 1.6
			alpha_s = 1.0
		var o := i * 16
		# Pack drift in basis column 0 and base radius in basis[1].y (decoded in waterfall_spray.gdshader).
		buf[o + 0] = dx;  buf[o + 1] = 0.0; buf[o + 2] = 0.0; buf[o + 3] = ox
		buf[o + 4] = dy;  buf[o + 5] = rad; buf[o + 6] = 0.0; buf[o + 7] = oy
		buf[o + 8] = dz;  buf[o + 9] = 0.0; buf[o + 10] = 1.0; buf[o + 11] = oz
		buf[o + 12] = rng.randf()
		buf[o + 13] = alpha_s
		buf[o + 14] = 0.0
		buf[o + 15] = 0.0
		var b := AABB(Vector3(ox - 12.0, oy - 4.0, oz - 12.0), Vector3(24.0, 14.0, 24.0))
		aabb = b if not has_aabb else aabb.merge(b)
		has_aabb = true
	_spray_count = TOTAL
	_spray_center = Vector3(imp_x, pool_y + 4.0, imp_z)
	_spray_aabb = aabb
	var mesh := _build_quad(-1.0, 1.0, -1.0, 1.0, spray_mat)
	_spray_swap = SwapMultiMesh.new(self, mesh, TOTAL, aabb)
	_spray_swap.push(buf, TOTAL)
	_spray_swap.set_visible(false)


# ---------- 4. Cottage Chimney Woodsmoke (W5, 20 puffs = 40 tris, 1 draw when near cottage) ----------
func _build_chimney_smoke() -> void:
	var finfo: Dictionary = world.fauna_info()
	if not finfo.has("chimney"):
		return
	var ch: Array = finfo.chimney
	if ch.size() < 3:
		return
	var origin := Vector3(float(ch[0]), float(ch[1]), float(ch[2]))
	var rng := RandomNumberGenerator.new()
	rng.seed = 505
	var buf := PackedFloat32Array()
	buf.resize(SMOKE_COUNT * 16)
	for i in SMOKE_COUNT:
		var o := i * 16
		buf[o + 0] = 1.0; buf[o + 1] = 0.0; buf[o + 2] = 0.0; buf[o + 3] = origin.x
		buf[o + 4] = 0.0; buf[o + 5] = 1.0; buf[o + 6] = 0.0; buf[o + 7] = origin.y
		buf[o + 8] = 0.0; buf[o + 9] = 0.0; buf[o + 10] = 1.0; buf[o + 11] = origin.z
		buf[o + 12] = float(i) / float(SMOKE_COUNT)
		buf[o + 13] = rng.randf()
		buf[o + 14] = 0.0
		buf[o + 15] = 0.0
	_smoke_count = SMOKE_COUNT
	_smoke_center = origin + Vector3(0.0, 6.0, 0.0)
	_smoke_aabb = AABB(origin - Vector3(12.0, 2.0, 12.0), Vector3(24.0, 22.0, 24.0))
	var mesh := _build_quad(-1.0, 1.0, -1.0, 1.0, smoke_mat)
	_smoke_swap = SwapMultiMesh.new(self, mesh, SMOKE_COUNT, _smoke_aabb)
	_smoke_swap.push(buf, SMOKE_COUNT)
	_smoke_swap.set_visible(false)
