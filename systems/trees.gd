extends Node3D

# Stillwater's trees at the low tier (src/world/trees.js, treeChunks.js, treeImpostor.js):
#   hero      32 m cells whose nearest point is within treeHeroR of the camera, hero meshes
#   mid       64 m cells within treeMidR: near cells (< treeMidFineR) draw mid1 (hero-lod1 trunk,
#             20-face indexed inner core + fringe leaf cards), far mid cells draw mid0 (20-face
#             opaque puffs, no leaf cards); trees in an active hero cell are hidden in the mid shader
#   impostor  everything else (not bushes): one quad per tree, one batch per 1024 m cell; trees in
#             an active mid cell are hidden in the impostor shader
# Opaque geometry (trunks, inner cores, mid0 puffs) lives on surface 0 with render_priority = -1
# and no discard, so hardware early-Z rejects rear leaf-card fragments on surface 1 (priority 0).
# Each level enters at its radius and leaves at lodExitRadius (hysteresis), re-picked after the
# camera moved 4 m. Hero and mid batches are one MultiMesh per kind and cell, built on first use
# and kept; Godot frustum-culls every batch by its box. Bushes draw only inside treeBushR.
# The four hand-placed hero oaks by the cottage (buildWorld.js) always draw with the hero material.
#
# Data: data/valley/web/trees.bin (the low tier's rank subset, see meta.json trees), meshes and
# atlases in data/trees/ (tools/build_tree_meshes.gd, tools/bake_impostors.mjs).

const SwapMultiMesh := preload("res://systems/swap_multimesh.gd")

const HERO_CELL := 32.0
const NEAR_CELL := 64.0
const FAR_CELL := 1024.0
const SWAY_PAD := 2.0
const LOD_STEP := 4.0
const HERO_CAP := 128
const KINDS: Array[String] = ["oak", "round", "pine", "bush", "poplar", "larch"]
const IMP_INDEX: Array[int] = [0, 1, 2, -1, 3, 4]
const BUSH := 3
const MESH_DIR := "res://data/trees"
# Walking streams mid cells in: batches this far beyond mid_r are built ahead, nearest first,
# at most BUILD_BUDGET_US of script per frame, so a cell is ready before it is needed. Hero trees
# (~12-30 total) merge by species into per-species SwapMultiMeshes when active hero cells change.
const PREFETCH_MID := 48.0
const BUILD_BUDGET_US := 2000

var world: RefCounted
var hero_r := 12.0
var mid_r := 100.0
var mid_fine_r := 40.0
var bush_r := 120.0

var count := 0
var px := PackedFloat32Array()
var py := PackedFloat32Array()
var pz := PackedFloat32Array()
var ps := PackedFloat32Array()
var prot := PackedFloat32Array()
var psx := PackedFloat32Array()
var ptint := PackedByteArray()
var prank := PackedInt32Array()
# Density lever: draw trees with rank < density * the tier's fraction, as Stillwater's tiers select.
var density := 1.0
var rank_limit := 1 << 20
var tier_trees := 0.55
var base_hero_r := 12.0
var base_mid_r := 100.0
var base_mid_fine_r := 40.0
var base_bush_r := 120.0
var pkind := PackedByteArray()
var tint_max := 2.0

var hero_mesh: Array[Mesh] = []
var mid_coarse_mesh: Array[Mesh] = []
var mid_fine_mesh: Array[Mesh] = []
var mesh_tris: Dictionary = {}
var mesh_draws: Dictionary = {}
var hero_opaque_mat: ShaderMaterial
var hero_card_mat: ShaderMaterial
var mid_opaque_mat: ShaderMaterial
var mid_card_mat: ShaderMaterial
var imp_mat: ShaderMaterial
var cells_img: Image
var cells_tex: ImageTexture
var cells_bytes := PackedByteArray()

# Cell grids over the tree bounds; `_grid` returns {ix0, iz0, w, h, start, order} where the trees
# of cell c are order[start[c] .. start[c + 1]).
var hero_grid: Dictionary
var near_grid: Dictionary
var flag_x0 := 0
var flag_z0 := 0
var flag_w := 0
var flag_h := 0

var hero_swaps: Array = []
var hero_counts: PackedInt32Array = PackedInt32Array()
var hero_aabbs: Array[AABB] = []
var hero_bufs: Array[PackedFloat32Array] = []
var _hero_dirty := true
var mid_batches: Dictionary = {}
var hero_active: Dictionary = {}
var mid_active: Dictionary = {}
var far_nodes: Array[MultiMeshInstance3D] = []
var far_total := 0
var hero_oaks: MultiMeshInstance3D
var lod_center := Vector3(1e9, 0.0, 1e9)
# Cells to build ahead: [distance, hero, key], nearest first.
var _prefetch: Array = []
# Slowest single cell build so far (walk checks).
var build_max_us := 0
# Per drawn MultiMeshInstance3D: [cull box, triangles per draw, surfaces per draw], filled on first use.
var _draw_info := {}

