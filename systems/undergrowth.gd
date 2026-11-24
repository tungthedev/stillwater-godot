extends Node3D

# Slice W4: Painted forest undergrowth — stylized low-overdraw ferns, mossy nurse logs, ancient
# mossy stumps, and high-readability woodland mushrooms (crimson toadstools & golden chanterelles).
#
# Perf contract (iPhone 13 mini WebGL2):
#   - <= 4 draw calls total in deep forest (0 draws outside forest!):
#       1. Ferns (stylized opaque 63-tri geometric rosette, SwapMultiMesh, render_priority = -1)
#       2. Mossy Logs (opaque chamfered trunk + draped velvet moss + shelf fungi, SwapMultiMesh, -1)
#       3. Mossy Stumps (opaque flared root stump + moss cap + cut grain, SwapMultiMesh, -1)
#       4. Mushrooms (toadstools + chanterelles in 1 opaque SwapMultiMesh, -1)
#   - 100% opaque, ZERO discard, ZERO alpha blending -> full Apple TBDR HSR.
#   - Tier parity: placements come from data/valley/web/ (logs, stumps, mushrooms.bin) and the
#     canonical deterministic 16 m fern tile scatter (seed 55, matching Three.js FERN_LAYOUT).
#   - Near-zero stationary GDScript: culling & fern tile cache run only when camera moves >= CULL_STEP.

const SwapMultiMesh := preload("res://systems/swap_multimesh.gd")
const VegScatter := preload("res://world/veg_scatter.gd")

const CULL_STEP := 5.0
const FERN_TILE_SIZE := 16.0
const FERN_SEED := 55
const FERN_MAX_COUNT := 768
const FERN_LOW_RANKS := 125
const FERN_RADIUS := 26.0
const FERN_CAP := 170
const LOG_DIST := 95.0
const STUMP_DIST := 85.0
const MUSH_DIST := 46.0
const TILE_CACHE_MAX := 128

var world: RefCounted
var fern_mat: ShaderMaterial
var wood_mat: ShaderMaterial
var mush_mat: ShaderMaterial

var _fern_swap: RefCounted
var _log_swap: RefCounted
var _stump_swap: RefCounted
var _mush_swap: RefCounted

var _fern_buf := PackedFloat32Array()
var _log_buf := PackedFloat32Array()
var _stump_buf := PackedFloat32Array()
var _mush_buf := PackedFloat32Array()

var _fern_tris := 0
var _log_tris := 0
var _stump_tris := 0
var _mush_tris := 0

var _logs: Array = []
var _stumps: Array = []
var _mush_x := PackedFloat32Array()
var _mush_y := PackedFloat32Array()
var _mush_z := PackedFloat32Array()
var _mush_sc := PackedFloat32Array()
var _mush_sh := PackedFloat32Array()
var _mush_cr := PackedFloat32Array()
var _mush_tilt := PackedFloat32Array()
var _mush_rot := PackedFloat32Array()
var _mush_golden := PackedByteArray()
var _mush_count := 0

# Deterministic canonical fern scatter (rank-ordered so tiers only draw the first N ranks).
var _fern_scatter_local := PackedFloat32Array()
var _fern_scatter_rnd := PackedFloat32Array()
var _fern_tile_cache := {} # Vector2i -> Array of packed records (empty array if non-forest tile)
var _house_xz := Vector2(615.25, 796.96)
var _has_house := false

var _cull_pos := Vector3(1e9, 0.0, 1e9)
var _cull_fwd := Vector2.ZERO
var _dist_scale := 1.0
var _density := 1.0
var _dirty := true
var _on := true
var frozen := false

var _fern_vis := 0
var _log_vis := 0
var _stump_vis := 0
var _mush_vis := 0
var _fern_aabb := AABB()
var _log_aabb := AABB()
var _stump_aabb := AABB()
var _mush_aabb := AABB()

var last_draws := 0
var last_tris := 0
var load_ms := 0
var prof_us := 0


func setup(w: RefCounted) -> void:
	world = w


func _ready() -> void:
	var t0 := Time.get_ticks_msec()
	process_priority = 100
	var pi: Dictionary = world.props_info()
	if pi.has("house"):
		_house_xz = Vector2(float(pi.house.x), float(pi.house.z))
		_has_house = true
	_build_materials()
	_build_fern_scatter()
	_build_ferns()
	_build_logs_and_stumps()
	_build_mushrooms()
	load_ms = Time.get_ticks_msec() - t0
	print("UNDERGROWTH built in %d ms: fern_tris=%d, logs=%d, stumps=%d, mushrooms=%d" % [
		load_ms, _fern_tris, _logs.size(), _stumps.size(), _mush_count])


func materials() -> Array[ShaderMaterial]:
	return [fern_mat, wood_mat, mush_mat]


func set_on(v: bool) -> void:
	_on = v
	visible = v
	if _fern_swap != null:
		_fern_swap.set_visible(v and _fern_vis > 0)
	if _log_swap != null:
		_log_swap.set_visible(v and _log_vis > 0)
	if _stump_swap != null:
		_stump_swap.set_visible(v and _stump_vis > 0)
	if _mush_swap != null:
		_mush_swap.set_visible(v and _mush_vis > 0)
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
	fern_mat.set_shader_parameter("dist_scale", _dist_scale)
	wood_mat.set_shader_parameter("dist_scale", _dist_scale)
	mush_mat.set_shader_parameter("dist_scale", _dist_scale)
	_dirty = true


func set_density(d: float) -> void:
	var clamped := clampf(d, 0.25, 1.0)
	if absf(clamped - _density) < 1e-4:
		return
	_density = clamped
	_fern_tile_cache.clear()
	_dirty = true


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
	var fwd := -cam.global_transform.basis.z
	var fwd_xz := Vector2(fwd.x, fwd.z)
	if fwd_xz.length_squared() > 1e-6:
		fwd_xz = fwd_xz.normalized()
	if not force and not _dirty and cp.distance_squared_to(_cull_pos) < CULL_STEP * CULL_STEP and fwd_xz.dot(_cull_fwd) > 0.86:
		return
	_cull_pos = cp
	_cull_fwd = fwd_xz
	_dirty = false
	_cull_ferns(cp, fwd_xz)
	_cull_logs(cp)
	_cull_stumps(cp)
	_cull_mushrooms(cp)


