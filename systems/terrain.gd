extends Node3D

# Stillwater's quadtree terrain with baked painted ground colour.
#
# The CPU walks an iterative quadtree over the 32 km far map (skipped when the camera is still or
# within the padded live-walk thresholds), keeps the nodes in the camera frustum, and splits a node
# while the camera is closer than LOD_K * size (2 m vertex spacing near the camera).
#
# In painterly mode (default), smooth macro ground colour and a forest-floor mask are baked once
# into RGBA8:
#   - Near ring: 12 m tiles baked into a 1536 x 1536 SubViewport atlas (12 x 12 = 144 slots of
#     128 x 128 px; 125 usable intervals + 1 px gutter on every side = 9.6 cm/texel), covering
#     a 64 m radius (10 m prefetch beyond the 40-54 m fade) with a 4-tile/frame bake budget.
#     Once all tiles around the camera are baked, bake scheduling sleeps with zero per-frame work
#     until the camera moves.
#   - Valley macro: a one-time 1024 x 1024 RGBA8 SubViewport bake over the 4096 m near map
#     (4 m/texel), used seamlessly beyond the near ring and as an instant fallback until a near
#     tile finishes baking.
#   - Far terrain: nodes beyond FAR_SPLIT_DIST or outside the 4 km valley draw with valley + live
#     trail inside the valley, 2-fetch painted mountains beyond, and per-pixel atmosphere.
#
# ?ground=live or ?style=classic switches back to the original single-draw per-pixel shader
# (shaders/terrain.gdshader) for A/B testing and classic parity.

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

const GROUND_TILE := 12.0
const GROUND_SLOT_PX := 128
const GROUND_SLOT_USE := 125.0
const GROUND_COLS := 12
const GROUND_ROWS := 12
const GROUND_CAPACITY := GROUND_COLS * GROUND_ROWS
const GROUND_RADIUS := 64.0
const GROUND_FADE_START := 40.0
const GROUND_FADE_END := 54.0
const GROUND_GRID_W := 16
const GROUND_BAKE_BUDGET := 4
const VALLEY_RES := 1024
const FAR_SPLIT_DIST := 700.0
const BAKE_WAKE_SQ := 1.0

const SwapMultiMesh := preload("res://systems/swap_multimesh.gd")
const Flags := preload("res://systems/flags.gd")

var world: RefCounted
var mat: ShaderMaterial
var baked_mat: ShaderMaterial
var far_mat: ShaderMaterial
var flat_mat: ShaderMaterial
var flat_on := false
var live_override := false
var painterly := true
var on := true
var frozen := false

var _patch_live: ArrayMesh
var _patch_near: ArrayMesh
var _patch_far: ArrayMesh
var _bounds: AABB
var draw: SwapMultiMesh
var draw_near: SwapMultiMesh
var draw_far: SwapMultiMesh
var _cap := INIT_NODES
var buf := PackedFloat32Array()
var buf_near := PackedFloat32Array()
var buf_far := PackedFloat32Array()

var tris_per_node := 0
var last_nodes := 0
var last_near_nodes := 0
var last_far_nodes := 0
var last_tris := 0
var last_draws := 0
# Script time of this frame's _process and sub-parts, for the bench and perf panel.
var prof_us := 0
var select_us := 0
var push_us := 0
var uniform_us := 0

# Near-tile and valley macro bake state.
var valley_vp: SubViewport
var valley_mat: ShaderMaterial
var valley_ready := false
var _valley_bake_frame := -1
var ground_vp: SubViewport
var _bake_rects: Array[ColorRect] = []
var _bake_mats: Array[ShaderMaterial] = []
var ground_slots: Array[Dictionary] = []
var ground_by_key := {}
var ground_grid_bytes := PackedByteArray()
var ground_grid_img: Image
var ground_grid_tex: ImageTexture
var _grid_ox := 999999
var _grid_oz := 999999
var _grid_dirty := true
var _baking_n := 0
var _frame := 0
var total_bakes := 0
var ready_slots := 0
var _bake_settled := false
var _bake_pos := Vector3(1e9, 0.0, 1e9)

