extends Node3D

# Stillwater's meadow grass and wildflowers at the `low` tier (src/world/grass.js,
# src/world/grassTiles.js, src/engine/quality.js).
#
# Same tile scheme as the game: a fixed world grid (grass 8 m, flowers 12 m tiles), the same
# per-plant scatter on every tile (world/veg_scatter.gd, bit-exact with Stillwater, mirrored per
# tile), and the tier draws the first N ranks. Every tile whose box touches the ring around the
# camera gets an atlas slot; its static per-blade fields (height, density, normal, tallness, yaw,
# colour) are baked once on the GPU when it enters, then the blade shaders read them per vertex.
# Grass tiles nearer than 16 m draw 1664 four-segment blades (7 triangles), the rest 1024
# two-segment ones (3 triangles, wider); near-only blades fade out before a tile switches.
#
# Godot difference: Stillwater draws one mesh per tile; here all near tiles are one instanced draw
# (a tile is an instance of a mesh holding all its blades), likewise far tiles and flowers, culled
# per tile on the CPU. Triangles are the same; draw calls drop from one per tile to three.
#
# The bake renders into a SubViewport (RGBA8; tests/bake_probe.gd checks the round trip is
# byte-exact). A tile is drawn from the frame after its bake.

const VegScatter := preload("res://world/veg_scatter.gd")
const SwapMultiMesh := preload("res://systems/swap_multimesh.gd")
const Flags := preload("res://systems/flags.gd")

# quality.js low: grassRadius 30, grassNear 1664, grassFar 1024, grassNearLod 16,
# grassFarWidthScale 1.32, flowers 576 (flower radius min(34, 0.75 * grassRadius)).
# Layouts (tile size, slot width, max count, seed) are grass.js GRASS_LAYOUT / FLOWER_LAYOUT.
const GRASS := {
	"tile": 8.0, "slot_w": 64, "max_count": 2432, "seed": 1337, "fields": 3,
	"radius": 30.0, "near": 1664, "far": 1024, "near_lod": 16.0, "far_width": 1.32,
	"near_tris": 7, "far_tris": 3, "verts_near": 9, "verts_far": 5,
	# Tile box padding (grass.js boundsPad) and the empty test: ground entirely under water - 1 m.
	"pad_xz": 1.8, "pad_down": 0.6, "pad_up": 2.5, "empty_below": -1.0,
}
const FLOWERS := {
	"tile": 12.0, "slot_w": 32, "max_count": 1440, "seed": 4242, "fields": 2,
	"radius": 22.5, "near": 576, "far": 576, "near_lod": INF, "far_width": 1.0,
	"near_tris": 4, "far_tris": 4,
	"pad_xz": 0.9, "pad_down": 0.5, "pad_up": 2.0, "empty_below": 0.2,
}
# Grass and flowers each enter tiles; this per-ring time budget keeps the pair under ~2 ms.
const ENTER_BUDGET_US := 900
const NEW_TILES_PER_FRAME := 4
# Height in the atlas is 16 bits over 64 m above this much under the tile's lowest sample.
const BASE_DROP := 4.0
# Live walk/turn skip thresholds and strictly wider frustum padding so edge blades never pop.
const MOVE_THRESH_SQ := 0.5 * 0.5
const ROT_COS := 0.9998  # cos(0.020 rad)
const PAD_M := 0.55
const PAD_ANG := 0.021

var world: RefCounted
var grass: Ring
var flowers: Ring
var _on := true
# ?probe=terrain turns one ring's updates (and so its bakes) off to test each bake on its own.
var update_grass := true
var update_flowers := true
var _grass_on := true
var _flowers_on := true
var frozen := false
var _frame := 0
var last_tris := 0
var last_draws := 0
var density := 1.0
var prof_us := 0
var push_us := 0
var grass_us := 0
var flowers_us := 0
var uniform_us := 0
# This frame's work, for walk checks: tiles that entered, ring selection and entry time.
var detail := {}
var _pl := PackedFloat64Array()
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
	process_priority = 100
	var t0 := Time.get_ticks_msec()
	grass = Ring.new(self, GRASS, "res://shaders/grass_bake.gdshader", "res://shaders/grass.gdshader", _grass_meshes())
	grass.draw_mat.set_shader_parameter("lod_start", maxf(8.0, GRASS.near_lod - 6.0))
	grass.draw_mat.set_shader_parameter("lod_end", GRASS.near_lod)
	grass.draw_mat.set_shader_parameter("far_count", float(GRASS.far))
	grass.draw_mat.set_shader_parameter("far_width_scale", GRASS.far_width)
	var gdbg := Flags.value("grassdbg")
	if gdbg == "1" or (Flags.has("grassdbg") and gdbg != "0"):
		grass.draw_mat.set_shader_parameter("dbg_tallness", 1.0)
	var fm := _flower_mesh()
	flowers = Ring.new(self, FLOWERS, "res://shaders/flower_bake.gdshader", "res://shaders/flower.gdshader", [fm, fm])
	print("GRASS built in %d ms: grass atlas %s, flower atlas %s" % [Time.get_ticks_msec() - t0, grass.vp.size, flowers.vp.size])