func count_drawn(cam: Camera3D) -> void:
	if not _on:
		last_draws = 0
		last_tris = 0
		return
	var planes := cam.get_frustum()
	var draws := 0
	var tris := 0
	if _fern_vis > 0 and _aabb_in_frustum(_fern_aabb, planes):
		draws += 1
		tris += _fern_vis * _fern_tris
	if _log_vis > 0 and _aabb_in_frustum(_log_aabb, planes):
		draws += 1
		tris += _log_vis * _log_tris
	if _stump_vis > 0 and _aabb_in_frustum(_stump_aabb, planes):
		draws += 1
		tris += _stump_vis * _stump_tris
	if _mush_vis > 0 and _aabb_in_frustum(_mush_aabb, planes):
		draws += 1
		tris += _mush_vis * _mush_tris
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
	var ao := Vector4(_house_xz.x, _house_xz.y, 8.5 if _has_house else 0.0, 0.0)

	fern_mat = ShaderMaterial.new()
	fern_mat.shader = load("res://shaders/fern_painted.gdshader")
	fern_mat.render_priority = -1
	fern_mat.set_shader_parameter("sky_lut", world.sky_lut_tex)
	fern_mat.set_shader_parameter("noise_tex", world.noise_tex)
	fern_mat.set_shader_parameter("water_level", world.water_level)
	fern_mat.set_shader_parameter("ao_spot", ao)

	wood_mat = ShaderMaterial.new()
	wood_mat.shader = load("res://shaders/undergrowth_wood.gdshader")
	wood_mat.render_priority = -1
	wood_mat.set_shader_parameter("sky_lut", world.sky_lut_tex)
	wood_mat.set_shader_parameter("noise_tex", world.noise_tex)
	wood_mat.set_shader_parameter("water_level", world.water_level)
	wood_mat.set_shader_parameter("ao_spot", ao)

	mush_mat = ShaderMaterial.new()
	mush_mat.shader = load("res://shaders/mushroom_painted.gdshader")
	mush_mat.render_priority = -1
	mush_mat.set_shader_parameter("sky_lut", world.sky_lut_tex)
	mush_mat.set_shader_parameter("noise_tex", world.noise_tex)
	mush_mat.set_shader_parameter("water_level", world.water_level)


# ---------- 1. Stylized Opaque Geometric Fern Rosettes ----------
func _build_fern_scatter() -> void:
	var sc: Dictionary = VegScatter.generate(FERN_MAX_COUNT, FERN_TILE_SIZE, FERN_SEED)
	_fern_scatter_local = sc.local
	_fern_scatter_rnd = sc.rnd


func _build_ferns() -> void:
	var mesh := _build_fern_mesh()
	mesh.surface_set_material(0, fern_mat)
	_fern_buf.resize(FERN_CAP * 16)
	_fern_swap = SwapMultiMesh.new(self, mesh, FERN_CAP, AABB(Vector3(-4000, -500, -4000), Vector3(8000, 3000, 8000)))
	_fern_swap.set_visible(false)


# 7 gracefully arching slender fern fronds per rosette (4 outer lower plumes + 3 inner taller
# plumes), each built as a 5-segment curved lanceolate blade (9 tris/frond = 63 tris total).
# 100% opaque geometry (zero discard, zero alpha overdraw) with spherical upward dome normals.
func _build_fern_mesh() -> ArrayMesh:
	var pos := PackedVector3Array()
	var nrm := PackedVector3Array()
	var uv := PackedVector2Array()
	var idx := PackedInt32Array()

	const FRONDS := 7
	const SEGS := 5
	for f in FRONDS:
		var ang := float(f) / float(FRONDS) * TAU + float(f % 2) * 0.22
		var dir := Vector3(cos(ang), 0.0, sin(ang))
		var side := Vector3(-dir.z, 0.0, dir.x)
		var is_outer := (f % 2 == 0)
		var reach := 1.05 if is_outer else 0.78
		var arch_h := 0.54 if is_outer else 0.76
		var max_w := 0.20 if is_outer else 0.17

		var base_v := pos.size()
		for s in SEGS:
			var t := float(s) / float(SEGS)
			var r := t * reach
			var y := sin(t * PI * 0.88) * arch_h + 0.01 - t * t * 0.08
			var center := dir * r + Vector3(0.0, y, 0.0)
			# Classic botanical fern outline: slender stalk at base, full mid-blade, fine tapering tip.
			var w := max_w * (0.16 + 0.84 * sin(pow(t, 0.72) * PI * 0.96)) * (1.0 - t * 0.22)
			var cup_y := w * 0.12
			var pl := center - side * w + Vector3(0.0, cup_y, 0.0)
			var pr := center + side * w + Vector3(0.0, cup_y, 0.0)
			var nl := (pl + Vector3(0.0, 0.65, 0.0) - side * 0.14).normalized()
			var nr := (pr + Vector3(0.0, 0.65, 0.0) + side * 0.14).normalized()
			pos.append(pl); nrm.append(nl); uv.append(Vector2(-1.0, t))
			pos.append(pr); nrm.append(nr); uv.append(Vector2(1.0, t))
		# Pointed drooping frond tip.
		var tip := dir * reach + Vector3(0.0, sin(PI * 0.88) * arch_h - 0.07, 0.0)
		var tip_i := pos.size()
		pos.append(tip)
		nrm.append((tip + Vector3(0.0, 0.65, 0.0)).normalized())
		uv.append(Vector2(0.0, 1.0))

		for s in SEGS - 1:
			var a := base_v + s * 2
			idx.append_array([a, a + 2, a + 1, a + 1, a + 2, a + 3])
		var last := base_v + (SEGS - 1) * 2
		idx.append_array([last, tip_i, last + 1])

	_fern_tris = idx.size() / 3
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = pos
	arrays[Mesh.ARRAY_NORMAL] = nrm
	arrays[Mesh.ARRAY_TEX_UV] = uv
	arrays[Mesh.ARRAY_INDEX] = idx
	var m := ArrayMesh.new()
	m.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return m


