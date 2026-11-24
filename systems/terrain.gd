extends Node3D

# Stillwater's quadtree terrain with baked painted ground colour.
#
# Every frame the CPU walks a quadtree over the 32 km far map, keeps the nodes in the camera
# frustum, and splits a node while the camera is closer than LOD_K * size (2 m vertex spacing near
# the camera). In painterly mode (default), position-only ground colour is baked once into RGBA8:
#   - Near ring: 12 m tiles baked into a 1536 x 1536 SubViewport atlas (12 x 12 = 144 slots of
#     128 x 128 px; 125 usable intervals + 1 px gutter on every side = 9.6 cm/texel), covering
#     a 64 m radius (10 m prefetch beyond the 40-54 m fade) with a 4-tile/frame bake budget.
#   - Valley macro: a one-time 1024 x 1024 RGBA8 SubViewport bake over the 4096 m near map
#     (4 m/texel), used seamlessly beyond the near ring and as an instant fallback until a near
#     tile finishes baking.
#   - Far terrain: nodes beyond FAR_SPLIT_DIST or outside the 4 km valley draw with a cheap
#     2-fetch painted mountain shader + per-pixel atmosphere; near/mid nodes shade lighting,
#     cloud shadow, forest glades and atmosphere in the vertex shader.
#
# ?ground=live or ?style=classic switches back to the original single-draw per-pixel shader
# (shaders/terrain.gdshader) for A/B testing and classic parity.

const ROOT := 32768.0
const MIN_SIZE := 64.0
const N := 32
const LOD_K := 3.0
const MAX_NODES := 1024
const BOX_MIN_Y := -200.0
const BOX_MAX_Y := 4400.0
const SKIRT := true

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

var draw: SwapMultiMesh
var draw_near: SwapMultiMesh
var draw_far: SwapMultiMesh
var buf := PackedFloat32Array()
var buf_near := PackedFloat32Array()
var buf_far := PackedFloat32Array()

var tris_per_node := 0
var last_nodes := 0
var last_near_nodes := 0
var last_far_nodes := 0
var last_tris := 0
var last_draws := 0
var prof_us := 0
var push_us := 0

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

var _pl := PackedFloat64Array()
var _cam_pos := Vector3.ZERO
var _cam_fwd := Vector2(0.0, -1.0)
var _dy := 0.0
var _count := 0
var _near_count := 0
var _far_count := 0


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

	var patch_live := _patch_mesh(N)
	patch_live.surface_set_material(0, mat)
	var patch_near := _patch_mesh(N)
	patch_near.surface_set_material(0, baked_mat)
	var patch_far := _patch_mesh(N)
	patch_far.surface_set_material(0, far_mat)

	buf.resize(MAX_NODES * 16)
	buf_near.resize(MAX_NODES * 16)
	buf_far.resize(MAX_NODES * 16)
	for i in MAX_NODES:
		# Identity transform; the shader reads the node from custom data.
		for d in [0, 5, 10]:
			buf[i * 16 + d] = 1.0
			buf_near[i * 16 + d] = 1.0
			buf_far[i * 16 + d] = 1.0

	var box := AABB(Vector3(-ROOT * 0.5, BOX_MIN_Y, -ROOT * 0.5), Vector3(ROOT, BOX_MAX_Y - BOX_MIN_Y, ROOT))
	draw = SwapMultiMesh.new(self, patch_live, MAX_NODES, box)
	draw_near = SwapMultiMesh.new(self, patch_near, MAX_NODES, box)
	draw_far = SwapMultiMesh.new(self, patch_far, MAX_NODES, box)
	_sync_draw_vis()

	var info := atlas_info()
	print("TERRAIN ground=%s tile=%.0fm texel=%.1fcm atlas=%dx%d (%d slots, %.1fMB) valley=%dx%d (%.1fMB) budget=%d/f" % [
		ground_mode(), info.tile_m, info.texel_cm, info.atlas_px.x, info.atlas_px.y, info.slots, info.atlas_mb,
		info.valley_px, info.valley_px, info.valley_mb, info.bake_budget])


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
	_sync_draw_vis()


func set_painterly(v: bool) -> void:
	if v == painterly:
		return
	painterly = v
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
		flat_mat.set_shader_parameter("cam_xz", Vector2(_cam_pos.x, _cam_pos.z))
		flat_mat.set_shader_parameter("cam_dy", _dy)
	for mmi in draw.mmis:
		mmi.material_override = flat_mat if v else null
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
	var cam := get_viewport().get_camera_3d()
	if on and not frozen and cam != null:
		select(cam)
	prof_us = Time.get_ticks_usec() - t0