func materials() -> Array[ShaderMaterial]:
	return [grass.draw_mat, flowers.draw_mat]


# Density lever: every tile draws the first round(f * N) ranks, as a lower Stillwater tier does
# (grassNear / grassFar / flowers). The bake keeps all of the tier's ranks.
func set_density(f: float) -> void:
	if is_equal_approx(f, density):
		return
	density = f
	var sc: Dictionary = VegScatter.generate(GRASS.max_count, GRASS.tile, GRASS.seed)
	var n_near := maxi(1, roundi(GRASS.near * f))
	var n_far := maxi(1, roundi(GRASS.far * f))
	grass.set_meshes(_blade_mesh(sc, n_near, 4), _blade_mesh(sc, n_far, 2), n_near, n_far)
	grass.draw_mat.set_shader_parameter("far_count", float(n_far))
	var fm := _flower_mesh(maxi(1, roundi(FLOWERS.near * f)))
	flowers.set_meshes(fm, fm, maxi(1, roundi(FLOWERS.near * f)), maxi(1, roundi(FLOWERS.far * f)))
	_cam_valid = false


func is_on() -> bool:
	return _on


func set_on(on: bool) -> void:
	_on = on
	_sync_ring_vis()
	_cam_valid = false
	if not on:
		last_tris = 0
		last_draws = 0


func set_grass_on(on: bool) -> void:
	_grass_on = on
	_sync_ring_vis()
	_cam_valid = false
	if not on:
		grass.last_tris = 0
		grass.last_draws = 0
		last_tris = flowers.last_tris if (_on and _flowers_on) else 0
		last_draws = flowers.last_draws if (_on and _flowers_on) else 0


func set_flowers_on(on: bool) -> void:
	_flowers_on = on
	_sync_ring_vis()
	_cam_valid = false
	if not on:
		flowers.last_tris = 0
		flowers.last_draws = 0
		last_tris = grass.last_tris if (_on and _grass_on) else 0
		last_draws = grass.last_draws if (_on and _grass_on) else 0


func _sync_ring_vis() -> void:
	var g_vis := _on and _grass_on
	var f_vis := _on and _flowers_on
	grass.draw_n.set_visible(g_vis)
	grass.draw_f.set_visible(g_vis)
	flowers.draw_n.set_visible(f_vis)
	flowers.draw_f.set_visible(f_vis)


func set_frozen(v: bool) -> void:
	frozen = v


func _process(_delta: float) -> void:
	var t0 := Time.get_ticks_usec()
	var cam := get_viewport().get_camera_3d()
	push_us = 0
	grass_us = 0
	flowers_us = 0
	uniform_us = 0
	if _on and not frozen and cam != null:
		_frame += 1
		update_rings(cam, false, true)
	prof_us = Time.get_ticks_usec() - t0