func _get_fern_tile(tx: int, tz: int) -> Array:
	var key := Vector2i(tx, tz)
	if _fern_tile_cache.has(key):
		return _fern_tile_cache[key]
	if _fern_tile_cache.size() >= TILE_CACHE_MAX:
		_fern_tile_cache.clear()
	var ox := float(tx) * FERN_TILE_SIZE
	var oz := float(tz) * FERN_TILE_SIZE
	# Quick 5x5 forest biome reject (matches Three.js undergrowth.js isFernTileEmpty).
	var any_forest := false
	for iz in 5:
		var z := oz + float(iz) * 0.25 * FERN_TILE_SIZE
		for ix in 5:
			var x := ox + float(ix) * 0.25 * FERN_TILE_SIZE
			if world.biome_at(x, z).forest > 0.36 and world.height_near(x, z) > world.water_level:
				any_forest = true
				break
		if any_forest:
			break
	if not any_forest:
		_fern_tile_cache[key] = []
		return []

	var flip: Vector2i = VegScatter.flip_bits(tx, tz)
	var ranks := maxi(16, int(round(float(FERN_LOW_RANKS) * _density)))
	var out: Array = []
	var wl: float = world.water_level
	for r in ranks:
		var lx := _fern_scatter_local[r * 2]
		var lz := _fern_scatter_local[r * 2 + 1]
		if flip.x != 0:
			lx = FERN_TILE_SIZE - lx
		if flip.y != 0:
			lz = FERN_TILE_SIZE - lz
		var x := ox + lx
		var z := oz + lz
		var bio: Dictionary = world.biome_at(x, z)
		var bf: float = bio.forest
		if bf <= 0.44:
			continue
		var bfl: float = bio.flowers
		if bfl >= 0.24:
			continue
		var h: float = world.height_near(x, z)
		if h < wl + 0.5:
			continue
		var tr_v: float = world.trail_at(x, z)
		if tr_v >= 0.34:
			continue
		var cot_k := 1.0
		if _has_house:
			var hd := Vector2(x - _house_xz.x, z - _house_xz.y).length()
			if hd < 28.0:
				continue
			cot_k = smoothstep(28.0, 48.0, hd)
		# Slope check from height_near finite difference.
		var hx: float = world.height_near(x + 1.0, z) - world.height_near(x - 1.0, z)
		var hz: float = world.height_near(x, z + 1.0) - world.height_near(x, z - 1.0)
		var ny := 2.0 / sqrt(hx * hx + 4.0 + hz * hz)
		if ny <= 0.64:
			continue
		var r0 := _fern_scatter_rnd[r * 4]
		var r1 := _fern_scatter_rnd[r * 4 + 1]
		var r2 := _fern_scatter_rnd[r * 4 + 2]
		var r3 := _fern_scatter_rnd[r * 4 + 3]
		if r3 > 0.94:
			continue
		# Smooth organic forest pockets + trail-verge boost (mirrors FERN_BAKE_FRAG).
		var clump := 0.5 + 0.5 * sin(x * 0.19 + cos(z * 0.17) * 1.6) * cos(z * 0.21 - sin(x * 0.14) * 1.4)
		var clump2 := 0.5 + 0.5 * sin(x * 0.51 + z * 0.43 + 1.3)
		var trail_edge := smoothstep(0.01, 0.14, tr_v) * (1.0 - smoothstep(0.24, 0.36, tr_v))
		var pocket := smoothstep(0.36, 0.64, clump * 0.68 + clump2 * 0.32 + trail_edge * 0.40)
		var dens := smoothstep(0.44, 0.78, bf) * (1.0 - smoothstep(0.08, 0.24, bfl)) * cot_k * smoothstep(0.64, 0.86, ny) * (1.0 - smoothstep(0.18, 0.34, tr_v)) * pocket
		if dens <= 0.14:
			continue
		var s := dens * lerpf(0.34, 1.42, r1 * r1 * 0.58 + r1 * 0.42)
		# Keep trail-verge ferns knee-high so they frame the path cleanly without blocking sightlines.
		s = minf(s, lerpf(s, 0.82, trail_edge))
		var morph_tall := 1.0 if r0 >= 0.54 else 0.0
		var s_rad := s * lerpf(1.24, 0.84, morph_tall) * lerpf(0.84, 1.18, fposmod(r2 * 5.3, 1.0))
		var sy := s * lerpf(0.62, 1.28, morph_tall) * lerpf(0.80, 1.20, r2)
		var yaw := r2 * TAU
		var gv := clampf(0.26 + 0.44 * clump, 0.18, 0.78)
		out.append([x, h - 0.03, z, s_rad, sy, yaw, r0, gv, clump])
	_fern_tile_cache[key] = out
	return out


func _cull_ferns(cp: Vector3, fwd_xz: Vector2 = Vector2.ZERO) -> void:
	var max_d := FERN_RADIUS * _dist_scale
	var r_tiles := int(ceil(max_d / FERN_TILE_SIZE))
	var ctx := int(floor(cp.x / FERN_TILE_SIZE))
	var ctz := int(floor(cp.z / FERN_TILE_SIZE))
	var max_d2 := max_d * max_d
	# Visit tiles nearest-first (weighted toward forward view) so FERN_CAP always populates
	# the visible foreground & trail verge instead of being exhausted by outer tiles behind camera.
	var tiles: Array = []
	for tz in range(ctz - r_tiles, ctz + r_tiles + 1):
		for tx in range(ctx - r_tiles, ctx + r_tiles + 1):
			var cx := (float(tx) + 0.5) * FERN_TILE_SIZE
			var cz := (float(tz) + 0.5) * FERN_TILE_SIZE
			var dx := cx - cp.x
			var dz := cz - cp.z
			var d2 := dx * dx + dz * dz
			var behind_pen := 0.0
			if fwd_xz.length_squared() > 0.1:
				var fdot := dx * fwd_xz.x + dz * fwd_xz.y
				if fdot < -14.0:
					continue
				if fdot < 0.0:
					behind_pen = 900.0
			tiles.append([d2 + behind_pen, tx, tz])
	tiles.sort_custom(func(a: Array, b: Array) -> bool: return float(a[0]) < float(b[0]))
	var n := 0
	var aabb := AABB()
	var has_aabb := false
	for te in tiles:
		var items := _get_fern_tile(int(te[1]), int(te[2]))
		if items.is_empty():
			continue
		for it in items:
			if n >= FERN_CAP:
				break
			var x: float = it[0]
			var y: float = it[1]
			var z: float = it[2]
			var dx := x - cp.x
			var dz := z - cp.z
			if dx * dx + dz * dz > max_d2:
				continue
			var sr: float = it[3]
			var sy: float = it[4]
			var yaw: float = it[5]
			var cy := cos(yaw)
			var s_y := sin(yaw)
			var o := n * 16
			_fern_buf[o + 0] = cy * sr;  _fern_buf[o + 1] = 0.0; _fern_buf[o + 2] = s_y * sr; _fern_buf[o + 3] = x
			_fern_buf[o + 4] = 0.0;      _fern_buf[o + 5] = sy;  _fern_buf[o + 6] = 0.0;      _fern_buf[o + 7] = y
			_fern_buf[o + 8] = -s_y * sr; _fern_buf[o + 9] = 0.0; _fern_buf[o + 10] = cy * sr; _fern_buf[o + 11] = z
			_fern_buf[o + 12] = max_d
			_fern_buf[o + 13] = float(it[6])
			_fern_buf[o + 14] = float(it[7])
			_fern_buf[o + 15] = float(it[8])
			var b := AABB(Vector3(x - sr, y - 0.1, z - sr), Vector3(sr * 2.0, sy + 0.4, sr * 2.0))
			aabb = b if not has_aabb else aabb.merge(b)
			has_aabb = true
			n += 1
		if n >= FERN_CAP:
			break
	_fern_vis = n
	_fern_aabb = aabb
	if n > 0:
		_fern_swap.push(_fern_buf, n)
		for mmi in _fern_swap.mmis:
			mmi.custom_aabb = aabb
	_fern_swap.set_visible(_on and n > 0)