# Per frustum plane: nx, nz, ny * (the box y deepest along the normal) - d, so a node's test reads
# no Plane objects.
var _pl := PackedFloat64Array()
# Iterative traversal stack (max depth for 32768 -> 64 is 9, max stack height 28).
var _st_x := PackedFloat32Array()
var _st_z := PackedFloat32Array()
var _st_s := PackedFloat32Array()
var _cam_pos := Vector3.ZERO
var _cam_fwd := Vector2(0.0, -1.0)
var _dy := 0.0
var _last_live_dy := -1.0
var _last_baked_dy := -1.0
var _last_flat_dy := -1.0
var _count := 0
var _near_count := 0
var _far_count := 0
var _pushed_count := -1
var _pushed_near := -1
var _pushed_far := -1
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
	live_override = Flags.value("ground", "baked").to_lower() == "live"
	painterly = Flags.style() != "classic"

	mat = _make_world_mat("res://shaders/terrain.gdshader")
	# ?dbg_terrain=<bits>: the ?probe=terrain switches in the real game, to confirm a probe finding.
	mat.set_shader_parameter("dbg_terrain", int(Flags.value("dbg_terrain", "0")))

	_setup_bakers()

	baked_mat = _make_world_mat("res://shaders/terrain_baked.gdshader")
	baked_mat.set_shader_parameter("ground_atlas", ground_vp.get_texture())
	baked_mat.set_shader_parameter("ground_grid_tex", ground_grid_tex)
	baked_mat.set_shader_parameter("valley_tex", valley_vp.get_texture())
	baked_mat.set_shader_parameter("ground_grid_w", float(GROUND_GRID_W))
	baked_mat.set_shader_parameter("ground_tile_size", GROUND_TILE)
	baked_mat.set_shader_parameter("ground_slot_px", float(GROUND_SLOT_PX))
	baked_mat.set_shader_parameter("ground_slot_use", GROUND_SLOT_USE)
	baked_mat.set_shader_parameter("ground_atlas_size", Vector2(GROUND_COLS * GROUND_SLOT_PX, GROUND_ROWS * GROUND_SLOT_PX))
	baked_mat.set_shader_parameter("ground_fade_start", GROUND_FADE_START)
	baked_mat.set_shader_parameter("ground_fade_end", GROUND_FADE_END)
	baked_mat.set_shader_parameter("valley_ready", 0.0)
	baked_mat.set_shader_parameter("dbg_terrain", int(Flags.value("dbg_terrain", "0")))

	far_mat = _make_world_mat("res://shaders/terrain_far.gdshader")
	far_mat.set_shader_parameter("valley_tex", valley_vp.get_texture())
	far_mat.set_shader_parameter("valley_ready", 0.0)
	far_mat.set_shader_parameter("dbg_terrain", int(Flags.value("dbg_terrain", "0")))

	_patch_live = _patch_mesh(N)
	_patch_live.surface_set_material(0, mat)
	_patch_near = _patch_mesh(N)
	_patch_near.surface_set_material(0, baked_mat)
	_patch_far = _patch_mesh(N)
	_patch_far.surface_set_material(0, far_mat)
	_st_x.resize(64)
	_st_z.resize(64)
	_st_s.resize(64)
	# Nodes are culled here on the CPU; Godot must never cull the whole terrain.
	_bounds = AABB(Vector3(-ROOT * 0.5, BOX_MIN_Y, -ROOT * 0.5), Vector3(ROOT, BOX_MAX_Y - BOX_MIN_Y, ROOT))
	_init_draws(INIT_NODES)

	var info := atlas_info()
	print("TERRAIN ground=%s tile=%.0fm texel=%.1fcm atlas=%dx%d (%d slots, %.1fMB) valley=%dx%d (%.1fMB) budget=%d/f" % [
		ground_mode(), info.tile_m, info.texel_cm, info.atlas_px.x, info.atlas_px.y, info.slots, info.atlas_mb,
		info.valley_px, info.valley_px, info.valley_mb, info.bake_budget])


