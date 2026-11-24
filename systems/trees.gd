extends Node3D

# Stillwater's trees at the low tier (src/world/trees.js, treeChunks.js, treeImpostor.js):
#   hero      32 m cells whose nearest point is within treeHeroR of the camera, hero meshes
#   mid       64 m cells within treeMidR, sparse leaf-card meshes; trees in an active hero cell
#             are hidden in the mid shader
#   impostor  everything else (not bushes): one quad per tree, one batch per 1024 m cell; trees in
#             an active mid cell are hidden in the impostor shader
# Each level enters at its radius and leaves at lodExitRadius (hysteresis), re-picked after the
# camera moved 4 m. Hero and mid batches are one MultiMesh per kind and cell, built on first use
# and kept; Godot frustum-culls every batch by its box. Bushes draw only inside treeBushR.
# The four hand-placed hero oaks by the cottage (buildWorld.js) always draw with the hero material.
#
# Data: data/valley/web/trees.bin (the low tier's rank subset, see meta.json trees), meshes and
# atlases in data/trees/ (tools/build_tree_meshes.gd, tools/bake_impostors.mjs).

const HERO_CELL := 32.0
const NEAR_CELL := 64.0
const FAR_CELL := 1024.0
const SWAY_PAD := 2.0
const LOD_STEP := 4.0
const KINDS: Array[String] = ["oak", "round", "pine", "bush", "poplar", "larch"]
const IMP_INDEX: Array[int] = [0, 1, 2, -1, 3, 4]
const BUSH := 3
const MESH_DIR := "res://data/trees"

var world: RefCounted
var hero_r := 12.0
var mid_r := 100.0
var bush_r := 120.0

var count := 0
var px := PackedFloat32Array()
var py := PackedFloat32Array()
var pz := PackedFloat32Array()
var ps := PackedFloat32Array()
var prot := PackedFloat32Array()
var psx := PackedFloat32Array()
var ptint := PackedByteArray()
var pkind := PackedByteArray()
var tint_max := 2.0

var hero_mesh: Array[Mesh] = []
var mid_mesh: Array[Mesh] = []
var mesh_tris: Dictionary = {}
var hero_mat: ShaderMaterial
var mid_mat: ShaderMaterial
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

var hero_batches: Dictionary = {}
var mid_batches: Dictionary = {}
var hero_active: Dictionary = {}
var mid_active: Dictionary = {}
var far_nodes: Array[MultiMeshInstance3D] = []
var far_total := 0
var hero_oaks: MultiMeshInstance3D
var lod_center := Vector3(1e9, 0.0, 1e9)

var on := true
var stats := {"hero": 0, "mid": 0, "impostor": 0, "near_cells": 0, "far_cells": 0}
var last_tris := 0
var last_draws := 0
var load_ms := 0


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
	bush_r = float(tier.get("treeBushR", mid_r))
	_decode(tm)
	_load_assets()
	hero_grid = _grid(HERO_CELL, false)
	near_grid = _grid(NEAR_CELL, false)
	_build_cell_flags()
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


func _load_assets() -> void:
	for k in KINDS:
		var h: Mesh = load(MESH_DIR.path_join(k + "_hero.res"))
		var m: Mesh = load(MESH_DIR.path_join(k + "_mid.res"))
		hero_mesh.append(h)
		mid_mesh.append(m)
		mesh_tris[h] = _tris(h)
		mesh_tris[m] = _tris(m)
	var leaf := _png("leaf_atlas.pngdata")
	leaf.generate_mipmaps()
	var leaf_tex := ImageTexture.create_from_image(leaf)
	var info: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(MESH_DIR.path_join("impostors.json")))
	var alb := _png("impostor_albedo.pngdata")
	var nrm := _png("impostor_normal.pngdata")
	alb.generate_mipmaps()
	nrm.generate_mipmaps()

	var tree_shader: Shader = load("res://shaders/tree.gdshader")
	hero_mat = ShaderMaterial.new()
	hero_mat.shader = tree_shader
	mid_mat = ShaderMaterial.new()
	mid_mat.shader = tree_shader
	for mat in [hero_mat, mid_mat]:
		mat.set_shader_parameter("leaf_atlas", leaf_tex)
		mat.set_shader_parameter("biome_tex", world.texture("biome"))
		mat.set_shader_parameter("near_size", world.near_size)
		mat.set_shader_parameter("blend_start", world.blend_start)
		mat.set_shader_parameter("blend_end", world.blend_end)
	mid_mat.set_shader_parameter("hide_in_hero", 1.0)
	imp_mat = ShaderMaterial.new()
	imp_mat.shader = load("res://shaders/tree_impostor.gdshader")
	imp_mat.set_shader_parameter("imp_albedo", ImageTexture.create_from_image(alb))
	imp_mat.set_shader_parameter("imp_normal", ImageTexture.create_from_image(nrm))
	var frames := PackedVector4Array()
	for f in info.frames:
		frames.append(Vector4(f[0], f[1], f[2], f[3]))
	imp_mat.set_shader_parameter("imp_frames", frames)
	var g: Array = info.grid
	imp_mat.set_shader_parameter("imp_grid", Vector4(g[0], g[1], g[2], g[3]))
	imp_mat.set_shader_parameter("imp_atlas_px", float(info.size))
	for mat in [hero_mat, mid_mat, imp_mat]:
		mat.set_shader_parameter("noise_tex", world.noise_tex)
		mat.set_shader_parameter("sky_lut", world.sky_lut_tex)
		mat.set_shader_parameter("water_level", world.water_level)


# Materials whose look values the environment sets (sun, light colour, exposure).
func materials() -> Array[ShaderMaterial]:
	return [hero_mat, mid_mat, imp_mat]