# assume_baked: count tiles as drawable without waiting for a bake (headless budget test).
func update_rings(cam: Camera3D, assume_baked: bool, allow_pad: bool = false) -> void:
	var xform := cam.global_transform
	var pos := xform.origin
	var fwd := -xform.basis.z
	var up := xform.basis.y
	var vp_sz := cam.get_viewport().get_visible_rect().size
	if assume_baked or not _cam_valid:
		_still_frames = 2
	elif xform == _prev_xform:
		_still_frames = mini(_still_frames + 1, 2)
	else:
		_still_frames = 0
	_prev_xform = xform
	var pad := allow_pad and not assume_baked and _still_frames < 2
	var cam_same := false
	if not assume_baked and _cam_valid and _last_pad == pad and cam.fov == _last_fov and cam.far == _last_far and vp_sz == _last_vp:
		if pad:
			cam_same = pos.distance_squared_to(_last_pos) < MOVE_THRESH_SQ and fwd.dot(_last_fwd) >= ROT_COS and up.dot(_last_up) >= ROT_COS
		else:
			cam_same = xform == _last_xform
	if cam_same:
		var g_busy := _grass_on and update_grass and grass.needs_work()
		var f_busy := _flowers_on and update_flowers and flowers.needs_work()
		if not g_busy and not f_busy:
			return
	if not cam_same:
		_cam_valid = not assume_baked
		_last_pad = pad
		_last_xform = xform
		_last_pos = pos
		_last_fwd = fwd
		_last_up = up
		_last_fov = cam.fov
		_last_far = cam.far
		_last_vp = vp_sz
		var planes := cam.get_frustum()
		var pn := planes.size()
		if _pl.size() != pn * 4:
			_pl.resize(pn * 4)
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
			var j := i * 4
			_pl[j] = n.x
			_pl[j + 1] = n.y
			_pl[j + 2] = n.z
			_pl[j + 3] = d
	var p := pos
	if _grass_on and update_grass:
		var tg := Time.get_ticks_usec()
		grass.update(p, _pl, _frame, assume_baked)
		grass_us = Time.get_ticks_usec() - tg
	elif not _grass_on:
		grass.last_tris = 0
		grass.last_draws = 0
		grass.push_us = 0
		grass_us = 0
	if _flowers_on and update_flowers:
		var tf := Time.get_ticks_usec()
		flowers.update(p, _pl, _frame, assume_baked)
		flowers_us = Time.get_ticks_usec() - tf
	elif not _flowers_on:
		flowers.last_tris = 0
		flowers.last_draws = 0
		flowers.push_us = 0
		flowers_us = 0
	last_tris = grass.last_tris + flowers.last_tris
	last_draws = grass.last_draws + flowers.last_draws
	push_us = grass.push_us + flowers.push_us
	detail["grass_new"] = grass.added
	detail["flower_new"] = flowers.added
	detail["ring_us"] = grass.ring_us + flowers.ring_us
	detail["enter_us"] = grass.enter_us + flowers.enter_us


# Stillwater's bladeGeometry(segs) for every rank below `count`, merged into one tile mesh.
func _grass_meshes() -> Array[ArrayMesh]:
	var sc: Dictionary = VegScatter.generate(GRASS.max_count, GRASS.tile, GRASS.seed)
	return [_blade_mesh(sc, GRASS.near, 4), _blade_mesh(sc, GRASS.far, 2)]


func _blade_mesh(sc: Dictionary, count: int, segs: int) -> ArrayMesh:
	var verts := PackedVector3Array()
	var c0 := PackedFloat32Array()
	var c1 := PackedFloat32Array()
	var idx := PackedInt32Array()
	var local: PackedFloat32Array = sc.local
	var rnd: PackedFloat32Array = sc.rnd
	var per := segs * 2 + 1
	for b in count:
		var base := b * per
		for i in segs:
			var y := float(i) / segs
			verts.append(Vector3(-0.5, y, 0.0))
			verts.append(Vector3(0.5, y, 0.0))
		verts.append(Vector3(0.0, 1.0, 0.0))
		for v in per:
			c0.append_array([local[b * 2], local[b * 2 + 1], float(b), 0.0])
			c1.append_array([rnd[b * 4], rnd[b * 4 + 1], rnd[b * 4 + 2], rnd[b * 4 + 3]])
		for i in segs - 1:
			var a := base + i * 2
			idx.append_array([a, a + 1, a + 2, a + 1, a + 3, a + 2])
		var t := base + (segs - 1) * 2
		idx.append_array([t, t + 1, base + segs * 2])
	return _mesh(verts, PackedVector2Array(), c0, c1, idx)