func _init_draws(cap: int) -> void:
	_cap = cap
	var old_n := buf.size() / 16
	buf.resize(_cap * 16)
	buf_near.resize(_cap * 16)
	buf_far.resize(_cap * 16)
	for i in range(old_n, _cap):
		# Identity transform; the shader reads the node from custom data.
		buf[i * 16] = 1.0
		buf[i * 16 + 5] = 1.0
		buf[i * 16 + 10] = 1.0
		buf_near[i * 16] = 1.0
		buf_near[i * 16 + 5] = 1.0
		buf_near[i * 16 + 10] = 1.0
		buf_far[i * 16] = 1.0
		buf_far[i * 16 + 5] = 1.0
		buf_far[i * 16 + 10] = 1.0
	for old_draw in [draw, draw_near, draw_far]:
		if old_draw != null:
			for mmi in old_draw.mmis:
				remove_child(mmi)
				mmi.queue_free()
	draw = SwapMultiMesh.new(self, _patch_live, _cap, _bounds)
	draw_near = SwapMultiMesh.new(self, _patch_near, _cap, _bounds)
	draw_far = SwapMultiMesh.new(self, _patch_far, _cap, _bounds)
	if flat_on and flat_mat != null:
		for mmi in draw.mmis:
			mmi.material_override = flat_mat
	_pushed_count = -1
	_pushed_near = -1
	_pushed_far = -1
	_force_push = true
	_sync_draw_vis()


func _make_world_mat(shader_path: String) -> ShaderMaterial:
	var m := ShaderMaterial.new()
	m.shader = load(shader_path)
	m.set_shader_parameter("near_tex", world.texture("near"))
	m.set_shader_parameter("far_tex", world.texture("far"))
	m.set_shader_parameter("biome_tex", world.texture("biome"))
	m.set_shader_parameter("noise_tex", world.noise_tex)
	m.set_shader_parameter("sky_lut", world.sky_lut_tex)
	m.set_shader_parameter("near_size", world.near_size)
	m.set_shader_parameter("near_min", world.near_min)
	m.set_shader_parameter("near_step", world.near_step)
	m.set_shader_parameter("far_size", world.far_size)
	m.set_shader_parameter("far_min", world.far_min)
	m.set_shader_parameter("far_step", world.far_step)
	m.set_shader_parameter("water_level", world.water_level)
	m.set_shader_parameter("grid_n", float(N))
	m.set_shader_parameter("lod_k", LOD_K)
	m.set_shader_parameter("skirt_on", 1.0 if SKIRT else 0.0)
	return m


func _bind_bake_world(m: ShaderMaterial) -> void:
	m.set_shader_parameter("near_tex", world.texture("near"))
	m.set_shader_parameter("far_tex", world.texture("far"))
	m.set_shader_parameter("biome_tex", world.texture("biome"))
	m.set_shader_parameter("noise_tex", world.noise_tex)
	m.set_shader_parameter("near_size", world.near_size)
	m.set_shader_parameter("near_min", world.near_min)
	m.set_shader_parameter("near_step", world.near_step)
	m.set_shader_parameter("far_size", world.far_size)
	m.set_shader_parameter("far_min", world.far_min)
	m.set_shader_parameter("far_step", world.far_step)
	m.set_shader_parameter("water_level", world.water_level)


func _setup_bakers() -> void:
	# One-time valley macro bake (1024 x 1024 RGBA8 over [-2048, +2048]^2).
	valley_vp = SubViewport.new()
	valley_vp.name = "valley_bake_vp"
	valley_vp.size = Vector2i(VALLEY_RES, VALLEY_RES)
	valley_vp.transparent_bg = true
	valley_vp.disable_3d = true
	valley_vp.render_target_clear_mode = SubViewport.CLEAR_MODE_NEVER
	valley_vp.render_target_update_mode = SubViewport.UPDATE_DISABLED
	var vrect := ColorRect.new()
	vrect.size = Vector2(VALLEY_RES, VALLEY_RES)
	valley_mat = ShaderMaterial.new()
	valley_mat.shader = load("res://shaders/valley_bake.gdshader")
	_bind_bake_world(valley_mat)
	valley_mat.set_shader_parameter("valley_res", float(VALLEY_RES))
	vrect.material = valley_mat
	valley_vp.add_child(vrect)
	add_child(valley_vp)

	# Near-ring tile atlas (1536 x 1536 RGBA8 = 12 x 12 slots of 128 x 128 px).
	# Uses GROUND_BAKE_BUDGET positioned 128 x 128 ColorRects so only newly dirtied slots rasterize.
	ground_vp = SubViewport.new()
	ground_vp.name = "ground_bake_vp"
	ground_vp.size = Vector2i(GROUND_COLS * GROUND_SLOT_PX, GROUND_ROWS * GROUND_SLOT_PX)
	ground_vp.transparent_bg = true
	ground_vp.disable_3d = true
	ground_vp.render_target_clear_mode = SubViewport.CLEAR_MODE_NEVER
	ground_vp.render_target_update_mode = SubViewport.UPDATE_DISABLED
	var bake_shader: Shader = load("res://shaders/ground_bake.gdshader")
	for b in GROUND_BAKE_BUDGET:
		var r := ColorRect.new()
		r.size = Vector2(GROUND_SLOT_PX, GROUND_SLOT_PX)
		r.visible = false
		var bm := ShaderMaterial.new()
		bm.shader = bake_shader
		_bind_bake_world(bm)
		bm.set_shader_parameter("tile_size", GROUND_TILE)
		bm.set_shader_parameter("slot_use", GROUND_SLOT_USE)
		r.material = bm
		ground_vp.add_child(r)
		_bake_rects.append(r)
		_bake_mats.append(bm)
	add_child(ground_vp)

	# RGBA8 lookup table (16 x 16 = 1 KB): maps tile offset from grid_origin to (col, row, ready).
	ground_grid_bytes.resize(GROUND_GRID_W * GROUND_GRID_W * 4)
	ground_grid_img = Image.create_from_data(GROUND_GRID_W, GROUND_GRID_W, false, Image.FORMAT_RGBA8, ground_grid_bytes)
	ground_grid_tex = ImageTexture.create_from_image(ground_grid_img)

	for s in GROUND_CAPACITY:
		ground_slots.append({
			"i": s, "col": s % GROUND_COLS, "row": s / GROUND_COLS,
			"key": null, "tx": 0, "tz": 0,
			"baking": false, "bake_frame": 0, "ready": false,
		})