# ---------- 2. Mossy Nurse Logs & Ancient Mossy Stumps ----------
func _build_logs_and_stumps() -> void:
	var ug: Dictionary = world.undergrowth_info()
	if ug.has("logs"):
		for rec in ug.logs:
			_logs.append(rec)
	if ug.has("stumps"):
		for rec in ug.stumps:
			_stumps.append(rec)

	var log_mesh := _build_log_mesh()
	log_mesh.surface_set_material(0, wood_mat)
	var log_cap := maxi(1, mini(48, _logs.size()))
	_log_buf.resize(log_cap * 16)
	_log_swap = SwapMultiMesh.new(self, log_mesh, log_cap, AABB(Vector3(-4000, -500, -4000), Vector3(8000, 3000, 8000)))
	_log_swap.set_visible(false)

	var stump_mesh := _build_stump_mesh()
	stump_mesh.surface_set_material(0, wood_mat)
	var stump_cap := maxi(1, mini(24, _stumps.size()))
	_stump_buf.resize(stump_cap * 16)
	_stump_swap = SwapMultiMesh.new(self, stump_mesh, stump_cap, AABB(Vector3(-4000, -500, -4000), Vector3(8000, 3000, 8000)))
	_stump_swap.set_visible(false)


# Unit mossy nurse log along local X in [-0.5, +0.5], unit radius 1.0:
# tapered weathered trunk + velvet emerald moss blanket + cut end-grain caps + 3 shelf polypores +
# dark humus bed grounding the underside solidly into sloping forest floors.
func _build_log_mesh() -> ArrayMesh:
	var mb := _WoodMB.new()
	var bark := Color(0.28, 0.18, 0.11)
	var end_wood := Color(0.66, 0.50, 0.32)
	var moss := Color(0.12, 0.34, 0.08)
	var shelf := Color(0.84, 0.66, 0.38)

	# Tapered round horizontal trunk (10 sides with smooth radial normals, upper arch rising to
	# +1.30*r and underside sunk to -1.15*r so sloping forest ground never shows a gap under ends).
	const SEGS := 10
	var rings := [
		[-0.50, 1.12, 0.22],
		[ 0.00, 1.06, 0.28],
		[ 0.50, 0.96, 0.22],
	]
	for ri in rings.size() - 1:
		var x0: float = rings[ri][0];     var r0: float = rings[ri][1];     var y0: float = rings[ri][2]
		var x1: float = rings[ri + 1][0]; var r1: float = rings[ri + 1][1]; var y1: float = rings[ri + 1][2]
		for s in SEGS:
			var a0 := float(s) / float(SEGS) * TAU
			var a1 := float(s + 1) / float(SEGS) * TAU
			var c0 := cos(a0); var s0 := sin(a0)
			var c1 := cos(a1); var s1 := sin(a1)
			var sy0 := s0 * (1.30 if s0 < 0.0 else 1.08)
			var sy1 := s1 * (1.30 if s1 < 0.0 else 1.08)
			var p00 := Vector3(x0, y0 + sy0 * r0, c0 * r0)
			var p01 := Vector3(x0, y0 + sy1 * r0, c1 * r0)
			var p11 := Vector3(x1, y1 + sy1 * r1, c1 * r1)
			var p10 := Vector3(x1, y1 + sy0 * r1, c0 * r1)
			var n0 := Vector3(0.0, s0, c0).normalized()
			var n1 := Vector3(0.0, s1, c1).normalized()
			var h0 := clampf(s0 * 0.5 + 0.5, 0.0, 1.0)
			var h1 := clampf(s1 * 0.5 + 0.5, 0.0, 1.0)
			mb.quad_smooth(p00, p10, p11, p01, n0, n0, n1, n1, bark, 0.96, Vector2(0.0, h0), Vector2(0.0, h0), Vector2(0.0, h1), Vector2(0.0, h1))

	# Cut end-grain caps at -0.5 and +0.5.
	for end_i in 2:
		var ex: float = -0.50 if end_i == 0 else 0.50
		var er: float = 1.12 if end_i == 0 else 0.96
		var en := Vector3(-1.0, 0.0, 0.0) if end_i == 0 else Vector3(1.0, 0.0, 0.0)
		var ec := Vector3(ex, 0.22, 0.0)
		for s in SEGS:
			var a0 := float(s) / float(SEGS) * TAU
			var a1 := float(s + 1) / float(SEGS) * TAU
			var s0 := sin(a0); var s1 := sin(a1)
			var v0 := Vector3(ex, 0.22 + s0 * (1.30 if s0 < 0.0 else 1.08) * er, cos(a0) * er)
			var v1 := Vector3(ex, 0.22 + s1 * (1.30 if s1 < 0.0 else 1.08) * er, cos(a1) * er)
			mb.tri(ec, v0, v1, en, end_wood, 1.0, Vector2(0.35, 0.55), Vector2(0.35, 0.55), Vector2(0.35, 0.55))

	# Plush sculpted velvet moss blanket draping organically over the upper arch.
	const MSEGS := 6
	var moss_rings := [
		[-0.38, 1.18, 0.26],
		[-0.12, 1.24, 0.34],
		[ 0.15, 1.20, 0.32],
		[ 0.36, 1.08, 0.24],
	]
	for ri in moss_rings.size() - 1:
		var x0: float = moss_rings[ri][0];     var r0: float = moss_rings[ri][1];     var y0: float = moss_rings[ri][2]
		var x1: float = moss_rings[ri + 1][0]; var r1: float = moss_rings[ri + 1][1]; var y1: float = moss_rings[ri + 1][2]
		for s in MSEGS:
			var a0 := lerpf(0.28, PI - 0.28, float(s) / float(MSEGS))
			var a1 := lerpf(0.28, PI - 0.28, float(s + 1) / float(MSEGS))
			var p00 := Vector3(x0, y0 + sin(a0) * r0, cos(a0) * r0)
			var p01 := Vector3(x0, y0 + sin(a1) * r0, cos(a1) * r0)
			var p11 := Vector3(x1, y1 + sin(a1) * r1, cos(a1) * r1)
			var p10 := Vector3(x1, y1 + sin(a0) * r1, cos(a0) * r1)
			var n0 := Vector3(0.0, sin(a0), cos(a0)).normalized()
			var n1 := Vector3(0.0, sin(a1), cos(a1)).normalized()
			mb.quad_smooth(p00, p10, p11, p01, n0, n0, n1, n1, moss, 1.0, Vector2(0.85, 0.85), Vector2(0.85, 0.85), Vector2(0.85, 0.85), Vector2(0.85, 0.85))

	# 3 compact semicircular fan polypore fungi sprouting on the sunlit bark flank (18 tris total;
	# fw kept narrow in X because X is scaled by log length ~4 m).
	for sp in [[-0.22, 0.42, 0.96, 0.024, 0.36], [0.05, 0.56, 0.92, 0.030, 0.44], [0.24, 0.36, 0.94, 0.022, 0.34]]:
		var fx: float = sp[0]; var fy: float = sp[1]; var fz: float = sp[2]
		var fw: float = sp[3]; var fout: float = sp[4]
		var p_root := Vector3(fx, fy, fz)
		var fan: Array[Vector3] = [
			Vector3(fx - fw, fy + 0.02, fz + fout * 0.45),
			Vector3(fx - fw * 0.48, fy + 0.05, fz + fout),
			Vector3(fx + fw * 0.48, fy + 0.05, fz + fout),
			Vector3(fx + fw, fy + 0.02, fz + fout * 0.45),
		]
		for k in 3:
			mb.tri(p_root, fan[k], fan[k + 1], Vector3.UP, shelf, 1.0, Vector2(0.35, 0.72), Vector2(0.35, 0.72), Vector2(0.35, 0.72))
			mb.tri(p_root + Vector3(0.0, -0.06, 0.0), fan[k + 1], fan[k], Vector3.DOWN, shelf * 0.78, 0.85, Vector2(0.35, 0.65), Vector2(0.35, 0.65), Vector2(0.35, 0.65))

	_log_tris = mb.tri_count
	return mb.finish()