var on := true
var impostors_on := true
var frozen := false
var stats := {"hero": 0, "mid": 0, "impostor": 0, "near_cells": 0, "far_cells": 0}
var last_tris := 0
var last_draws := 0
var load_ms := 0
# Script time of this frame's _process and sub-parts, for the bench and perf panel.
var prof_us := 0
var hero_us := 0
var mid_us := 0
var flags_us := 0
var prefetch_us := 0
var count_us := 0
var _lod_gen := 0
var _count_gen := -1
var _count_xform := Transform3D.IDENTITY
var _count_fov := -1.0
var _count_far := -1.0
var _count_vp := Vector2.ZERO
var _count_pl := PackedFloat64Array()
var _hero_changed := false
var _mid_changed := false


func setup(w: RefCounted) -> void:
	world = w


func _ready() -> void:
	# After the camera has moved this frame.
	process_priority = 100
	var t0 := Time.get_ticks_msec()
	var tm: Dictionary = world.meta.trees
	var tier: Dictionary = tm.tierValues
	hero_r = float(tier.treeHeroR)
	mid_r = float(tier.treeMidR)
	mid_fine_r = float(tier.get("treeMidFineR", 40.0))
	bush_r = float(tier.get("treeBushR", mid_r))
	base_hero_r = hero_r
	base_mid_r = mid_r
	base_mid_fine_r = mid_fine_r
	base_bush_r = bush_r
	tier_trees = float(tier.trees)
	_decode(tm)
	_load_assets()
	hero_grid = _grid(HERO_CELL, false)
	near_grid = _grid(NEAR_CELL, false)
	_build_cell_flags()
	_build_hero_swaps()
	_build_far()
	_build_hero_oaks(tm.heroOaks)
	load_ms = Time.get_ticks_msec() - t0
	print("TREES %d placed (%s tier), %d impostors in %d far cells, built in %d ms" % [count, tm.tier, far_total, far_nodes.size(), load_ms])


func _decode(_tm: Dictionary) -> void:
	var t: Dictionary = world.load_trees()
	if t.is_empty():
		count = 0
		return
	count = t.count
	px = t.x
	py = t.y
	pz = t.z
	ps = t.s
	prot = t.rot
	psx = t.sx
	ptint = t.tint
	pkind = t.kind
	tint_max = t.tint_max
	prank = t.rank


func _load_assets() -> void:
	var leaf := _png("leaf_atlas.pngdata")
	leaf.generate_mipmaps()
	var leaf_tex := ImageTexture.create_from_image(leaf)
	var info: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(MESH_DIR.path_join("impostors.json")))
	var alb := _png("impostor_albedo.pngdata")
	var nrm := _png("impostor_normal.pngdata")
	alb.generate_mipmaps()
	nrm.generate_mipmaps()

	var opaque_shader: Shader = load("res://shaders/tree_opaque.gdshader")
	var card_shader: Shader = load("res://shaders/tree.gdshader")
	# Opaque materials draw at priority -1 and discard materials at +1 so Apple TBDR HSR never
	# interleaves opaque geometry with alpha-tested leaf cards or impostors.
	hero_opaque_mat = ShaderMaterial.new()
	hero_opaque_mat.shader = opaque_shader
	hero_opaque_mat.render_priority = -1
	hero_card_mat = ShaderMaterial.new()
	hero_card_mat.shader = card_shader
	hero_card_mat.render_priority = 1
	mid_opaque_mat = ShaderMaterial.new()
	mid_opaque_mat.shader = opaque_shader
	mid_opaque_mat.render_priority = -1
	mid_card_mat = ShaderMaterial.new()
	mid_card_mat.shader = card_shader
	mid_card_mat.render_priority = 1

	for mat in [hero_opaque_mat, mid_opaque_mat]:
		mat.set_shader_parameter("biome_tex", world.texture("biome"))
		mat.set_shader_parameter("near_size", world.near_size)
		mat.set_shader_parameter("blend_start", world.blend_start)
		mat.set_shader_parameter("blend_end", world.blend_end)
	for mat in [hero_card_mat, mid_card_mat]:
		mat.set_shader_parameter("leaf_atlas", leaf_tex)
	mid_opaque_mat.set_shader_parameter("hide_in_hero", 1.0)
	mid_card_mat.set_shader_parameter("hide_in_hero", 1.0)

	imp_mat = ShaderMaterial.new()
	imp_mat.shader = load("res://shaders/tree_impostor.gdshader")
	imp_mat.render_priority = 1
	imp_mat.set_shader_parameter("imp_albedo", ImageTexture.create_from_image(alb))
	imp_mat.set_shader_parameter("imp_normal", ImageTexture.create_from_image(nrm))
	var frames := PackedVector4Array()
	for f in info.frames:
		frames.append(Vector4(f[0], f[1], f[2], f[3]))
	imp_mat.set_shader_parameter("imp_frames", frames)
	var g: Array = info.grid
	imp_mat.set_shader_parameter("imp_grid", Vector4(g[0], g[1], g[2], g[3]))
	imp_mat.set_shader_parameter("imp_atlas_px", float(info.size))
	for mat in [hero_opaque_mat, hero_card_mat, mid_opaque_mat, mid_card_mat, imp_mat]:
		mat.set_shader_parameter("noise_tex", world.noise_tex)
		mat.set_shader_parameter("sky_lut", world.sky_lut_tex)
		mat.set_shader_parameter("water_level", world.water_level)

	for k in KINDS:
		var h: Mesh = load(MESH_DIR.path_join(k + "_hero.res"))
		var m0: Mesh = load(MESH_DIR.path_join(k + "_mid0.res"))
		var m1: Mesh = load(MESH_DIR.path_join(k + "_mid1.res"))
		_bind_mesh_mats(h, hero_opaque_mat, hero_card_mat)
		_bind_mesh_mats(m0, mid_opaque_mat, mid_card_mat)
		_bind_mesh_mats(m1, mid_opaque_mat, mid_card_mat)
		hero_mesh.append(h)
		mid_coarse_mesh.append(m0)
		mid_fine_mesh.append(m1)
		for m in [h, m0, m1]:
			mesh_tris[m] = _tris(m)
			mesh_draws[m] = m.get_surface_count()