func materials() -> Array[ShaderMaterial]:
	return [mat, baked_mat, far_mat]


func atlas_info() -> Dictionary:
	var aw := GROUND_COLS * GROUND_SLOT_PX
	var ah := GROUND_ROWS * GROUND_SLOT_PX
	var atlas_mb := float(aw * ah * 4) / (1024.0 * 1024.0)
	var valley_mb := float(VALLEY_RES * VALLEY_RES * 4) / (1024.0 * 1024.0)
	return {
		"tile_m": GROUND_TILE,
		"texel_cm": GROUND_TILE / GROUND_SLOT_USE * 100.0,
		"atlas_px": Vector2i(aw, ah),
		"valley_px": VALLEY_RES,
		"slots": GROUND_CAPACITY,
		"ready_slots": ready_slots,
		"total_bakes": total_bakes,
		"atlas_mb": atlas_mb,
		"valley_mb": valley_mb,
		"vram_mb": atlas_mb + valley_mb,
		"bake_budget": GROUND_BAKE_BUDGET,
	}


func use_baked() -> bool:
	return not flat_on and not live_override and painterly


func ground_mode() -> String:
	return "baked" if (not live_override and painterly) else "live"


func is_live() -> bool:
	return live_override or not painterly


func set_live(v: bool) -> void:
	if v == live_override:
		return
	live_override = v
	_cam_valid = false
	_force_push = true
	if use_baked():
		_bake_settled = false
	_sync_draw_vis()


func set_painterly(v: bool) -> void:
	if v == painterly:
		return
	painterly = v
	_cam_valid = false
	_force_push = true
	if use_baked():
		_bake_settled = false
	_sync_draw_vis()


func set_skirt(v: bool) -> void:
	var f := 1.0 if v else 0.0
	mat.set_shader_parameter("skirt_on", f)
	baked_mat.set_shader_parameter("skirt_on", f)
	far_mat.set_shader_parameter("skirt_on", f)
	if flat_mat != null:
		flat_mat.set_shader_parameter("skirt_on", f)


# Sweep helper: swap terrain fragments to a flat colour while keeping identical CDLOD vertices and depth.
func set_flat(v: bool) -> void:
	if v == flat_on:
		return
	flat_on = v
	if v and flat_mat == null:
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
	elif v and flat_mat != null and absf(_dy - _last_flat_dy) > 0.005:
		flat_mat.set_shader_parameter("cam_dy", _dy)
		_last_flat_dy = _dy
	for mmi in draw.mmis:
		mmi.material_override = flat_mat if v else null
	_cam_valid = false
	_force_push = true
	if use_baked():
		_bake_settled = false
	_sync_draw_vis()