# Stillwater's flowerGeometry: a stem quad (part 0) and a head quad (part 1) per rank.
func _flower_mesh(count: int = FLOWERS.near) -> ArrayMesh:
	var sc: Dictionary = VegScatter.generate(FLOWERS.max_count, FLOWERS.tile, FLOWERS.seed)
	var local: PackedFloat32Array = sc.local
	var rnd: PackedFloat32Array = sc.rnd
	var verts := PackedVector3Array()
	var uvs := PackedVector2Array()
	var c0 := PackedFloat32Array()
	var c1 := PackedFloat32Array()
	var idx := PackedInt32Array()
	var quad_uv := [Vector2(0, 0), Vector2(1, 0), Vector2(0, 1), Vector2(1, 1)]
	for b in count:
		var base := b * 8
		verts.append_array([Vector3(-0.5, 0, 0), Vector3(0.5, 0, 0), Vector3(-0.5, 1, 0), Vector3(0.5, 1, 0)])
		verts.append_array([Vector3(-0.5, 1, -0.5), Vector3(0.5, 1, -0.5), Vector3(-0.5, 1, 0.5), Vector3(0.5, 1, 0.5)])
		for v in 8:
			uvs.append(quad_uv[v % 4])
			c0.append_array([local[b * 2], local[b * 2 + 1], float(b), 0.0 if v < 4 else 1.0])
			c1.append_array([rnd[b * 4], rnd[b * 4 + 1], rnd[b * 4 + 2], rnd[b * 4 + 3]])
		idx.append_array([base, base + 1, base + 2, base + 1, base + 3, base + 2])
		idx.append_array([base + 4, base + 6, base + 5, base + 5, base + 6, base + 7])
	return _mesh(verts, uvs, c0, c1, idx)


func _mesh(verts: PackedVector3Array, uvs: PackedVector2Array, c0: PackedFloat32Array, c1: PackedFloat32Array, idx: PackedInt32Array) -> ArrayMesh:
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	if not uvs.is_empty():
		arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_CUSTOM0] = c0
	arrays[Mesh.ARRAY_CUSTOM1] = c1
	arrays[Mesh.ARRAY_INDEX] = idx
	var fmt := (Mesh.ARRAY_CUSTOM_RGBA_FLOAT << Mesh.ARRAY_FORMAT_CUSTOM0_SHIFT) \
		| (Mesh.ARRAY_CUSTOM_RGBA_FLOAT << Mesh.ARRAY_FORMAT_CUSTOM1_SHIFT)
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays, [], {}, fmt)
	# Blades are placed by the shader; tiles are culled on the CPU.
	mesh.custom_aabb = AABB(Vector3(-1.0e5, -1.0e4, -1.0e5), Vector3(2.0e5, 2.0e4, 2.0e5))
	return mesh