static func _bind_mesh_mats(m: Mesh, op_mat: ShaderMaterial, card_mat: ShaderMaterial) -> void:
	if m.get_surface_count() >= 1:
		m.surface_set_material(0, op_mat)
	if m.get_surface_count() >= 2:
		m.surface_set_material(1, card_mat)


# Materials whose look values the environment sets (sun, light colour, exposure).
func materials() -> Array[ShaderMaterial]:
	return [hero_opaque_mat, hero_card_mat, mid_opaque_mat, mid_card_mat, imp_mat]


func _png(file: String) -> Image:
	var img := Image.new()
	if img.load_png_from_buffer(FileAccess.get_file_as_bytes(MESH_DIR.path_join(file))) != OK:
		push_error("trees: cannot decode %s" % file)
	return img


static func _tris(m: Mesh) -> int:
	var total := 0
	for s in m.get_surface_count():
		var arr := m.surface_get_arrays(s)
		total += (arr[Mesh.ARRAY_INDEX] as PackedInt32Array).size() / 3
	return total


# Counting sort of tree indices by cell, over a grid padded by two cells (treeChunks.js
# groupIntoCells, in canonical order inside a cell).
func _grid(size: float, skip_bush: bool) -> Dictionary:
	var ix0 := 1 << 30
	var iz0 := 1 << 30
	var ix1 := -(1 << 30)
	var iz1 := -(1 << 30)
	var cell := PackedInt32Array()
	cell.resize(count)
	for i in count:
		var ix := int(floorf(px[i] / size))
		var iz := int(floorf(pz[i] / size))
		ix0 = mini(ix0, ix)
		iz0 = mini(iz0, iz)
		ix1 = maxi(ix1, ix)
		iz1 = maxi(iz1, iz)
	ix0 -= 2
	iz0 -= 2
	var w := ix1 + 3 - ix0
	var h := iz1 + 3 - iz0
	var start := PackedInt32Array()
	start.resize(w * h + 1)
	for i in count:
		if skip_bush and pkind[i] == BUSH:
			cell[i] = -1
			continue
		var c := (int(floorf(pz[i] / size)) - iz0) * w + int(floorf(px[i] / size)) - ix0
		cell[i] = c
		start[c + 1] += 1
	for c in w * h:
		start[c + 1] += start[c]
	var fill := start.slice(0, w * h)
	var order := PackedInt32Array()
	order.resize(start[w * h])
	for i in count:
		var c := cell[i]
		if c < 0:
			continue
		order[fill[c]] = i
		fill[c] += 1
	return {"size": size, "ix0": ix0, "iz0": iz0, "w": w, "h": h, "start": start, "order": order}