# Unit mossy woodland stump (radius 1.0, height 1.0):
# flared tapered trunk + pale cut top + velvet moss dome + 4 splayed grounding root flares.
func _build_stump_mesh() -> ArrayMesh:
	var mb := _WoodMB.new()
	var bark := Color(0.32, 0.22, 0.14)
	var top_wood := Color(0.70, 0.56, 0.36)
	var moss := Color(0.14, 0.38, 0.09)

	const SEGS := 8
	for s in SEGS:
		var a0 := float(s) / float(SEGS) * TAU
		var a1 := float(s + 1) / float(SEGS) * TAU
		var c0 := cos(a0); var s0 := sin(a0)
		var c1 := cos(a1); var s1 := sin(a1)
		var b0 := Vector3(c0 * 1.26, -0.25, s0 * 1.26)
		var b1 := Vector3(c1 * 1.26, -0.25, s1 * 1.26)
		var t0 := Vector3(c0 * 0.86, 1.0, s0 * 0.86)
		var t1 := Vector3(c1 * 0.86, 1.0, s1 * 0.86)
		var n := Vector3(c0 + c1, 0.22, s0 + s1).normalized()
		mb.quad(b0, b1, t1, t0, n, bark, 0.95, Vector2(0.0, 0.0), Vector2(0.0, 0.0), Vector2(0.0, 1.0), Vector2(0.0, 1.0))
		mb.tri(Vector3(0.0, 1.0, 0.0), t0, t1, Vector3.UP, top_wood, 1.0, Vector2(0.35, 0.95), Vector2(0.35, 0.95), Vector2(0.35, 0.95))

	# Asymmetrical moss cushion perched on one half of the cut top.
	mb.box(Vector3(1.05, 0.26, 0.95), Vector3(0.24, 1.06, 0.10), moss, 1.0, 0.85, 0.95)
	mb.box(Vector3(0.72, 0.20, 0.72), Vector3(-0.18, 1.02, -0.18), moss, 1.0, 0.85, 0.95)

	# 4 grounding root buttresses radiating into the forest floor.
	for r in 4:
		var a := float(r) * (PI * 0.5) + 0.35
		var d := Vector3(cos(a), 0.0, sin(a))
		var sd := Vector3(-d.z, 0.0, d.x)
		var p_in := d * 0.72 + Vector3(0.0, 0.42, 0.0)
		var p_out := d * 1.65 + Vector3(0.0, -0.18, 0.0)
		var rw := 0.24
		var n_top := (Vector3.UP + d * 0.45).normalized()
		mb.quad(p_in - sd * rw, p_in + sd * rw, p_out + sd * (rw * 0.7), p_out - sd * (rw * 0.7), n_top, bark, 0.86, Vector2(0.0, 0.38), Vector2(0.0, 0.38), Vector2(0.0, 0.02), Vector2(0.0, 0.02))
		mb.quad(p_in + sd * rw, p_out + sd * (rw * 0.7), p_out + sd * (rw * 0.7) + Vector3(0.0, -0.30, 0.0), p_in + sd * rw + Vector3(0.0, -0.55, 0.0), sd, bark, 0.78, Vector2(0.0, 0.25), Vector2(0.0, 0.0), Vector2(0.0, 0.0), Vector2(0.0, 0.0))
		mb.quad(p_out - sd * (rw * 0.7), p_in - sd * rw, p_in - sd * rw + Vector3(0.0, -0.55, 0.0), p_out - sd * (rw * 0.7) + Vector3(0.0, -0.30, 0.0), -sd, bark, 0.78, Vector2(0.0, 0.0), Vector2(0.0, 0.25), Vector2(0.0, 0.0), Vector2(0.0, 0.0))

	_stump_tris = mb.tri_count
	return mb.finish()