# One plant type: tile ring, atlas slots, bake viewport, near/far instanced draws.
class Ring:
	var cfg: Dictionary
	var world: RefCounted
	var tile: float
	var radius: float
	var cols := 0
	var rows := 0
	var capacity := 0
	var slot_h := 0
	var slots: Array[Dictionary] = []
	var by_key := {}
	var slot_bytes := PackedByteArray()
	var slot_img: Image
	var slot_tex: ImageTexture
	var slot_dirty_tex := false
	var vp: SubViewport
	var bake_mat: ShaderMaterial
	var draw_mat: ShaderMaterial
	var draw_n: SwapMultiMesh
	var draw_f: SwapMultiMesh
	var buf_near := PackedFloat32Array()
	var buf_far := PackedFloat32Array()
	var near_vis := 0
	var far_vis := 0
	var last_tris := 0
	var last_draws := 0
	var total_bakes := 0
	var draw_near := 0
	var draw_far := 0
	var push_us := 0
	var added := 0
	var ring_us := 0
	var enter_us := 0
	var baking_n := 0
	var _has_far := false
	var _near_lod2 := INF
	var _ring_valid := false
	var _ring_cx := 1e9
	var _ring_cz := 1e9
	var _ring_n := 0
	var _r_tx := PackedInt32Array()
	var _r_tz := PackedInt32Array()
	var _r_d2 := PackedFloat32Array()
	var _r_slot: Array = []
	var _m_idx := PackedInt32Array()
	var _m_c2 := PackedFloat32Array()
	var _m_n := 0
	var _has_missing := false
	var _active := {}
	var _gen_seq := 0
	var _buf_near_gen := PackedInt32Array()
	var _buf_far_gen := PackedInt32Array()
	var _pushed_near_n := -1
	var _pushed_far_n := -1

	func _init(owner: Node3D, c: Dictionary, bake_shader: String, draw_shader: String, meshes: Array) -> void:
		cfg = c
		draw_near = cfg.near
		draw_far = cfg.far
		world = owner.world
		tile = cfg.tile
		radius = cfg.radius
		_has_far = float(cfg.near_lod) < 1.0e8
		_near_lod2 = float(cfg.near_lod) * float(cfg.near_lod) if _has_far else INF
		_atlas_grid(1.3)
		var max_ring := (int(ceil(radius * 2.0 / tile)) + 3) * (int(ceil(radius * 2.0 / tile)) + 3)
		_r_tx.resize(max_ring)
		_r_tz.resize(max_ring)
		_r_d2.resize(max_ring)
		_r_slot.resize(max_ring)
		_m_idx.resize(max_ring)
		_m_c2.resize(max_ring)
		_buf_near_gen.resize(capacity)
		_buf_near_gen.fill(-1)
		_buf_far_gen.resize(capacity)
		_buf_far_gen.fill(-1)
		slot_h = int(ceil(float(cfg.near) / cfg.slot_w))
		var sc: Dictionary = VegScatter.generate(cfg.max_count, tile, cfg.seed)
		# Pack scatter and slot tables into RGBA8 bytes rather than RGBAF: WebGL2 without
		# OES_texture_float_linear (iPhone Safari) downgrades RGBAF to RGBAHalf on creation,
		# causing ImageTexture.update(slot_img) to fail with a format mismatch and leaving
		# every grass and flower bake pass discarded.
		var n_near := int(cfg.near)
		var sbytes := PackedByteArray()
		sbytes.resize(n_near * 3 * 4)
		var packed: PackedInt64Array = sc.packed
		for i in n_near:
			for row_i in 3:
				var w: int = packed[i * 4 + row_i]
				var o := (row_i * n_near + i) * 4
				sbytes[o] = w & 255
				sbytes[o + 1] = (w >> 8) & 255
				sbytes[o + 2] = (w >> 16) & 255
				sbytes[o + 3] = (w >> 24) & 255
		var simg := Image.create_from_data(n_near, 3, false, Image.FORMAT_RGBA8, sbytes)
		slot_bytes.resize(capacity * 2 * 4)
		slot_img = Image.create_from_data(capacity, 2, false, Image.FORMAT_RGBA8, slot_bytes)
		slot_tex = ImageTexture.create_from_image(slot_img)
		for s in capacity:
			slots.append({"i": s, "key": null, "sx": (s % cols) * int(cfg.slot_w) * int(cfg.fields), "sy": (s / cols) * slot_h,
				"tx": 0, "tz": 0, "ox": 0.0, "oz": 0.0, "flips": 0, "base": 0.0, "base_q": 0, "box": AABB(), "empty": false,
				"baking": false, "bake_frame": 0, "ready": false, "gen": 0})

		vp = SubViewport.new()
		vp.size = Vector2i(cols * int(cfg.slot_w) * int(cfg.fields), rows * slot_h)
		vp.transparent_bg = true
		vp.disable_3d = true
		vp.render_target_clear_mode = SubViewport.CLEAR_MODE_NEVER
		vp.render_target_update_mode = SubViewport.UPDATE_DISABLED
		var rect := ColorRect.new()
		rect.size = Vector2(vp.size)
		bake_mat = ShaderMaterial.new()
		bake_mat.shader = load(bake_shader)
		for k in ["near", "far", "biome"]:
			bake_mat.set_shader_parameter(k + "_tex", world.texture(k))
		bake_mat.set_shader_parameter("noise_tex", world.noise_tex)
		for k in ["near_size", "near_min", "near_step", "far_size", "far_min", "far_step", "water_level"]:
			bake_mat.set_shader_parameter(k, world.get(k))
		bake_mat.set_shader_parameter("slot_tex", slot_tex)
		bake_mat.set_shader_parameter("scatter_tex", ImageTexture.create_from_image(simg))
		bake_mat.set_shader_parameter("slot_cols", cols)
		bake_mat.set_shader_parameter("slot_w", int(cfg.slot_w))
		bake_mat.set_shader_parameter("slot_h", slot_h)
		bake_mat.set_shader_parameter("fields", int(cfg.fields))
		bake_mat.set_shader_parameter("tile_size", tile)
		rect.material = bake_mat
		vp.add_child(rect)
		owner.add_child(vp)

		draw_mat = ShaderMaterial.new()
		draw_mat.shader = load(draw_shader)
		draw_mat.set_shader_parameter("atlas", vp.get_texture())
		draw_mat.set_shader_parameter("noise_tex", world.noise_tex)
		draw_mat.set_shader_parameter("sky_lut", world.sky_lut_tex)
		draw_mat.set_shader_parameter("water_level", world.water_level)
		draw_mat.set_shader_parameter("tile_size", tile)
		draw_mat.set_shader_parameter("slot_w", int(cfg.slot_w))
		draw_mat.set_shader_parameter("radius", radius)
		buf_near.resize(capacity * 16)
		buf_far.resize(capacity * 16)
		for i in capacity:
			for d in [0, 5, 10]:
				buf_near[i * 16 + d] = 1.0
				buf_far[i * 16 + d] = 1.0
		draw_n = _swap(owner, meshes[0])
		draw_f = _swap(owner, meshes[1])

	func set_meshes(near_mesh: ArrayMesh, far_mesh: ArrayMesh, n_near: int, n_far: int) -> void:
		near_mesh.surface_set_material(0, draw_mat)
		far_mesh.surface_set_material(0, draw_mat)
		draw_n.set_mesh(near_mesh)
		draw_f.set_mesh(far_mesh)
		draw_near = n_near
		draw_far = n_far

	func _swap(owner: Node3D, mesh: ArrayMesh) -> SwapMultiMesh:
		mesh.surface_set_material(0, draw_mat)
		return SwapMultiMesh.new(owner, mesh, capacity, AABB(Vector3(-1.0e5, -1.0e4, -1.0e5), Vector3(2.0e5, 2.0e4, 2.0e5)))

	# grassTiles.js computeAtlasGrid: the ring plus LRU headroom.
	func _atlas_grid(margin: float) -> void:
		var max_span := int(ceil(radius * 2.0 / tile)) + 2
		var approx := int(ceil(PI * pow(radius / tile + 1.1, 2.0)))
		var needed := maxi(9, mini(max_span * max_span, int(ceil(approx * margin))))
		cols = int(ceil(sqrt(float(needed))))
		rows = int(ceil(float(needed) / cols))
		capacity = cols * rows

	func needs_work() -> bool:
		return baking_n > 0 or _has_missing or not _ring_valid

	func update(cam: Vector3, pl: PackedFloat64Array, frame: int, assume_baked: bool) -> void:
		# Slots baked during the previous frame's draw are now readable.
		if baking_n > 0:
			for s in slots:
				if s.baking and frame > s.bake_frame:
					s.baking = false
					s.ready = true
					_gen_seq += 1
					s.gen = _gen_seq
					baking_n -= 1
					_write_slot(s)
		var cx := cam.x
		var cz := cam.z
		var tr := Time.get_ticks_usec()
		var dcx := cx - _ring_cx
		var dcz := cz - _ring_cz
		var rebuild_ring := assume_baked or not _ring_valid or (dcx * dcx + dcz * dcz) >= 0.0625
		if rebuild_ring:
			_rebuild_ring(cx, cz)
		ring_us = Time.get_ticks_usec() - tr

		var bake_any := false
		added = 0
		var te := Time.get_ticks_usec()
		if _has_missing:
			# Build missing list (sorted nearest first) only when tiles need entering.
			_m_n = 0
			for i in _ring_n:
				if _r_slot[i] == null:
					var tx := _r_tx[i]
					var tz := _r_tz[i]
					var ex := tx * tile + tile * 0.5 - cx
					var ez := tz * tile + tile * 0.5 - cz
					var c2 := ex * ex + ez * ez
					# Insertion sort keeps nearest first with zero closure allocation.
					var j := _m_n
					while j > 0 and _m_c2[j - 1] > c2:
						_m_c2[j] = _m_c2[j - 1]
						_m_idx[j] = _m_idx[j - 1]
						j -= 1
					_m_c2[j] = c2
					_m_idx[j] = i
					_m_n += 1
			if _m_n > 0:
				_active.clear()
				for i in _ring_n:
					_active[Vector2i(_r_tx[i], _r_tz[i])] = true
				for mi in _m_n:
					# Tiles enter nearest first and at most NEW_TILES_PER_FRAME a frame, so a walk across a
					# tile row (or a teleport) spreads its ground sampling and bakes over a few frames; the
					# ones left wait at the ring's edge, where blades are thinnest. Headless counts fill at once.
					if not assume_baked and (added >= NEW_TILES_PER_FRAME or (added > 0 and Time.get_ticks_usec() - te > ENTER_BUDGET_US)):
						break
					var ri := _m_idx[mi]
					var tx := _r_tx[ri]
					var tz := _r_tz[ri]
					var key := Vector2i(tx, tz)
					added += 1
					var s := _evict(_active, cx, cz)
					if s.key != null:
						by_key.erase(s.key)
					_assign(s, key, tx, tz)
					by_key[key] = s
					_r_slot[ri] = s
					if not s.empty:
						s.ready = assume_baked
						s.baking = not assume_baked
						s.bake_frame = frame
						if s.baking:
							baking_n += 1
						bake_any = bake_any or s.baking
					_write_slot(s)
				_has_missing = _m_n > added
			else:
				_has_missing = false
		enter_us = Time.get_ticks_usec() - te
		if bake_any:
			vp.render_target_update_mode = SubViewport.UPDATE_ONCE
		var tu := Time.get_ticks_usec()
		if slot_dirty_tex:
			slot_img.set_data(capacity, 2, false, Image.FORMAT_RGBA8, slot_bytes)
			slot_tex.update(slot_img)
			slot_dirty_tex = false
		var slot_us := Time.get_ticks_usec() - tu

		near_vis = 0
		far_vis = 0
		var near_dirty := false
		var far_dirty := false
		var pl_len := pl.size()
		for i in _ring_n:
			var s = _r_slot[i]
			if s == null or s.empty or not s.ready:
				continue
			var b: AABB = s.box
			var vis := true
			var pi := 0
			while pi < pl_len:
				var nx := pl[pi]
				var ny := pl[pi + 1]
				var nz := pl[pi + 2]
				var bx := b.position.x if nx > 0.0 else b.end.x
				var by := b.position.y if ny > 0.0 else b.end.y
				var bz := b.position.z if nz > 0.0 else b.end.z
				if nx * bx + ny * by + nz * bz - pl[pi + 3] > 0.0:
					vis = false
					break
				pi += 4
			if not vis:
				continue
			var gen: int = s.gen
			if not _has_far or _r_d2[i] < _near_lod2:
				if _buf_near_gen[near_vis] != gen:
					_put(true, near_vis, s)
					_buf_near_gen[near_vis] = gen
					near_dirty = true
				near_vis += 1
			else:
				if _buf_far_gen[far_vis] != gen:
					_put(false, far_vis, s)
					_buf_far_gen[far_vis] = gen
					far_dirty = true
				far_vis += 1
		var tp := Time.get_ticks_usec()
		if near_dirty or near_vis != _pushed_near_n:
			draw_n.push(buf_near, near_vis)
			_pushed_near_n = near_vis
		if _has_far and (far_dirty or far_vis != _pushed_far_n):
			draw_f.push(buf_far, far_vis)
			_pushed_far_n = far_vis
		# GPU uploads: the instance buffers and the slot table.
		push_us = Time.get_ticks_usec() - tp + slot_us
		last_tris = near_vis * draw_near * int(cfg.near_tris) + far_vis * draw_far * int(cfg.far_tris)
		last_draws = (1 if near_vis > 0 else 0) + (1 if far_vis > 0 else 0)

	# grassTiles.js selectTileRing: tiles whose box touches the circle, stored in flat arrays.
	func _rebuild_ring(cx: float, cz: float) -> void:
		_ring_valid = true
		_ring_cx = cx
		_ring_cz = cz
		var r2 := radius * radius
		var tz0 := int(floor((cz - radius) / tile))
		var tz1 := int(floor((cz + radius) / tile))
		var tx0 := int(floor((cx - radius) / tile))
		var tx1 := int(floor((cx + radius) / tile))
		var n := 0
		var any_missing := false
		for tz in range(tz0, tz1 + 1):
			var z0 := tz * tile
			var z1 := z0 + tile
			var dz := z0 - cz if cz < z0 else (cz - z1 if cz > z1 else 0.0)
			var dz2 := dz * dz
			if dz2 > r2:
				continue
			for tx in range(tx0, tx1 + 1):
				var x0 := tx * tile
				var x1 := x0 + tile
				var dx := x0 - cx if cx < x0 else (cx - x1 if cx > x1 else 0.0)
				var d2 := dx * dx + dz2
				if d2 > r2:
					continue
				_r_tx[n] = tx
				_r_tz[n] = tz
				_r_d2[n] = d2
				var s = by_key.get(Vector2i(tx, tz))
				_r_slot[n] = s
				if s == null:
					any_missing = true
				n += 1
		_ring_n = n
		_has_missing = any_missing

	# One instance: identity basis moved to (tile origin x, base height, tile origin z); custom =
	# (slot x, y, mirror bits). The base rides in the transform because MultiMesh custom data is
	# stored at half precision in this renderer (0.125 m steps at 140 m), the transform in full.
	# Writes the member arrays by name: a packed array held in a local may be a copy.
	# The basis entries are set once (buffers start as identity rows); only the per-tile values change.
	func _put(near: bool, i: int, s: Dictionary) -> void:
		var k := i * 16
		if near:
			buf_near[k + 3] = s.ox
			buf_near[k + 7] = s.base
			buf_near[k + 11] = s.oz
			buf_near[k + 12] = float(s.sx)
			buf_near[k + 13] = float(s.sy)
			buf_near[k + 14] = float(s.flips)
		else:
			buf_far[k + 3] = s.ox
			buf_far[k + 7] = s.base
			buf_far[k + 11] = s.oz
			buf_far[k + 12] = float(s.sx)
			buf_far[k + 13] = float(s.sy)
			buf_far[k + 14] = float(s.flips)

	# grassTiles.js _pickEvictSlot: a free slot, else the farthest one outside the ring.
	func _evict(active: Dictionary, cx: float, cz: float) -> Dictionary:
		var best: Dictionary = {}
		var best_d := -1.0
		for s in slots:
			if s.key == null:
				return s
			if active.has(s.key):
				continue
			var dx: float = s.ox + tile * 0.5 - cx
			var dz: float = s.oz + tile * 0.5 - cz
			var d := dx * dx + dz * dz
			if d > best_d:
				best_d = d
				best = s
		return best

	func _assign(s: Dictionary, key: Vector2i, tx: int, tz: int) -> void:
		var f := VegScatter.flip_bits(tx, tz)
		s.key = key
		s.tx = tx
		s.tz = tz
		s.ox = tx * tile
		s.oz = tz * tile
		s.flips = f.x | (f.y << 1)
		_gen_seq += 1
		s.gen = _gen_seq
		# grassTiles.js computeTileBounds: 5 x 5 ground samples.
		var lo := INF
		var hi := -INF
		for iz in 5:
			for ix in 5:
				var y: float = world.height(s.ox + ix * tile * 0.25, s.oz + iz * tile * 0.25)
				lo = minf(lo, y)
				hi = maxf(hi, y)
		# Quantise base height to 1/1024 m (~1 mm) so CPU MODEL_MATRIX[3].y and GPU RGBA8 slot_tex match bit-exact.
		var base_q := clampi(roundi((lo - BASE_DROP + 1024.0) * 1024.0), 0, 16777215)
		s.base_q = base_q
		s.base = float(base_q) / 1024.0 - 1024.0
		s.box = AABB(Vector3(s.ox - cfg.pad_xz, lo - cfg.pad_down, s.oz - cfg.pad_xz),
			Vector3(tile + 2.0 * cfg.pad_xz, hi - lo + cfg.pad_down + cfg.pad_up, tile + 2.0 * cfg.pad_xz))
		s.empty = hi < world.water_level + cfg.empty_below
		s.ready = false
		if s.baking:
			baking_n -= 1
		s.baking = false

	func _write_slot(s: Dictionary) -> void:
		var i: int = s.i
		var flags: int = s.flips | (4 if s.baking else 0)
		var txu := clampi(int(s.tx) + 32768, 0, 65535)
		var tzu := clampi(int(s.tz) + 32768, 0, 65535)
		var o0 := i * 4
		slot_bytes[o0] = txu & 255
		slot_bytes[o0 + 1] = (txu >> 8) & 255
		slot_bytes[o0 + 2] = tzu & 255
		slot_bytes[o0 + 3] = (tzu >> 8) & 255
		var bq: int = s.base_q
		var o1 := (capacity + i) * 4
		slot_bytes[o1] = flags & 255
		slot_bytes[o1 + 1] = bq & 255
		slot_bytes[o1 + 2] = (bq >> 8) & 255
		slot_bytes[o1 + 3] = (bq >> 16) & 255
		slot_dirty_tex = true