func _build_cell_flags() -> void:
	# One texel per 32 m cell: red = hero cell active, green = the 64 m mid cell around it active.
	flag_x0 = hero_grid.ix0
	flag_z0 = hero_grid.iz0
	flag_w = hero_grid.w
	flag_h = hero_grid.h
	cells_bytes.resize(flag_w * flag_h * 2)
	cells_img = Image.create_from_data(flag_w, flag_h, false, Image.FORMAT_RG8, cells_bytes)
	cells_tex = ImageTexture.create_from_image(cells_img)
	for mat in [mid_opaque_mat, mid_card_mat, imp_mat]:
		mat.set_shader_parameter("tree_cells", cells_tex)
		mat.set_shader_parameter("tree_cell_origin", Vector2(flag_x0, flag_z0))


func _write_cell_flags() -> void:
	cells_bytes.fill(0)
	for key in hero_active:
		var c: Vector2i = key
		var x := c.x - flag_x0
		var z := c.y - flag_z0
		if x >= 0 and z >= 0 and x < flag_w and z < flag_h:
			cells_bytes[(z * flag_w + x) * 2] = 255
	var k := int(NEAR_CELL / HERO_CELL)
	for key in mid_active:
		var c: Vector2i = key
		for a in k:
			for b in k:
				var x := c.x * k + b - flag_x0
				var z := c.y * k + a - flag_z0
				if x >= 0 and z >= 0 and x < flag_w and z < flag_h:
					cells_bytes[(z * flag_w + x) * 2 + 1] = 255
	cells_img.set_data(flag_w, flag_h, false, Image.FORMAT_RG8, cells_bytes)
	cells_tex.update(cells_img)


# MultiMesh rows: 3 x 4 transform (rotate rot about +Y, scale (s * sx, s, s * sx)), then custom
# (tint rgb, extra).
func _write_instance(buf: PackedFloat32Array, o: int, i: int, extra: float) -> void:
	var s := ps[i]
	var w := s * psx[i]
	var c := cos(prot[i])
	var sn := sin(prot[i])
	buf[o] = c * w
	buf[o + 1] = 0.0
	buf[o + 2] = sn * w
	buf[o + 3] = px[i]
	buf[o + 4] = 0.0
	buf[o + 5] = s
	buf[o + 6] = 0.0
	buf[o + 7] = py[i]
	buf[o + 8] = -sn * w
	buf[o + 9] = 0.0
	buf[o + 10] = c * w
	buf[o + 11] = pz[i]
	var tk := tint_max / 255.0
	buf[o + 12] = ptint[i * 3] * tk
	buf[o + 13] = ptint[i * 3 + 1] * tk
	buf[o + 14] = ptint[i * 3 + 2] * tk
	buf[o + 15] = extra


func _kept(idx: PackedInt32Array) -> PackedInt32Array:
	if density >= 1.0 or prank.is_empty():
		return idx
	var out := PackedInt32Array()
	for i in idx:
		if prank[i] < rank_limit:
			out.append(i)
	return out


func _multimesh(mesh: Mesh, idx: PackedInt32Array, extra_of_kind: bool) -> MultiMesh:
	idx = _kept(idx)
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_custom_data = true
	mm.mesh = mesh
	mm.instance_count = idx.size()
	var buf := PackedFloat32Array()
	buf.resize(idx.size() * 16)
	for j in idx.size():
		var i := idx[j]
		_write_instance(buf, j * 16, i, float(IMP_INDEX[pkind[i]]) if extra_of_kind else 0.0)
	mm.buffer = buf
	return mm


# Box around a cell's trees: the cell square plus crown overhang, ground spread plus the tallest
# crown, plus wind sway (treeChunks.js cellBoundingSphere, as a box).
func _cell_aabb(idx: PackedInt32Array, cx: float, cz: float, size: float) -> AABB:
	var y0 := INF
	var y1 := -INF
	var smax := 0.0
	for i in idx:
		y0 = minf(y0, py[i])
		y1 = maxf(y1, py[i])
		smax = maxf(smax, ps[i])
	var hx := size * 0.5 + smax * 0.6 + SWAY_PAD
	return AABB(Vector3(cx - hx, y0 - SWAY_PAD, cz - hx), Vector3(hx * 2.0, y1 - y0 + smax * 1.15 + SWAY_PAD * 2.0, hx * 2.0))