func set_on(v: bool) -> void:
	on = v
	_sync_draw_vis()
	if not v:
		last_nodes = 0
		last_near_nodes = 0
		last_far_nodes = 0
		last_tris = 0
		last_draws = 0
	else:
		_cam_valid = false
		_force_push = true


func is_on() -> bool:
	return on


func set_frozen(v: bool) -> void:
	frozen = v


func _sync_draw_vis() -> void:
	if draw == null:
		return
	var baked := use_baked()
	draw.set_visible(on and not baked and _count > 0)
	draw_near.set_visible(on and baked and _near_count > 0)
	draw_far.set_visible(on and baked and _far_count > 0)


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
	var baked := use_baked()

	# Keep baking while tiles are in flight or the camera moved into new tiles, but do zero work
	# once all active tiles around the camera are ready and the camera is still.
	var grid_push_us := 0
	if baked:
		var need_bake := not _bake_settled or not valley_ready or _baking_n > 0 or _grid_dirty or pos.distance_squared_to(_bake_pos) >= BAKE_WAKE_SQ
		if need_bake:
			_frame += 1
			_cam_pos = pos
			var f2 := Vector2(fwd.x, fwd.z)
			_cam_fwd = f2.normalized() if f2.length_squared() > 1e-6 else Vector2(0.0, -1.0)
			grid_push_us = _update_ground_bake()

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
				push_us = grid_push_us
				select_us = Time.get_ticks_usec() - ts - grid_push_us
				return last_nodes
		elif xform == _last_xform:
			push_us = grid_push_us
			select_us = Time.get_ticks_usec() - ts - grid_push_us
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
	var half_near: float = world.near_size * 0.5
	var far_split2 := FAR_SPLIT_DIST * FAR_SPLIT_DIST

	_count = 0
	_near_count = 0
	_far_count = 0
	var changed_live := false
	var changed_near := false
	var changed_far := false
	_st_x[0] = -ROOT * 0.5
	_st_z[0] = -ROOT * 0.5
	_st_s[0] = ROOT
	var sp := 1
	while sp > 0:
		sp -= 1
		var x0 := _st_x[sp]
		var z0 := _st_z[sp]
		var size := _st_s[sp]
		if (not baked and _count >= MAX_NODES) or (baked and (_near_count + _far_count) >= MAX_NODES):
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
		var d_xz2 := ddx * ddx + ddz * ddz
		var lim := LOD_K * size
		if size > MIN_SIZE and d_xz2 + dy2 < lim * lim:
			var h := size * 0.5
			_st_x[sp] = x0 + h; _st_z[sp] = z0 + h; _st_s[sp] = h; sp += 1
			_st_x[sp] = x0;     _st_z[sp] = z0 + h; _st_s[sp] = h; sp += 1
			_st_x[sp] = x0 + h; _st_z[sp] = z0;     _st_s[sp] = h; sp += 1
			_st_x[sp] = x0;     _st_z[sp] = z0;     _st_s[sp] = h; sp += 1
		else:
			if baked:
				var in_valley := x0 >= -half_near and x1 <= half_near and z0 >= -half_near and z1 <= half_near
				if in_valley and size <= 256.0 and d_xz2 < far_split2:
					if _near_count >= _cap:
						_init_draws(mini(MAX_NODES, _cap * 2))
						changed_near = true
						changed_far = true
					var kn := _near_count * 16 + 12
					if buf_near[kn] != x0 or buf_near[kn + 1] != z0 or buf_near[kn + 2] != size:
						buf_near[kn] = x0
						buf_near[kn + 1] = z0
						buf_near[kn + 2] = size
						buf_near[kn + 3] = 0.0
						changed_near = true
					_near_count += 1
				else:
					if _far_count >= _cap:
						_init_draws(mini(MAX_NODES, _cap * 2))
						changed_near = true
						changed_far = true
					var kf := _far_count * 16 + 12
					if buf_far[kf] != x0 or buf_far[kf + 1] != z0 or buf_far[kf + 2] != size:
						buf_far[kf] = x0
						buf_far[kf + 1] = z0
						buf_far[kf + 2] = size
						buf_far[kf + 3] = 0.0
						changed_far = true
					_far_count += 1
			else:
				if _count >= _cap:
					_init_draws(mini(MAX_NODES, _cap * 2))
					changed_live = true
				var k := _count * 16 + 12
				if buf[k] != x0 or buf[k + 1] != z0 or buf[k + 2] != size:
					buf[k] = x0
					buf[k + 1] = z0
					buf[k + 2] = size
					buf[k + 3] = 0.0
					changed_live = true
				_count += 1

	var tp := Time.get_ticks_usec()
	select_us = tp - ts - grid_push_us
	if baked:
		draw.set_visible(false)
		if _near_count > 0:
			draw_near.set_visible(on)
			if changed_near or _near_count != _pushed_near or _force_push:
				draw_near.push(buf_near, _near_count)
				_pushed_near = _near_count
		else:
			draw_near.set_visible(false)
		if _far_count > 0:
			draw_far.set_visible(on)
			if changed_far or _far_count != _pushed_far or _force_push:
				draw_far.push(buf_far, _far_count)
				_pushed_far = _far_count
		else:
			draw_far.set_visible(false)
		_force_push = false
		last_draws = (1 if _near_count > 0 else 0) + (1 if _far_count > 0 else 0)
	else:
		draw_near.set_visible(false)
		draw_far.set_visible(false)
		if _count > 0:
			draw.set_visible(on)
			if changed_live or _count != _pushed_count or _force_push:
				draw.push(buf, _count)
				_pushed_count = _count
		else:
			draw.set_visible(false)
		_force_push = false
		last_draws = 1 if _count > 0 else 0

	var tu := Time.get_ticks_usec()
	push_us = tu - tp + grid_push_us
	if baked:
		if absf(_dy - _last_baked_dy) > 0.005:
			baked_mat.set_shader_parameter("cam_dy", _dy)
			far_mat.set_shader_parameter("cam_dy", _dy)
			_last_baked_dy = _dy
	else:
		if absf(_dy - _last_live_dy) > 0.005:
			mat.set_shader_parameter("cam_dy", _dy)
			_last_live_dy = _dy
		if flat_on and flat_mat != null and absf(_dy - _last_flat_dy) > 0.005:
			flat_mat.set_shader_parameter("cam_dy", _dy)
			_last_flat_dy = _dy
	uniform_us = Time.get_ticks_usec() - tu
	last_near_nodes = _near_count
	last_far_nodes = _far_count
	last_nodes = (_near_count + _far_count) if baked else _count
	last_tris = last_nodes * tris_per_node
	return last_nodes