func _png(file: String) -> Image:
	var img := Image.new()
	if img.load_png_from_buffer(FileAccess.get_file_as_bytes(MESH_DIR.path_join(file))) != OK:
		push_error("trees: cannot decode %s" % file)
	return img


static func _tris(m: Mesh) -> int:
	var arr := m.surface_get_arrays(0)
	return (arr[Mesh.ARRAY_INDEX] as PackedInt32Array).size() / 3


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
	for mat in [mid_mat, imp_mat]:
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


func _multimesh(mesh: Mesh, idx: PackedInt32Array, extra_of_kind: bool) -> MultiMesh:
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
		var mmi := MultiMeshInstance3D.new()
		mmi.multimesh = _multimesh(quad, idx, true)
		mmi.multimesh.custom_aabb = _cell_aabb(idx, (ix + 0.5) * FAR_CELL, (iz + 0.5) * FAR_CELL, FAR_CELL)
		mmi.material_override = imp_mat
		mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		add_child(mmi)
		far_nodes.append(mmi)
		far_total += idx.size()
	stats.far_cells = far_nodes.size()


func _build_hero_oaks(spots: Array) -> void:
	if spots.is_empty():
		return
	var mesh: Mesh = load(MESH_DIR.path_join("hero_oak.res"))
	mesh_tris[mesh] = _tris(mesh)
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
	hero_oaks.material_override = hero_mat
	hero_oaks.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(hero_oaks)


func _make_batch(g: Dictionary, key: Vector2i, hero: bool) -> Dictionary:
	var size: float = g.size
	var c := (key.y - int(g.iz0)) * int(g.w) + key.x - int(g.ix0)
	var start: PackedInt32Array = g.start
	var idx: PackedInt32Array = (g.order as PackedInt32Array).slice(start[c], start[c + 1])
	var cx := (key.x + 0.5) * size
	var cz := (key.y + 0.5) * size
	var batch := {"nodes": [], "cx": cx, "cz": cz, "size": size, "count": idx.size(), "bushes": 0, "on": false, "bush_on": true}
	var aabb := _cell_aabb(idx, cx, cz, size)
	for v in KINDS.size():
		var sub := PackedInt32Array()
		for i in idx:
			if pkind[i] == v:
				sub.append(i)
		if sub.is_empty():
			continue
		var mmi := MultiMeshInstance3D.new()
		mmi.multimesh = _multimesh(hero_mesh[v] if hero else mid_mesh[v], sub, false)
		mmi.multimesh.custom_aabb = aabb
		mmi.material_override = hero_mat if hero else mid_mat
		mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		mmi.visible = false
		mmi.set_meta("bush", v == BUSH)
		add_child(mmi)
		batch.nodes.append(mmi)
		if v == BUSH:
			batch.bushes = sub.size()
	return batch


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
	for key in active:
		if not want.has(key):
			_show(batches[key], false, true)
	active.clear()
	var n := 0
	var imp := 0
	for key in want:
		if not batches.has(key):
			batches[key] = _make_batch(g, key, hero)
		var b: Dictionary = batches[key]
		var bush_on := _cell_distance(b.cx, b.cz, b.size, x, z) < bush_r
		_show(b, true, bush_on)
		active[key] = true
		n += b.count if bush_on else b.count - b.bushes
		imp += b.count - b.bushes
	return Vector2i(n, imp)


func update_lod(cam_pos: Vector3, force: bool = false) -> void:
	var dx := cam_pos.x - lod_center.x
	var dz := cam_pos.z - lod_center.z
	if not force and dx * dx + dz * dz < LOD_STEP * LOD_STEP:
		return
	lod_center = cam_pos
	var hero_want := _cells_in_radius(hero_grid, cam_pos.x, cam_pos.z, hero_r, hero_active)
	var mid_want := _cells_in_radius(near_grid, cam_pos.x, cam_pos.z, mid_r, mid_active)
	var h := _sync(hero_grid, hero_batches, hero_active, hero_want, true, cam_pos.x, cam_pos.z)
	var m := _sync(near_grid, mid_batches, mid_active, mid_want, false, cam_pos.x, cam_pos.z)
	_write_cell_flags()
	stats.hero = h.x
	stats.mid = m.x - h.x
	stats.near_cells = mid_want.size()
	stats.impostor = far_total - m.y


func set_on(v: bool) -> void:
	on = v
	visible = v


func is_on() -> bool:
	return on


func _process(_delta: float) -> void:
	var cam := get_viewport().get_camera_3d()
	if cam == null or count == 0:
		return
	update_lod(cam.global_position)
	count_drawn(cam)


# Triangles and draw calls the tree batches submit this frame: every visible batch whose box is
# in the camera frustum (Godot's own cull test) draws all its instances, hidden ones included.
func count_drawn(cam: Camera3D) -> void:
	last_tris = 0
	last_draws = 0
	if not on:
		return
	var planes := cam.get_frustum()
	for child in get_children():
		var mmi := child as MultiMeshInstance3D
		if mmi == null or not mmi.visible:
			continue
		var mm := mmi.multimesh
		var box := mm.custom_aabb if mm.custom_aabb.size != Vector3.ZERO else mm.get_aabb()
		if not _box_in(planes, box):
			continue
		last_tris += mm.instance_count * int(mesh_tris[mm.mesh])
		last_draws += 1


static func _box_in(planes: Array[Plane], b: AABB) -> bool:
	for p in planes:
		var n := p.normal
		var c := Vector3(b.position.x if n.x > 0.0 else b.end.x, b.position.y if n.y > 0.0 else b.end.y, b.position.z if n.z > 0.0 else b.end.z)
		if n.dot(c) - p.d > 0.0:
			return false
	return true