func _build_far() -> void:
	var quad := ArrayMesh.new()
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = PackedVector3Array([Vector3(-0.5, -0.5, 0), Vector3(0.5, -0.5, 0), Vector3(-0.5, 0.5, 0), Vector3(0.5, 0.5, 0)])
	arrays[Mesh.ARRAY_INDEX] = PackedInt32Array([0, 1, 2, 1, 3, 2])
	quad.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	mesh_tris[quad] = 2
	mesh_draws[quad] = 1
	var g := _grid(FAR_CELL, true)
	var start: PackedInt32Array = g.start
	var order: PackedInt32Array = g.order
	for c in int(g.w) * int(g.h):
		if start[c + 1] == start[c]:
			continue
		var idx := order.slice(start[c], start[c + 1])
		# Species order inside a batch, as the game builds them.
		var by_kind: Array[PackedInt32Array] = []
		for v in KINDS.size():
			by_kind.append(PackedInt32Array())
		for i in idx:
			by_kind[pkind[i]].append(i)
		idx = PackedInt32Array()
		for v in KINDS.size():
			idx.append_array(by_kind[v])
		var ix := c % int(g.w) + int(g.ix0)
		var iz := c / int(g.w) + int(g.iz0)
		idx = _kept(idx)
		if idx.is_empty():
			continue
		var mmi := MultiMeshInstance3D.new()
		mmi.multimesh = _multimesh(quad, idx, true)
		mmi.multimesh.custom_aabb = _cell_aabb(idx, (ix + 0.5) * FAR_CELL, (iz + 0.5) * FAR_CELL, FAR_CELL)
		mmi.material_override = imp_mat
		mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		mmi.visible = impostors_on
		add_child(mmi)
		far_nodes.append(mmi)
		far_total += idx.size()
	stats.far_cells = far_nodes.size()


func _build_hero_oaks(spots: Array) -> void:
	if spots.is_empty():
		return
	var mesh: Mesh = load(MESH_DIR.path_join("hero_oak.res"))
	_bind_mesh_mats(mesh, hero_opaque_mat, hero_card_mat)
	mesh_tris[mesh] = _tris(mesh)
	mesh_draws[mesh] = mesh.get_surface_count()
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_custom_data = true
	mm.mesh = mesh
	mm.instance_count = spots.size()
	for j in spots.size():
		var t: Dictionary = spots[j]
		var s := float(t.s)
		var basis := Basis(Vector3.UP, float(t.rot)).scaled(Vector3(s * 0.94, s, s * 0.94))
		mm.set_instance_transform(j, Transform3D(basis, Vector3(t.x, t.y, t.z)))
		mm.set_instance_custom_data(j, Color(t.tint[0], t.tint[1], t.tint[2], 0.0))
	# An explicit box, so the drawn-count test works without a GPU (headless budget test).
	var box := AABB()
	for j in spots.size():
		var t: Dictionary = spots[j]
		var s := float(t.s)
		var b := AABB(Vector3(t.x - s * 0.6 - SWAY_PAD, t.y - SWAY_PAD, t.z - s * 0.6 - SWAY_PAD), Vector3(s * 1.2 + SWAY_PAD * 2.0, s * 1.15 + SWAY_PAD * 2.0, s * 1.2 + SWAY_PAD * 2.0))
		box = b if j == 0 else box.merge(b)
	mm.custom_aabb = box
	hero_oaks = MultiMeshInstance3D.new()
	hero_oaks.multimesh = mm
	hero_oaks.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(hero_oaks)


func _make_batch(g: Dictionary, key: Vector2i, hero: bool) -> Dictionary:
	var t0 := Time.get_ticks_usec()
	var b := _build_batch(g, key, hero)
	build_max_us = maxi(build_max_us, Time.get_ticks_usec() - t0)
	return b


func _build_batch(g: Dictionary, key: Vector2i, hero: bool) -> Dictionary:
	var size: float = g.size
	var c := (key.y - int(g.iz0)) * int(g.w) + key.x - int(g.ix0)
	var start: PackedInt32Array = g.start
	var idx: PackedInt32Array = _kept((g.order as PackedInt32Array).slice(start[c], start[c + 1]))
	var cx := (key.x + 0.5) * size
	var cz := (key.y + 0.5) * size
	var batch := {"nodes": [], "cx": cx, "cz": cz, "size": size, "count": idx.size(), "bushes": 0, "on": false, "bush_on": true, "fine": false}
	if idx.is_empty():
		return batch
	var aabb := _cell_aabb(idx, cx, cz, size)
	for v in KINDS.size():
		var sub := PackedInt32Array()
		for i in idx:
			if pkind[i] == v:
				sub.append(i)
		if sub.is_empty():
			continue
		var mmi := MultiMeshInstance3D.new()
		mmi.multimesh = _multimesh(hero_mesh[v] if hero else mid_coarse_mesh[v], sub, false)
		mmi.multimesh.custom_aabb = aabb
		mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		mmi.visible = false
		mmi.set_meta("bush", v == BUSH)
		mmi.set_meta("kind", v)
		add_child(mmi)
		batch.nodes.append(mmi)
		if v == BUSH:
			batch.bushes = sub.size()
	return batch


func _set_fine(batch: Dictionary, fine: bool) -> void:
	if batch.fine == fine:
		return
	batch.fine = fine
	for mmi: MultiMeshInstance3D in batch.nodes:
		var v: int = mmi.get_meta("kind")
		mmi.multimesh.mesh = mid_fine_mesh[v] if fine else mid_coarse_mesh[v]
		_draw_info.erase(mmi)