func _update_ground_bake() -> int:
	# Schedule the one-time valley macro bake on the first baked frame, mark ready on the next.
	if not valley_ready:
		if _valley_bake_frame < 0:
			valley_vp.render_target_update_mode = SubViewport.UPDATE_ONCE
			_valley_bake_frame = _frame
		elif _frame > _valley_bake_frame:
			valley_ready = true
			baked_mat.set_shader_parameter("valley_ready", 1.0)
			far_mat.set_shader_parameter("valley_ready", 1.0)

	# Slots baked on an earlier frame are now readable in ground_atlas.
	if _baking_n > 0:
		for s in ground_slots:
			if s.baking and _frame > s.bake_frame:
				s.baking = false
				s.ready = true
				_baking_n -= 1
				ready_slots += 1
				_grid_dirty = true

	var cx := _cam_pos.x
	var cz := _cam_pos.z
	var half_g := GROUND_GRID_W >> 1
	var ox := floori(cx / GROUND_TILE) - half_g
	var oz := floori(cz / GROUND_TILE) - half_g
	if ox != _grid_ox or oz != _grid_oz:
		_grid_ox = ox
		_grid_oz = oz
		_grid_dirty = true

	# Collect active tiles touching GROUND_RADIUS around the camera.
	var r2 := GROUND_RADIUS * GROUND_RADIUS
	var tx0 := floori((cx - GROUND_RADIUS) / GROUND_TILE)
	var tx1 := floori((cx + GROUND_RADIUS) / GROUND_TILE)
	var tz0 := floori((cz - GROUND_RADIUS) / GROUND_TILE)
	var tz1 := floori((cz + GROUND_RADIUS) / GROUND_TILE)
	var active := {}
	var missing: Array[Dictionary] = []
	for tz in range(tz0, tz1 + 1):
		var z0 := tz * GROUND_TILE
		var dz := maxf(maxf(z0 - cz, 0.0), cz - (z0 + GROUND_TILE))
		var dz2 := dz * dz
		if dz2 > r2:
			continue
		for tx in range(tx0, tx1 + 1):
			var x0 := tx * GROUND_TILE
			var dx := maxf(maxf(x0 - cx, 0.0), cx - (x0 + GROUND_TILE))
			var d2 := dx * dx + dz2
			if d2 > r2:
				continue
			var key := Vector2i(tx, tz)
			active[key] = true
			if not ground_by_key.has(key):
				# Prioritise tiles closest to the camera and ahead of the view direction so the
				# visible path bakes first on teleport or walking.
				var ex := x0 + GROUND_TILE * 0.5 - cx
				var ez := z0 + GROUND_TILE * 0.5 - cz
				var c2 := ex * ex + ez * ez
				var fwd_dot := ex * _cam_fwd.x + ez * _cam_fwd.y
				var bias := 0.45 if fwd_dot >= -GROUND_TILE * 0.5 else 1.4
				missing.append({"key": key, "tx": tx, "tz": tz, "score": c2 * bias})

	var baked_now := 0
	if not missing.is_empty():
		missing.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return a.score < b.score)
		for m in missing:
			if baked_now >= GROUND_BAKE_BUDGET:
				break
			var s := _pick_ground_slot(active, cx, cz)
			if s.is_empty():
				break
			if s.key != null:
				ground_by_key.erase(s.key)
				if s.ready:
					ready_slots -= 1
				if s.baking:
					_baking_n -= 1
			s.key = m.key
			s.tx = m.tx
			s.tz = m.tz
			s.ready = false
			s.baking = true
			s.bake_frame = _frame
			_baking_n += 1
			total_bakes += 1
			ground_by_key[m.key] = s

			var rect := _bake_rects[baked_now]
			var bm := _bake_mats[baked_now]
			var sx := float(s.col * GROUND_SLOT_PX)
			var sy := float(s.row * GROUND_SLOT_PX)
			rect.position = Vector2(sx, sy)
			rect.visible = true
			bm.set_shader_parameter("tile_origin", Vector2(float(s.tx) * GROUND_TILE, float(s.tz) * GROUND_TILE))
			bm.set_shader_parameter("slot_origin", Vector2(sx, sy))
			baked_now += 1
			_grid_dirty = true

	for b in range(baked_now, GROUND_BAKE_BUDGET):
		_bake_rects[b].visible = false
	if baked_now > 0:
		ground_vp.render_target_update_mode = SubViewport.UPDATE_ONCE

	var upload_us := 0
	if _grid_dirty:
		var tu := Time.get_ticks_usec()
		for gz in GROUND_GRID_W:
			var tz := _grid_oz + gz
			for gx in GROUND_GRID_W:
				var tx := _grid_ox + gx
				var o := (gz * GROUND_GRID_W + gx) * 4
				var key := Vector2i(tx, tz)
				if ground_by_key.has(key):
					var s: Dictionary = ground_by_key[key]
					if s.ready:
						ground_grid_bytes[o] = s.col
						ground_grid_bytes[o + 1] = s.row
						ground_grid_bytes[o + 2] = 255
						ground_grid_bytes[o + 3] = 255
						continue
				ground_grid_bytes[o] = 0
				ground_grid_bytes[o + 1] = 0
				ground_grid_bytes[o + 2] = 0
				ground_grid_bytes[o + 3] = 0
		ground_grid_img.set_data(GROUND_GRID_W, GROUND_GRID_W, false, Image.FORMAT_RGBA8, ground_grid_bytes)
		ground_grid_tex.update(ground_grid_img)
		baked_mat.set_shader_parameter("ground_grid_origin", Vector2(float(_grid_ox), float(_grid_oz)))
		_grid_dirty = false
		upload_us = Time.get_ticks_usec() - tu

	if valley_ready and _baking_n == 0 and missing.is_empty() and not _grid_dirty:
		_bake_settled = true
		_bake_pos = _cam_pos
	else:
		_bake_settled = false
	return upload_us


func _pick_ground_slot(active: Dictionary, cx: float, cz: float) -> Dictionary:
	var best: Dictionary = {}
	var best_d := -1.0
	for s in ground_slots:
		if s.key == null:
			return s
		if active.has(s.key) or s.baking:
			continue
		var ex := float(s.tx) * GROUND_TILE + GROUND_TILE * 0.5 - cx
		var ez := float(s.tz) * GROUND_TILE + GROUND_TILE * 0.5 - cz
		var d := ex * ex + ez * ez
		if d > best_d:
			best_d = d
			best = s
	return best