func _cull_logs(cp: Vector3) -> void:
	if _logs.is_empty():
		_log_vis = 0
		return
	var max_d := LOG_DIST * _dist_scale
	var max_d2 := max_d * max_d
	var cap := _log_buf.size() / 16
	var n := 0
	var aabb := AABB()
	var has_aabb := false
	for rec in _logs:
		if n >= cap:
			break
		var x: float = float(rec[0])
		var y: float = float(rec[1])
		var z: float = float(rec[2])
		var dx := x - cp.x
		var dz := z - cp.z
		if dx * dx + dz * dz > max_d2:
			continue
		var ry: float = float(rec[3])
		var slope: float = float(rec[4])
		var ln: float = float(rec[5])
		var rad: float = float(rec[6])
		var seed: float = float(rec[7])
		var cs := cos(slope)
		var sn := sin(slope)
		var x_axis := Vector3(cos(ry) * cs, sn, -sin(ry) * cs).normalized()
		var z_axis := x_axis.cross(Vector3.UP).normalized()
		if z_axis.length_squared() < 1e-4:
			z_axis = Vector3.BACK
		var y_axis := z_axis.cross(x_axis).normalized()
		var bx := x_axis * ln
		var by := y_axis * rad
		var bz := z_axis * rad
		var o := n * 16
		_log_buf[o + 0] = bx.x; _log_buf[o + 1] = by.x; _log_buf[o + 2] = bz.x; _log_buf[o + 3] = x
		_log_buf[o + 4] = bx.y; _log_buf[o + 5] = by.y; _log_buf[o + 6] = bz.y; _log_buf[o + 7] = y
		_log_buf[o + 8] = bx.z; _log_buf[o + 9] = by.z; _log_buf[o + 10] = bz.z; _log_buf[o + 11] = z
		_log_buf[o + 12] = max_d
		_log_buf[o + 13] = seed
		_log_buf[o + 14] = 0.35 + 0.35 * seed
		_log_buf[o + 15] = 0.0
		var r_ext := maxf(ln * 0.55, rad * 1.4)
		var b := AABB(Vector3(x - r_ext, y - rad * 1.5, z - r_ext), Vector3(r_ext * 2.0, rad * 3.2, r_ext * 2.0))
		aabb = b if not has_aabb else aabb.merge(b)
		has_aabb = true
		n += 1
	_log_vis = n
	_log_aabb = aabb
	if n > 0:
		_log_swap.push(_log_buf, n)
		for mmi in _log_swap.mmis:
			mmi.custom_aabb = aabb
	_log_swap.set_visible(_on and n > 0)


func _cull_stumps(cp: Vector3) -> void:
	if _stumps.is_empty():
		_stump_vis = 0
		return
	var max_d := STUMP_DIST * _dist_scale
	var max_d2 := max_d * max_d
	var cap := _stump_buf.size() / 16
	var n := 0
	var aabb := AABB()
	var has_aabb := false
	for rec in _stumps:
		if n >= cap:
			break
		var x: float = float(rec[0])
		var y: float = float(rec[1])
		var z: float = float(rec[2])
		var dx := x - cp.x
		var dz := z - cp.z
		if dx * dx + dz * dz > max_d2:
			continue
		var rad: float = float(rec[3])
		var h: float = float(rec[4])
		var ry: float = float(rec[5])
		var seed: float = float(rec[6])
		var cy := cos(ry)
		var sy := sin(ry)
		var o := n * 16
		_stump_buf[o + 0] = cy * rad;  _stump_buf[o + 1] = 0.0; _stump_buf[o + 2] = sy * rad; _stump_buf[o + 3] = x
		_stump_buf[o + 4] = 0.0;       _stump_buf[o + 5] = h;   _stump_buf[o + 6] = 0.0;      _stump_buf[o + 7] = y
		_stump_buf[o + 8] = -sy * rad; _stump_buf[o + 9] = 0.0; _stump_buf[o + 10] = cy * rad; _stump_buf[o + 11] = z
		_stump_buf[o + 12] = max_d
		_stump_buf[o + 13] = seed
		_stump_buf[o + 14] = 0.35 + 0.35 * seed
		_stump_buf[o + 15] = 0.0
		var r_ext := rad * 1.8
		var b := AABB(Vector3(x - r_ext, y - 0.3, z - r_ext), Vector3(r_ext * 2.0, h + 0.6, r_ext * 2.0))
		aabb = b if not has_aabb else aabb.merge(b)
		has_aabb = true
		n += 1
	_stump_vis = n
	_stump_aabb = aabb
	if n > 0:
		_stump_swap.push(_stump_buf, n)
		for mmi in _stump_swap.mmis:
			mmi.custom_aabb = aabb
	_stump_swap.set_visible(_on and n > 0)


# ---------- 3. High-Readability Mushrooms (Toadstools + Chanterelles in 1 SwapMultiMesh) ----------
func _build_mushrooms() -> void:
	var md: Dictionary = world.load_mushrooms()
	if not md.is_empty():
		_mush_count = int(md.count)
		_mush_x = md.x; _mush_y = md.y; _mush_z = md.z
		_mush_sc = md.sc; _mush_sh = md.sh; _mush_cr = md.cap_r
		_mush_tilt = md.tilt; _mush_rot = md.rot; _mush_golden = md.golden
	var mesh := _build_mushroom_mesh()
	mesh.surface_set_material(0, mush_mat)
	var cap := maxi(1, mini(160, _mush_count))
	_mush_buf.resize(cap * 16)
	_mush_swap = SwapMultiMesh.new(self, mesh, cap, AABB(Vector3(-4000, -500, -4000), Vector3(8000, 3000, 8000)))
	_mush_swap.set_visible(false)