func _show(batch: Dictionary, show: bool, bush_on: bool) -> void:
	if batch.on == show and batch.bush_on == bush_on:
		return
	batch.on = show
	batch.bush_on = bush_on
	for mmi: MultiMeshInstance3D in batch.nodes:
		mmi.visible = show and (bush_on or not mmi.get_meta("bush"))


static func _cell_distance(cx: float, cz: float, size: float, x: float, z: float) -> float:
	var h := size * 0.5
	return Vector2(maxf(absf(x - cx) - h, 0.0), maxf(absf(z - cz) - h, 0.0)).length()


static func _exit_radius(r: float) -> float:
	return r + maxf(r * 0.08, 4.0)


# treeChunks.js cellsInRadius: cells whose nearest point is inside enter_r, plus cells already
# active that are still inside exit_r.
func _cells_in_radius(g: Dictionary, x: float, z: float, enter_r: float, prev: Dictionary) -> Dictionary:
	var size: float = g.size
	var exit_r := _exit_radius(enter_r)
	var out := {}
	var r := int(ceilf(exit_r / size)) + 1
	var cx0 := int(floorf(x / size))
	var cz0 := int(floorf(z / size))
	var start: PackedInt32Array = g.start
	for iz in range(cz0 - r, cz0 + r + 1):
		for ix in range(cx0 - r, cx0 + r + 1):
			var gx := ix - int(g.ix0)
			var gz := iz - int(g.iz0)
			if gx < 0 or gz < 0 or gx >= int(g.w) or gz >= int(g.h):
				continue
			var c := gz * int(g.w) + gx
			if start[c + 1] == start[c]:
				continue
			var key := Vector2i(ix, iz)
			var d := _cell_distance((ix + 0.5) * size, (iz + 0.5) * size, size, x, z)
			if d < enter_r or (prev.has(key) and d < exit_r):
				out[key] = true
	return out


func _sync(g: Dictionary, batches: Dictionary, active: Dictionary, want: Dictionary, hero: bool, x: float, z: float) -> Vector2i:
	var set_changed := want.size() != active.size()
	for key in active:
		if not want.has(key):
			_show(batches[key], false, true)
			set_changed = true
	if not set_changed:
		for key in want:
			if not active.has(key):
				set_changed = true
				break
	if set_changed:
		active.clear()
	var n := 0
	var imp := 0
	for key in want:
		if not batches.has(key):
			batches[key] = _make_batch(g, key, hero)
		var b: Dictionary = batches[key]
		var d := _cell_distance(b.cx, b.cz, b.size, x, z)
		var bush_on := d < bush_r
		if not hero:
			var fine: bool = d < mid_fine_r or (bool(b.fine) and d < _exit_radius(mid_fine_r))
			_set_fine(b, fine)
		_show(b, true, bush_on)
		if set_changed:
			active[key] = true
		n += b.count if bush_on else b.count - b.bushes
		imp += b.count - b.bushes
	_mid_changed = set_changed
	return Vector2i(n, imp)


func _build_hero_swaps() -> void:
	hero_swaps.clear()
	hero_counts.resize(KINDS.size())
	hero_counts.fill(0)
	hero_aabbs.clear()
	hero_bufs.clear()
	for v in KINDS.size():
		var sw := SwapMultiMesh.new(self, hero_mesh[v], HERO_CAP, AABB())
		sw.set_visible(false)
		hero_swaps.append(sw)
		hero_aabbs.append(AABB())
		var buf := PackedFloat32Array()
		buf.resize(HERO_CAP * 16)
		hero_bufs.append(buf)
	_hero_dirty = true