func select(cam: Camera3D) -> int:
	_frame += 1
	_cam_pos = cam.global_position
	var fwd3 := -cam.global_transform.basis.z
	var f2 := Vector2(fwd3.x, fwd3.z)
	_cam_fwd = f2.normalized() if f2.length_squared() > 1e-6 else Vector2(0.0, -1.0)
	var planes := cam.get_frustum()
	_pl.resize(planes.size() * 3)
	for i in planes.size():
		var n := planes[i].normal
		_pl[i * 3] = n.x
		_pl[i * 3 + 1] = n.z
		_pl[i * 3 + 2] = n.y * (BOX_MIN_Y if n.y > 0.0 else BOX_MAX_Y) - planes[i].d
	_dy = maxf(0.0, _cam_pos.y - world.height(_cam_pos.x, _cam_pos.z))

	var baked := use_baked()
	var grid_push_us := 0
	if baked:
		grid_push_us = _update_ground_bake()

	_count = 0
	_near_count = 0
	_far_count = 0
	_visit(-ROOT * 0.5, -ROOT * 0.5, ROOT, baked)

	var tp := Time.get_ticks_usec()
	var cam_xz := Vector2(_cam_pos.x, _cam_pos.z)
	if baked:
		draw.set_visible(false)
		if _near_count > 0:
			draw_near.set_visible(on)
			draw_near.push(buf_near, _near_count)
		else:
			draw_near.set_visible(false)
		if _far_count > 0:
			draw_far.set_visible(on)
			draw_far.push(buf_far, _far_count)
		else:
			draw_far.set_visible(false)
		baked_mat.set_shader_parameter("cam_xz", cam_xz)
		baked_mat.set_shader_parameter("cam_dy", _dy)
		far_mat.set_shader_parameter("cam_xz", cam_xz)
		far_mat.set_shader_parameter("cam_dy", _dy)
		last_draws = (1 if _near_count > 0 else 0) + (1 if _far_count > 0 else 0)
	else:
		draw_near.set_visible(false)
		draw_far.set_visible(false)
		if _count > 0:
			draw.set_visible(on)
			draw.push(buf, _count)
		else:
			draw.set_visible(false)
		mat.set_shader_parameter("cam_xz", cam_xz)
		mat.set_shader_parameter("cam_dy", _dy)
		if flat_on and flat_mat != null:
			flat_mat.set_shader_parameter("cam_xz", cam_xz)
			flat_mat.set_shader_parameter("cam_dy", _dy)
		last_draws = 1 if _count > 0 else 0
	push_us = Time.get_ticks_usec() - tp + grid_push_us
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


func _visit(x0: float, z0: float, size: float, baked: bool) -> void:
	if (not baked and _count >= MAX_NODES) or (baked and (_near_count + _far_count) >= MAX_NODES) or not _box_visible(x0, z0, size):
		return
	var ddx := maxf(maxf(x0 - _cam_pos.x, 0.0), _cam_pos.x - (x0 + size))
	var ddz := maxf(maxf(z0 - _cam_pos.z, 0.0), _cam_pos.z - (z0 + size))
	var d_xz2 := ddx * ddx + ddz * ddz
	var d := sqrt(d_xz2 + _dy * _dy)
	if size > MIN_SIZE and d < LOD_K * size:
		var h := size * 0.5
		_visit(x0, z0, h, baked)
		_visit(x0 + h, z0, h, baked)
		_visit(x0, z0 + h, h, baked)
		_visit(x0 + h, z0 + h, h, baked)
	else:
		if baked:
			var half_near: float = world.near_size * 0.5
			var in_valley := x0 >= -half_near and (x0 + size) <= half_near and z0 >= -half_near and (z0 + size) <= half_near
			if in_valley and size <= 256.0 and d_xz2 < FAR_SPLIT_DIST * FAR_SPLIT_DIST:
				var kn := _near_count * 16 + 12
				buf_near[kn] = x0
				buf_near[kn + 1] = z0
				buf_near[kn + 2] = size
				buf_near[kn + 3] = 0.0
				_near_count += 1
			else:
				var kf := _far_count * 16 + 12
				buf_far[kf] = x0
				buf_far[kf + 1] = z0
				buf_far[kf + 2] = size
				buf_far[kf + 3] = 0.0
				_far_count += 1
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
	var i := 0
	while i < _pl.size():
		var nx := _pl[i]
		var nz := _pl[i + 1]
		var cx := x0 if nx > 0.0 else x0 + size
		var cz := z0 if nz > 0.0 else z0 + size
		if nx * cx + nz * cz + _pl[i + 2] > 0.0:
			return false
		i += 3
	return true