# Unit mushroom mesh (~56 tris): humus contact pad (UV.x=0), tapered stem (UV.x=0.4),
# and hemispherical dome cap + underside gill disc (UV.x=1.0).
func _build_mushroom_mesh() -> ArrayMesh:
	var pos := PackedVector3Array()
	var nrm := PackedVector3Array()
	var uv := PackedVector2Array()
	var idx := PackedInt32Array()

	var push_tri := func(v0: Vector3, v1: Vector3, v2: Vector3, n: Vector3, u0: Vector2, u1: Vector2, u2: Vector2) -> void:
		var flip := (v2 - v0).cross(v1 - v0).dot(n) < 0.0
		var base_i := pos.size()
		if flip:
			pos.append_array([v0, v2, v1])
			uv.append_array([u0, u2, u1])
		else:
			pos.append_array([v0, v1, v2])
			uv.append_array([u0, u1, u2])
		nrm.append_array([n, n, n])
		idx.append_array([base_i, base_i + 1, base_i + 2])

	const SEGS := 6
	# 1. Grounding humus contact pad (6 tris).
	var pad_c := Vector3(0.0, 1.0, 0.0)
	for s in SEGS:
		var a0 := float(s) / float(SEGS) * TAU
		var a1 := float(s + 1) / float(SEGS) * TAU
		push_tri.call(pad_c, Vector3(cos(a0), 0.2, sin(a0)), Vector3(cos(a1), 0.2, sin(a1)), Vector3.UP, Vector2(0.0, 0.5), Vector2(0.0, 0.0), Vector2(0.0, 0.0))

	# 2. Tapered stem (12 tris).
	for s in SEGS:
		var a0 := float(s) / float(SEGS) * TAU
		var a1 := float(s + 1) / float(SEGS) * TAU
		var c0 := cos(a0); var s0 := sin(a0)
		var c1 := cos(a1); var s1 := sin(a1)
		var b0 := Vector3(c0 * 1.15, 0.0, s0 * 1.15)
		var b1 := Vector3(c1 * 1.15, 0.0, s1 * 1.15)
		var t0 := Vector3(c0 * 0.78, 1.0, s0 * 0.78)
		var t1 := Vector3(c1 * 0.78, 1.0, s1 * 0.78)
		var n := Vector3(c0 + c1, 0.15, s0 + s1).normalized()
		push_tri.call(b0, b1, t1, n, Vector2(0.4, 0.0), Vector2(0.4, 0.0), Vector2(0.4, 1.0))
		push_tri.call(b0, t1, t0, n, Vector2(0.4, 0.0), Vector2(0.4, 1.0), Vector2(0.4, 1.0))

	# 3. Domed cap (2 rings x 6 segs + apex + underside gills = 24 tris -> 42 tris total).
	var cap_rings := [
		[1.00, 0.00],
		[0.64, 0.74],
	]
	var apex := Vector3(0.0, 1.0, 0.0)
	for ri in cap_rings.size() - 1:
		var r0: float = cap_rings[ri][0];     var y0: float = cap_rings[ri][1]
		var r1: float = cap_rings[ri + 1][0]; var y1: float = cap_rings[ri + 1][1]
		for s in SEGS:
			var a0 := float(s) / float(SEGS) * TAU
			var a1 := float(s + 1) / float(SEGS) * TAU
			var c0 := cos(a0); var s0 := sin(a0)
			var c1 := cos(a1); var s1 := sin(a1)
			var p00 := Vector3(c0 * r0, y0, s0 * r0)
			var p01 := Vector3(c1 * r0, y0, s1 * r0)
			var p11 := Vector3(c1 * r1, y1, s1 * r1)
			var p10 := Vector3(c0 * r1, y1, s0 * r1)
			var n := (p00 + p01 + p10 + p11).normalized()
			push_tri.call(p00, p01, p11, n, Vector2(1.0, y0), Vector2(1.0, y0), Vector2(1.0, y1))
			push_tri.call(p00, p11, p10, n, Vector2(1.0, y0), Vector2(1.0, y1), Vector2(1.0, y1))
	var top_r: float = cap_rings[cap_rings.size() - 1][0]
	var top_y: float = cap_rings[cap_rings.size() - 1][1]
	for s in SEGS:
		var a0 := float(s) / float(SEGS) * TAU
		var a1 := float(s + 1) / float(SEGS) * TAU
		var v0 := Vector3(cos(a0) * top_r, top_y, sin(a0) * top_r)
		var v1 := Vector3(cos(a1) * top_r, top_y, sin(a1) * top_r)
		push_tri.call(apex, v0, v1, Vector3.UP, Vector2(1.0, 1.0), Vector2(1.0, top_y), Vector2(1.0, top_y))
		# Underside gill disc so low angles never see a hollow cap.
		var g0 := Vector3(cos(a0), 0.0, sin(a0))
		var g1 := Vector3(cos(a1), 0.0, sin(a1))
		push_tri.call(Vector3(0.0, -0.05, 0.0), g1, g0, Vector3.DOWN, Vector2(1.0, 0.0), Vector2(1.0, 0.0), Vector2(1.0, 0.0))

	_mush_tris = idx.size() / 3
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = pos
	arrays[Mesh.ARRAY_NORMAL] = nrm
	arrays[Mesh.ARRAY_TEX_UV] = uv
	arrays[Mesh.ARRAY_INDEX] = idx
	var m := ArrayMesh.new()
	m.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return m