func _sync_hero(want: Dictionary) -> int:
	var same := not _hero_dirty and want.size() == hero_active.size()
	if same:
		for key in want:
			if not hero_active.has(key):
				same = false
				break
	if same:
		_hero_changed = false
		var total_same := 0
		for v in KINDS.size():
			total_same += hero_counts[v]
		return total_same
	_hero_changed = true
	_hero_dirty = false
	hero_active = want.duplicate()
	var by_kind: Array[PackedInt32Array] = []
	for v in KINDS.size():
		by_kind.append(PackedInt32Array())
	var start: PackedInt32Array = hero_grid.start
	var order: PackedInt32Array = hero_grid.order
	var gw := int(hero_grid.w)
	var ix0 := int(hero_grid.ix0)
	var iz0 := int(hero_grid.iz0)
	for key in want:
		var k: Vector2i = key
		var c := (k.y - iz0) * gw + k.x - ix0
		for i in _kept(order.slice(start[c], start[c + 1])):
			by_kind[pkind[i]].append(i)
	var total := 0
	for v in KINDS.size():
		var sub := by_kind[v]
		var n := sub.size()
		hero_counts[v] = n
		total += n
		var sw: SwapMultiMesh = hero_swaps[v]
		if n == 0:
			sw.set_visible(false)
			hero_aabbs[v] = AABB()
			continue
		var cap: int = sw.mms[0].instance_count
		if n > cap:
			for mmi in sw.mmis:
				remove_child(mmi)
				mmi.queue_free()
			cap = maxi(cap * 2, n)
			sw = SwapMultiMesh.new(self, hero_mesh[v], cap, AABB())
			hero_swaps[v] = sw
			var nb := PackedFloat32Array()
			nb.resize(cap * 16)
			hero_bufs[v] = nb
		var buf: PackedFloat32Array = hero_bufs[v]
		var x0 := INF; var x1 := -INF; var y0 := INF; var y1 := -INF; var z0 := INF; var z1 := -INF; var smax := 0.0
		for j in n:
			var i := sub[j]
			_write_instance(buf, j * 16, i, 0.0)
			x0 = minf(x0, px[i]); x1 = maxf(x1, px[i])
			y0 = minf(y0, py[i]); y1 = maxf(y1, py[i])
			z0 = minf(z0, pz[i]); z1 = maxf(z1, pz[i])
			smax = maxf(smax, ps[i])
		var pad := smax * 0.6 + SWAY_PAD
		var aabb := AABB(Vector3(x0 - pad, y0 - SWAY_PAD, z0 - pad), Vector3(x1 - x0 + pad * 2.0, y1 - y0 + smax * 1.15 + SWAY_PAD * 2.0, z1 - z0 + pad * 2.0))
		hero_aabbs[v] = aabb
		sw.set_visible(true)
		sw.push(buf, n)
		sw.mmis[sw._cur].custom_aabb = aabb
	return total


func _plan_prefetch(cam_pos: Vector3) -> void:
	_prefetch.clear()
	for key in _cells_in_radius(near_grid, cam_pos.x, cam_pos.z, mid_r + PREFETCH_MID, {}):
		if not mid_batches.has(key):
			var size: float = near_grid.size
			_prefetch.append([_cell_distance((key.x + 0.5) * size, (key.y + 0.5) * size, size, cam_pos.x, cam_pos.z), key])
	_prefetch.sort_custom(func(a: Array, b: Array) -> bool: return a[0] < b[0])
	_prefetch.reverse()


func _drain_prefetch(t0: int) -> void:
	while not _prefetch.is_empty() and Time.get_ticks_usec() - t0 < BUILD_BUDGET_US:
		var job: Array = _prefetch.pop_back()
		if not mid_batches.has(job[1]):
			mid_batches[job[1]] = _make_batch(near_grid, job[1], false)


func update_lod(cam_pos: Vector3, force: bool = false) -> void:
	var dx := cam_pos.x - lod_center.x
	var dz := cam_pos.z - lod_center.z
	if not force and dx * dx + dz * dz < LOD_STEP * LOD_STEP:
		return
	lod_center = cam_pos
	var hero_want := _cells_in_radius(hero_grid, cam_pos.x, cam_pos.z, hero_r, hero_active)
	var mid_want := _cells_in_radius(near_grid, cam_pos.x, cam_pos.z, mid_r, mid_active)
	var th := Time.get_ticks_usec()
	var h_cnt := _sync_hero(hero_want)
	var tm := Time.get_ticks_usec()
	hero_us = tm - th
	var m := _sync(near_grid, mid_batches, mid_active, mid_want, false, cam_pos.x, cam_pos.z)
	var tf := Time.get_ticks_usec()
	mid_us = tf - tm
	if _hero_changed or _mid_changed or force:
		_write_cell_flags()
	var tp := Time.get_ticks_usec()
	flags_us = tp - tf
	_plan_prefetch(cam_pos)
	prefetch_us += Time.get_ticks_usec() - tp
	_lod_gen += 1
	stats.hero = h_cnt
	stats.mid = m.x - h_cnt
	stats.near_cells = mid_want.size()
	stats.impostor = far_total - m.y


# Density (fraction of this tier's trees) and draw distance (scale of the hero / mid / bush radii):
# both rebuild the batches, which takes a moment, as a tier switch does in Stillwater.
func set_levers(dens: float, dist: float) -> void:
	if is_equal_approx(dens, density) and is_equal_approx(base_hero_r * dist, hero_r):
		return
	density = dens
	rank_limit = int(floor(tier_trees * dens * 65536.0)) if dens < 1.0 else 1 << 20
	hero_r = base_hero_r * dist
	mid_r = base_mid_r * dist
	mid_fine_r = base_mid_fine_r * dist
	bush_r = base_bush_r * dist
	for child in get_children():
		if child != hero_oaks:
			child.queue_free()
			remove_child(child)
	mid_batches.clear()
	_prefetch.clear()
	_draw_info.clear()
	hero_active.clear()
	mid_active.clear()
	far_nodes.clear()
	far_total = 0
	_build_hero_swaps()
	_build_far()
	lod_center = Vector3(1e9, 0.0, 1e9)


func set_on(v: bool) -> void:
	on = v
	visible = v
	_lod_gen += 1
	if not v:
		last_tris = 0
		last_draws = 0


func set_impostors_on(v: bool) -> void:
	impostors_on = v
	_lod_gen += 1
	for mmi in far_nodes:
		mmi.visible = v


func is_on() -> bool:
	return on


func set_frozen(v: bool) -> void:
	frozen = v


func _process(_delta: float) -> void:
	var t0 := Time.get_ticks_usec()
	hero_us = 0
	mid_us = 0
	flags_us = 0
	prefetch_us = 0
	count_us = 0
	if not frozen:
		var cam := get_viewport().get_camera_3d()
		if cam != null and count > 0:
			update_lod(cam.global_position)
			if on and not _prefetch.is_empty():
				var tp := Time.get_ticks_usec()
				_drain_prefetch(t0)
				prefetch_us += Time.get_ticks_usec() - tp
	prof_us = Time.get_ticks_usec() - t0


# On-demand drawn-count stats for the perf readout and bench (not run in normal play frames).
func ensure_counts(cam: Camera3D) -> void:
	if cam == null:
		return
	var xform := cam.global_transform
	var vp_sz := cam.get_viewport().get_visible_rect().size
	if _count_gen == _lod_gen and xform == _count_xform and cam.fov == _count_fov and cam.far == _count_far and vp_sz == _count_vp:
		return
	var tc := Time.get_ticks_usec()
	count_drawn(cam)
	count_us += Time.get_ticks_usec() - tc
	_count_gen = _lod_gen
	_count_xform = xform
	_count_fov = cam.fov
	_count_far = cam.far
	_count_vp = vp_sz


# Triangles and draw calls the tree batches submit this frame: every visible batch whose box is
# in the camera frustum (Godot's own cull test) draws all its instances, hidden ones included.
# Only the impostor cells, the hero oaks and the active hero / mid cells can be visible, so only
# those are visited; inactive batches stay as hidden children.
func count_drawn(cam: Camera3D) -> void:
	last_tris = 0
	last_draws = 0
	if not on:
		return
	var planes := cam.get_frustum()
	var pn := planes.size()
	if _count_pl.size() != pn * 4:
		_count_pl.resize(pn * 4)
	for i in pn:
		var pl := planes[i]
		var n := pl.normal
		var j := i * 4
		_count_pl[j] = n.x
		_count_pl[j + 1] = n.y
		_count_pl[j + 2] = n.z
		_count_pl[j + 3] = pl.d
	for mmi in far_nodes:
		_count(mmi, _count_pl)
	if hero_oaks != null:
		_count(hero_oaks, _count_pl)
	for v in KINDS.size():
		if hero_counts[v] > 0 and _box_in_pl(_count_pl, hero_aabbs[v]):
			last_tris += hero_counts[v] * int(mesh_tris[hero_mesh[v]])
			last_draws += int(mesh_draws.get(hero_mesh[v], 1))
	for key in mid_active:
		for mmi: MultiMeshInstance3D in mid_batches[key].nodes:
			_count(mmi, _count_pl)


func _count(mmi: MultiMeshInstance3D, pl: PackedFloat64Array) -> void:
	if not mmi.visible:
		return
	var info: Array = _draw_info.get(mmi, [])
	if info.is_empty():
		var mm := mmi.multimesh
		info = [
			mm.custom_aabb if mm.custom_aabb.size != Vector3.ZERO else mm.get_aabb(),
			mm.instance_count * int(mesh_tris[mm.mesh]),
			int(mesh_draws.get(mm.mesh, 1)),
		]
		_draw_info[mmi] = info
	if not _box_in_pl(pl, info[0]):
		return
	last_tris += info[1]
	last_draws += info[2]


static func _box_in_pl(pl: PackedFloat64Array, b: AABB) -> bool:
	var i := 0
	var n := pl.size()
	while i < n:
		var nx := pl[i]
		var ny := pl[i + 1]
		var nz := pl[i + 2]
		var cx := b.position.x if nx > 0.0 else b.end.x
		var cy := b.position.y if ny > 0.0 else b.end.y
		var cz := b.position.z if nz > 0.0 else b.end.z
		if nx * cx + ny * cy + nz * cz - pl[i + 3] > 0.0:
			return false
		i += 4
	return true