func _cull_mushrooms(cp: Vector3) -> void:
	if _mush_count == 0:
		_mush_vis = 0
		return
	var max_d := MUSH_DIST * _dist_scale
	var max_d2 := max_d * max_d
	var cap := _mush_buf.size() / 16
	var n := 0
	var aabb := AABB()
	var has_aabb := false
	for i in _mush_count:
		if n >= cap:
			break
		var x := _mush_x[i]
		var z := _mush_z[i]
		var dx := x - cp.x
		var dz := z - cp.z
		if dx * dx + dz * dz > max_d2:
			continue
		var y := _mush_y[i]
		var sh := _mush_sh[i]
		var cr := _mush_cr[i]
		var tilt := _mush_tilt[i]
		var rot := _mush_rot[i]
		var b := Basis(Vector3.UP, rot) * Basis(Vector3.BACK, tilt)
		var o := n * 16
		_mush_buf[o + 0] = b.x.x; _mush_buf[o + 1] = b.y.x; _mush_buf[o + 2] = b.z.x; _mush_buf[o + 3] = x
		_mush_buf[o + 4] = b.x.y; _mush_buf[o + 5] = b.y.y; _mush_buf[o + 6] = b.z.y; _mush_buf[o + 7] = y
		_mush_buf[o + 8] = b.x.z; _mush_buf[o + 9] = b.y.z; _mush_buf[o + 10] = b.z.z; _mush_buf[o + 11] = z
		_mush_buf[o + 12] = max_d
		_mush_buf[o + 13] = 1.0 if _mush_golden[i] != 0 else 0.0
		_mush_buf[o + 14] = sh
		_mush_buf[o + 15] = cr
		var ext := maxf(cr * 1.4, sh + cr)
		var bb := AABB(Vector3(x - ext, y - 0.08, z - ext), Vector3(ext * 2.0, ext * 1.6, ext * 2.0))
		aabb = bb if not has_aabb else aabb.merge(bb)
		has_aabb = true
		n += 1
	_mush_vis = n
	_mush_aabb = aabb
	if n > 0:
		_mush_swap.push(_mush_buf, n)
		for mmi in _mush_swap.mmis:
			mmi.custom_aabb = aabb
	_mush_swap.set_visible(_on and n > 0)


# ---------- Winding-verified vertex-colored wood/moss mesh builder ----------
class _WoodMB:
	var pos := PackedVector3Array()
	var nrm := PackedVector3Array()
	var uv := PackedVector2Array()
	var col := PackedColorArray()
	var idx := PackedInt32Array()
	var tri_count := 0

	func tri(v0: Vector3, v1: Vector3, v2: Vector3, n: Vector3, rgb: Color, ao: float, u0: Vector2, u1: Vector2, u2: Vector2) -> void:
		var wn := n.normalized()
		var flip := (v2 - v0).cross(v1 - v0).dot(wn) < 0.0
		var base := pos.size()
		var c := Color(rgb.r, rgb.g, rgb.b, ao)
		if flip:
			pos.append_array([v0, v2, v1])
			uv.append_array([u0, u2, u1])
		else:
			pos.append_array([v0, v1, v2])
			uv.append_array([u0, u1, u2])
		nrm.append_array([wn, wn, wn])
		col.append_array([c, c, c])
		idx.append_array([base, base + 1, base + 2])
		tri_count += 1

	func quad(a: Vector3, b: Vector3, c: Vector3, d: Vector3, n: Vector3, rgb: Color, ao: float, ua: Vector2, ub: Vector2, uc: Vector2, ud: Vector2) -> void:
		tri(a, b, c, n, rgb, ao, ua, ub, uc)
		tri(a, c, d, n, rgb, ao, ua, uc, ud)

	func tri_smooth(v0: Vector3, v1: Vector3, v2: Vector3, n0: Vector3, n1: Vector3, n2: Vector3, rgb: Color, ao: float, u0: Vector2, u1: Vector2, u2: Vector2) -> void:
		var navg := (n0 + n1 + n2).normalized()
		var flip := (v2 - v0).cross(v1 - v0).dot(navg) < 0.0
		var base := pos.size()
		var c := Color(rgb.r, rgb.g, rgb.b, ao)
		if flip:
			pos.append_array([v0, v2, v1])
			nrm.append_array([n0.normalized(), n2.normalized(), n1.normalized()])
			uv.append_array([u0, u2, u1])
		else:
			pos.append_array([v0, v1, v2])
			nrm.append_array([n0.normalized(), n1.normalized(), n2.normalized()])
			uv.append_array([u0, u1, u2])
		col.append_array([c, c, c])
		idx.append_array([base, base + 1, base + 2])
		tri_count += 1

	func quad_smooth(a: Vector3, b: Vector3, c: Vector3, d: Vector3, na: Vector3, nb: Vector3, nc: Vector3, nd: Vector3, rgb: Color, ao: float, ua: Vector2, ub: Vector2, uc: Vector2, ud: Vector2) -> void:
		tri_smooth(a, b, c, na, nb, nc, rgb, ao, ua, ub, uc)
		tri_smooth(a, c, d, na, nc, nd, rgb, ao, ua, uc, ud)

	func box(size: Vector3, center: Vector3, rgb: Color, ao: float, part_u: float, h_v: float) -> void:
		var hx := size.x * 0.5; var hy := size.y * 0.5; var hz := size.z * 0.5
		var p: Array[Vector3] = [
			center + Vector3(-hx, -hy, -hz), center + Vector3(hx, -hy, -hz),
			center + Vector3(hx, hy, -hz),   center + Vector3(-hx, hy, -hz),
			center + Vector3(-hx, -hy, hz),  center + Vector3(hx, -hy, hz),
			center + Vector3(hx, hy, hz),    center + Vector3(-hx, hy, hz),
		]
		var u := Vector2(part_u, h_v)
		for f in [
			[4, 5, 6, 7, Vector3(0, 0, 1)], [1, 0, 3, 2, Vector3(0, 0, -1)],
			[5, 1, 2, 6, Vector3(1, 0, 0)], [0, 4, 7, 3, Vector3(-1, 0, 0)],
			[7, 6, 2, 3, Vector3(0, 1, 0)], [0, 1, 5, 4, Vector3(0, -1, 0)],
		]:
			quad(p[f[0]], p[f[1]], p[f[2]], p[f[3]], f[4], rgb, ao, u, u, u, u)

	func finish() -> ArrayMesh:
		var custom0 := PackedFloat32Array()
		custom0.resize(col.size() * 4)
		for i in col.size():
			var c := col[i]
			var o := i * 4
			custom0[o] = c.r; custom0[o + 1] = c.g; custom0[o + 2] = c.b; custom0[o + 3] = c.a
		var arrays := []
		arrays.resize(Mesh.ARRAY_MAX)
		arrays[Mesh.ARRAY_VERTEX] = pos
		arrays[Mesh.ARRAY_NORMAL] = nrm
		arrays[Mesh.ARRAY_TEX_UV] = uv
		arrays[Mesh.ARRAY_CUSTOM0] = custom0
		arrays[Mesh.ARRAY_INDEX] = idx
		var m := ArrayMesh.new()
		m.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays, [], {}, Mesh.ARRAY_CUSTOM_RGBA_FLOAT << Mesh.ARRAY_FORMAT_CUSTOM0_SHIFT)
		return m
